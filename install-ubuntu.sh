#!/bin/sh
# Interactive Ubuntu desktop setup. POSIX sh entry point for `sh -c ...` use.
set -eu

INSTALLER_VERSION=0.8.2
STATE="$HOME/.local/state/ubuntu-init"
TMP=""

say() { printf '\n==> %s\n' "$*"; }
warn() { printf '\n[!] %s\n' "$*" >&2; }
die() { warn "$*"; print_summary || :; exit 1; }
cleanup() { [ -z "$TMP" ] || [ ! -d "$TMP" ] || rm -rf "$TMP"; }
interrupted() { warn '已中断。已完成的步骤保留；修复问题后重新运行即可重试。'; print_summary || :; exit 130; }
trap cleanup EXIT
trap interrupted HUP INT TERM

confirm_update() {
  prompt=$1; default=${2:-y}
  if [ "$default" = y ]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
  while :; do
    printf '%s %s ' "$prompt" "$suffix"
    IFS= read -r answer || { warn '无法读取确认输入，保留现有版本/停止该操作。'; return 1; }
    case "$answer" in
      '') [ "$default" = y ] && return 0 || return 1 ;;
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf '请输入 y 或 n。\n' ;;
    esac
  done
}

# 0 = install/update, 1 = skip, 2 = cannot compare safely.
version_action() (
  label=$1; installed=$2; available=$3
  if [ -z "$available" ] || [ "$available" = '(none)' ]; then
    warn "$label：无法获取最新版本，跳过并报告失败。"; return 2
  fi
  if [ -z "$installed" ]; then
    say "$label：尚未安装，自动安装 $available"; record_step_event change; record_step_event "install	$label：$available"; return 0
  fi
  if ! dpkg --validate-version "$installed" >/dev/null 2>&1 ||
     ! dpkg --validate-version "$available" >/dev/null 2>&1; then
    warn "$label：版本格式无法比较（$installed / $available），保留现有安装。"; return 2
  fi
  if dpkg --compare-versions "$installed" ge "$available"; then
    say "$label：本地 $installed 已是最新版或更新，跳过。"; record_step_event skip; return 1
  fi
  if confirm_update "$label：本地 $installed → 最新 $available，是否更新？" y; then
    record_step_event change; record_step_event "update	$label：$installed → $available"; return 0
  fi
  record_step_event skip; return 1
)

installed_package_version() {
  dpkg-query -W -f='${db:Status-Status} ${Version}\n' "$1" 2>/dev/null |
    awk '$1 == "installed" {print $2}'
}

candidate_package_version() {
  LC_ALL=C apt-cache policy "$1" | awk '/Candidate:/ {print $2; exit}'
}

# Compare each package, including local debs, before invoking the APT solver.
apt() (
  if [ "${1:-}" != install ] || [ "${2:-}" = -f ]; then apt_raw "$@"; return; fi
  shift
  selected="$TMP/apt-selected-$$"
  : > "$selected"
  protected="$TMP/apt-protected-$$"
  : > "$protected"
  for argument do
    case "$argument" in
      -*) continue ;;
      *.deb)
        package=$(dpkg-deb -f "$argument" Package) || return 1
        candidate=$(dpkg-deb -f "$argument" Version) || return 1 ;;
      *)
        package=$argument
        candidate=$(candidate_package_version "$package") ;;
    esac
    current=$(installed_package_version "$package")
    if version_action "$package" "$current" "$candidate"; then
      printf '%s\n' "$argument" >> "$selected"
    else
      rc=$?
      [ "$rc" -eq 1 ] || { rm -f "$selected" "$protected"; return 1; }
      [ -z "$current" ] || printf '%s=%s\n' "$package" "$current" >> "$protected"
    fi
  done
  set --
  while IFS= read -r argument; do set -- "$@" "$argument"; done < "$selected"
  if [ "$#" -eq 0 ]; then rm -f "$selected" "$protected"; return 0; fi
  while IFS= read -r argument; do set -- "$@" "$argument"; done < "$protected"
  rm -f "$selected" "$protected"
  # Docker migration: let one solver transaction replace conflicting packages.
  # Download the entire accepted plan before any installed package is removed.
  for package in ${APT_REPLACEMENTS:-}; do set -- "$@" "$package-"; done
  if [ "${APT_PREFETCH:-no}" = yes ]; then
    apt_raw install --download-only -y --no-install-recommends "$@" || return 1
  fi
  apt_raw install -y --no-install-recommends "$@"
)

# Read the numeric version from a program's ordinary --version output.
program_version() {
  "$@" 2>/dev/null | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9.]*\).*/\1/p' | head -n 1
}

git_update() (
  directory=$1; repository=$2
  if [ ! -d "$directory" ]; then
    say "$repository：未安装，自动安装"
    record_step_event change
    git_clone --depth 1 "$repository" "$directory" || return 1
    record_step_event "install	$directory"; return
  fi
  [ -d "$directory/.git" ] || { warn "$directory 不是 Git 安装，无法比较版本。"; return 1; }
  current=$(git -C "$directory" rev-parse HEAD) || return 1
  remote=$(GIT_TERMINAL_PROMPT=0 git -c http.connectTimeout=15 -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 ls-remote "$repository" HEAD) || return 1
  latest=$(printf '%s\n' "$remote" | awk 'NR == 1 {print $1}')
  [ -n "$latest" ] || return 1
  if [ "$current" = "$latest" ]; then say "$directory：已是最新提交，跳过。"; record_step_event skip; return 0; fi
  if ! confirm_update "$directory：本地 $current，上游 $latest，是否更新？" y; then
    record_step_event skip; return 0
  fi
  record_step_event change
  [ -z "$(git -C "$directory" status --porcelain)" ] || { warn '存在本地修改，保留并跳过更新。'; return 1; }
  git -C "$directory" fetch "$repository" "$latest" || return 1
  # Do not reset user branches or discard commits.
  git -C "$directory" merge --ff-only FETCH_HEAD || return 1
  record_step_event "update	$directory：$current → $latest"
)

extension_action() (
  archive=$1; uuid=$2
  metadata="$HOME/.local/share/gnome-shell/extensions/$uuid/metadata.json"
  versions=$(python3 - "$archive" "$metadata" <<'PYVERS'
import json, sys, zipfile
from pathlib import Path
with zipfile.ZipFile(sys.argv[1]) as archive:
    latest = json.loads(archive.read('metadata.json'))['version']
path = Path(sys.argv[2])
current = json.loads(path.read_text()).get('version', '') if path.exists() else ''
print(str(current) + '|' + str(latest))
PYVERS
  ) || return 2
  version_action "$uuid" "${versions%|*}" "${versions#*|}"
)

download() {
  curl --fail --silent --show-error --location --connect-timeout 8 --max-time "${3:-60}" \
    --retry 2 --retry-delay 2 "$1" --output "$2"
}

git_clone() {
  GIT_TERMINAL_PROMPT=0 git -c http.connectTimeout=15 -c http.lowSpeedLimit=1024 \
    -c http.lowSpeedTime=30 clone "$@"
}

apt_raw() {
  if [ -n "${PROXY_PORT:-}" ]; then
    sudo env DEBIAN_FRONTEND=noninteractive apt-get \
      -o "Acquire::http::Proxy=http://127.0.0.1:$PROXY_PORT" \
      -o "Acquire::https::Proxy=http://127.0.0.1:$PROXY_PORT" \
      -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
      -o Acquire::Retries=2 -o DPkg::Lock::Timeout=300 "$@"
  else
    sudo env DEBIAN_FRONTEND=noninteractive apt-get \
      -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
      -o Acquire::Retries=2 -o DPkg::Lock::Timeout=300 "$@"
  fi
}

results_init() {
  RUN_RESULTS=$(mktemp "${TMP:-/tmp}/ubuntu-results.XXXXXX") || return 1
  export RUN_RESULTS
}

print_summary() {
  [ -n "${RUN_RESULTS:-}" ] && [ -f "$RUN_RESULTS" ] || return 0
  python3 - "$RUN_RESULTS" <<'PYSUMMARY'
from pathlib import Path
import sys
rows = [line.split('\t', 1) for line in Path(sys.argv[1]).read_text().splitlines() if '\t' in line]
steps = [(status, label) for status, label in rows if status in ('success', 'failure', 'skip')]
counts = {status: sum(row[0] == status for row in steps) for status in ('success', 'failure', 'skip')}
print('\n========== 本次执行结果（按软件/配置项目统计） ==========')
print('成功：{success} 项  失败：{failure} 项  跳过：{skip} 项'.format(**counts))
labels = {'success': '成功', 'failure': '失败', 'skip': '跳过'}
for index, (status, label) in enumerate(steps, 1):
    print(f'{index}. [{labels[status]}] {label}')
for kind, heading in [('install', '本次新安装'), ('update', '本次已更新')]:
    items = list(dict.fromkeys(label for status, label in rows if status == kind))
    print(heading + '：' + ('；'.join(items) if items else '无'))
failed = [label for status, label in steps if status == 'failure']
if failed:
    print('失败项目：' + '、'.join(failed))
    for status, detail in rows:
        if status == 'reason':
            print('失败原因：' + detail)
    print('请按处理建议修复后重跑；已成功的项目会按实际状态检查并跳过。')
raise SystemExit(1 if failed else 0)
PYSUMMARY
}

record_step_event() {
  [ -n "${STEP_EVENTS:-}" ] || return 0
  printf '%s\n' "$1" >> "$STEP_EVENTS"
}

# Store actionable failures in the event file, including from subshell steps.
step_failure() {
  warn "$1。处理建议：$2"
  record_step_event "reason	$1；处理建议：$2"
  return 1
}

docker_check() {
  docker_stage=$1; docker_hint=$2; shift 2
  if "$@"; then return 0; else
    docker_rc=$?
    step_failure "$docker_stage（退出码 $docker_rc）" "$docker_hint"
  fi
}

# Generated candidates are validated by the caller; keep existing files untouched
# when their content already matches, including timestamps and permissions.
apply_user_config() {
  if cmp -s "$1" "$2"; then
    rm -f "$1" || return 1
    say "$2：配置已正确，跳过写入。"
    record_step_event skip
  else
    mv "$1" "$2" || return 1
    record_step_event change
  fi
}

run_step() {
  step_title=$1; shift
  STEP_EVENTS=$(mktemp "${TMP:-/tmp}/ubuntu-step.XXXXXX") || return 1
  export STEP_EVENTS
  say "正在执行：$step_title"
  if "$@"; then
    if grep -q '^change$' "$STEP_EVENTS" || ! grep -q '^skip$' "$STEP_EVENTS"; then
      step_status=success; printf '[成功] %s\n' "$step_title"
    else
      step_status=skip; printf '[跳过] %s\n' "$step_title"
    fi
    step_rc=0
  else
    step_rc=$?; step_status=failure
    warn "$step_title 失败（退出码 $step_rc）。"
    if ! grep -q '^reason' "$STEP_EVENTS"; then
      printf 'reason\t命令 %s 失败（退出码 %s）；请检查该项目上方的命令错误输出。\n' "$*" "$step_rc" >> "$STEP_EVENTS"
    fi
  fi
  if [ -n "${RUN_RESULTS:-}" ]; then
    printf '%s\t%s\n' "$step_status" "$step_title" >> "$RUN_RESULTS"
  fi
  if [ "$step_status" = failure ] && [ -n "${RUN_RESULTS:-}" ]; then
    while IFS= read -r detail; do
      printf 'reason\t%s：%s\n' "$step_title" "$detail" >> "$RUN_RESULTS"
    done <<EOF
$(sed -n 's/^reason	//p' "$STEP_EVENTS")
EOF
  fi
  if [ "$step_status" = success ] && [ -n "${RUN_RESULTS:-}" ]; then
    # Only completed steps contribute installation/update details.
    sed -n '/^install	/p; /^update	/p' "$STEP_EVENTS" >> "$RUN_RESULTS"
  fi
  rm -f "$STEP_EVENTS"
  unset STEP_EVENTS
  return "$step_rc"
}

optional() {
  run_step "$@" || warn '其余独立步骤继续；失败项目将在最后汇总。'
}

preflight() {
  [ "$(id -u)" -ne 0 ] || die '请以普通桌面用户运行，不要在整条命令前加 sudo。'
  command -v curl >/dev/null 2>&1 || die '缺少 curl；请先安装 curl。'
  [ -r /etc/os-release ] || die '无法识别操作系统。'
  . /etc/os-release
  [ "${ID:-}" = ubuntu ] || die "只支持 Ubuntu，当前系统为 ${ID:-unknown}。"
  case "${VERSION_ID:-}" in
    24.04|26.04) ;;
    22.04) die 'Ubuntu 22.04 尚未完成兼容验证，本版会在任何安装前停止。' ;;
    *) die "暂不支持 Ubuntu ${VERSION_ID:-unknown}；支持 24.04 和 26.04。" ;;
  esac
  CODENAME=${VERSION_CODENAME:-}
  [ -n "$CODENAME" ] || die '无法读取 Ubuntu 发行版代号。'
  case "$(dpkg --print-architecture)" in
    amd64) ARCH=amd64 ;;
    arm64) ARCH=arm64 ;;
    *) die "暂不支持架构 $(dpkg --print-architecture)。" ;;
  esac
  command -v python3 >/dev/null 2>&1 || die '系统缺少 python3，无法安全解析发布信息。'
  command -v sudo >/dev/null 2>&1 || die '系统缺少 sudo。'
  [ -t 0 ] || die '安装器需要交互式终端，请在桌面终端运行。'
  sudo -v || die '无法取得 sudo 权限。'
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-init.XXXXXX")
  mkdir -p "$STATE"
  detect_desktop
  printf 'Ubuntu %s (%s), 桌面 %s, 会话 %s\n' "$VERSION_ID" "$ARCH" "$DESKTOP" "$SESSION_TYPE"
}

detect_desktop() {
  DESKTOP=${XDG_CURRENT_DESKTOP:-unknown}
  SESSION_TYPE=${XDG_SESSION_TYPE:-unknown}
  case ":$DESKTOP:" in
    *:GNOME:*|*:ubuntu:*) DE=gnome ;;
    *:KDE:*) DE=kde ;;
    *:XFCE:*) DE=xfce ;;
    *) DE=other ;;
  esac
}

mirror_probe() {
  uri=$1
  pids=''
  for pocket in "$CODENAME" "$CODENAME-updates" "$CODENAME-security"; do
    # InRelease alone can exist even when this architecture is not mirrored.
    curl --fail --silent --location --head --connect-timeout 3 --max-time 6 --retry 0 \
      "$uri/dists/$pocket/main/binary-$ARCH/Packages.xz" -o /dev/null >/dev/null 2>&1 &
    pids="$pids $!"
  done
  result=0
  for pid in $pids; do wait "$pid" || result=1; done
  [ "$result" -eq 0 ]
}

set_mirror() {
  case "$ARCH" in
    amd64)
      mirror_path=ubuntu
      official_main=https://archive.ubuntu.com/ubuntu
      official_security=https://security.ubuntu.com/ubuntu ;;
    arm64)
      mirror_path=ubuntu-ports
      official_main=https://ports.ubuntu.com/ubuntu-ports
      official_security=$official_main ;;
    *) warn "没有匹配架构 $ARCH 的 Ubuntu 软件源。"; return 1 ;;
  esac
  candidates="https://mirrors.tuna.tsinghua.edu.cn/$mirror_path https://mirrors.ustc.edu.cn/$mirror_path https://mirrors.aliyun.com/$mirror_path"
  best=''; best_seconds=''
  say '并行探测每个镜像的发行版、更新和安全仓库（每个候选约 6 秒上限）'
  for uri in $candidates; do
    start=$(date +%s%N)
    if mirror_probe "$uri"; then
      finish=$(date +%s%N)
      elapsed=$(awk -v a="$start" -v b="$finish" 'BEGIN { printf "%.3f", (b-a)/1000000000 }')
      printf '可用：%s，探测 %ss\n' "$uri" "$elapsed"
      faster=$(awk -v a="$elapsed" -v b="${best_seconds:-999999}" 'BEGIN { print (a < b) ? 1 : 0 }')
      if [ -z "$best" ] || [ "$faster" = 1 ]; then best=$uri; best_seconds=$elapsed; fi
    else
      printf '不可用或超时：%s\n' "$uri"
    fi
  done
  source=/etc/apt/sources.list.d/ubuntu.sources
  backup="$STATE/ubuntu.sources.original"
  if [ ! -e "$STATE/source-configured" ]; then
    if [ -f "$source" ]; then
      sudo cp -a "$source" "$backup" || return 1
    else
      : > "$STATE/no-original-source" || return 1
    fi
    printf '%s\n' "$source" > "$STATE/source-path" || return 1
  fi
  if [ -z "$best" ]; then
    warn '国内镜像探测失败，写入 Ubuntu 官方主源和安全源。'
    sudo tee "$source" >/dev/null <<EOF || return 1
Types: deb
URIs: $official_main
Suites: $CODENAME $CODENAME-updates $CODENAME-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $official_security
Suites: $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  else
    printf '选择镜像：%s\n' "$best"
    sudo tee "$source" >/dev/null <<EOF || return 1
Types: deb
URIs: $best
Suites: $CODENAME $CODENAME-updates $CODENAME-backports $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  fi
  : > "$STATE/source-configured"
}

github_hosts() {
  say '下载 GitHub520 最新 hosts（HTTPS，最长 60 秒/次）'
  download https://raw.hellogithub.com/hosts "$TMP/github-hosts" || return 1
  say '校验 GitHub hosts、备份并更新 /etc/hosts'
  sudo python3 - "$TMP/github-hosts" <<'PYHOSTS'
from pathlib import Path
import ipaddress
import re
import shutil
import sys

begin, end = '# GitHub520 Host Start', '# GitHub520 Host End'
source = Path(sys.argv[1]).read_text(encoding='utf-8')
if source.count(begin) != 1 or source.count(end) != 1:
    raise SystemExit('GitHub hosts 标记不完整，保留原配置。')
body = source.split(begin, 1)[1].split(end, 1)[0]
entries = {}
for line in body.splitlines():
    fields = line.split('#', 1)[0].split()
    if not fields:
        continue
    if len(fields) < 2:
        raise SystemExit('GitHub hosts 格式错误，保留原配置。')
    address = ipaddress.ip_address(fields[0])
    if not address.is_global:
        raise SystemExit('GitHub hosts 包含非公网地址，保留原配置。')
    for domain in fields[1:]:
        if not re.fullmatch(r'[a-zA-Z0-9.-]+', domain):
            raise SystemExit('GitHub hosts 域名格式错误，保留原配置。')
        if domain in ('github.com', 'githubusercontent.com', 'githubassets.com') or domain.endswith(('.github.com', '.githubusercontent.com', '.githubassets.com')):
            entries[domain] = str(address)
if not {'github.com', 'api.github.com', 'raw.githubusercontent.com'} <= entries.keys():
    raise SystemExit('GitHub hosts 缺少必要域名，保留原配置。')
path = Path('/etc/hosts')
original = path.read_text(encoding='utf-8')
if original.count(begin) != original.count(end) or original.count(begin) > 1:
    raise SystemExit('现有 GitHub hosts 标记异常，请先手动检查。')
clean = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', original, flags=re.S)
lines = []
for line in clean.splitlines():
    content, sep, comment = line.partition('#')
    fields = content.split()
    if len(fields) >= 2 and any(domain in entries for domain in fields[1:]):
        remaining = [domain for domain in fields[1:] if domain not in entries]
        line = (fields[0] + ' ' + ' '.join(remaining) if remaining else '') + ((' #' + comment) if sep else '')
    lines.append(line)
updated = '\n'.join(lines).rstrip() + '\n\n' + begin + '\n'
updated += ''.join(f'{address} {domain}\n' for domain, address in sorted(entries.items())) + end + '\n'
backup = Path('/etc/hosts.before-ubuntu-init')
if not backup.exists():
    shutil.copy2(path, backup)
path.write_text(updated, encoding='utf-8')
print(f'已更新 {len(entries)} 个 GitHub 域名；原始备份：{backup}')
PYHOSTS
  [ "$?" -eq 0 ] || return 1
  if command -v resolvectl >/dev/null 2>&1; then
    sudo resolvectl flush-caches || warn 'DNS 缓存刷新失败，hosts 已写入。'
  fi
}

apt_update() { say '刷新 APT 索引'; apt update -o APT::Update::Error-Mode=any; }

apt_maintenance() {
  apt_update || return 1
  say '检查系统软件包更新（仅模拟，不安装）'
  apt_raw --simulate upgrade > "$TMP/system-upgrade-plan" || return 1
  cat "$TMP/system-upgrade-plan"
  if grep -q '^Inst ' "$TMP/system-upgrade-plan"; then
    if confirm_update '以上系统软件包有可用更新，是否执行升级？' y; then
      dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Version}\n' > "$TMP/system-before" || return 1
      apt upgrade -y || return 1
      dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\t${Version}\n' > "$TMP/system-after" || return 1
      python3 - "$TMP/system-before" "$TMP/system-after" "${STEP_EVENTS:-/dev/null}" <<'PYSYSTEM'
from pathlib import Path
import sys
def inventory(path):
    rows = [line.split('\t') for line in Path(path).read_text().splitlines()]
    return {name: version for name, status, version in rows if status == 'installed'}
before, after = inventory(sys.argv[1]), inventory(sys.argv[2])
with open(sys.argv[3], 'a') as events:
    for name, version in after.items():
        if before.get(name) == version:
            continue
        old = before.get(name)
        kind = 'update' if old else 'install'
        events.write(kind + '\t' + name + '：' + (old + ' → ' if old else '') + version + '\nchange\n')
PYSYSTEM
      [ "$?" -eq 0 ] || return 1
    else
      record_step_event skip
    fi
  else
    say '系统软件包已是最新，跳过升级。'
    record_step_event skip
  fi
  say '清理不再需要的依赖（apt autoremove -y）'
  apt autoremove -y || return 1
  say '清理过期软件包缓存（apt autoclean）'
  apt autoclean || return 1
}


latest_asset() {
  repo=$1; regex=$2; json="$TMP/release.json"
  download "https://api.github.com/repos/$repo/releases/latest" "$json" || return 1
  python3 - "$json" "$regex" <<'PY'
import json, re, sys
with open(sys.argv[1], encoding="utf-8") as f: release = json.load(f)
pattern = re.compile(sys.argv[2])
for asset in release.get("assets", []):
    if pattern.search(asset.get("name", "")):
        print(asset["browser_download_url"])
        raise SystemExit(0)
raise SystemExit(1)
PY
}

install_deb() {
  deb=$1
  sudo dpkg-deb --info "$deb" >/dev/null || return 1
  package=$(dpkg-deb -f "$deb" Package 2>/dev/null || printf unknown)
  package_version=$(dpkg-deb -f "$deb" Version 2>/dev/null || printf unknown)
  apt install -y --no-install-recommends "$deb" || return 1
  printf '%s %s\n' "$package" "$(installed_package_version "$package")" >> "$STATE/versions.log"
}

# Probe only the deb control header, never the complete payload before consent.
remote_deb_install() (
  label=$1; package=$2; url=$3; target=$4; digest=${5:-}
  say "$label：检查远端 deb 版本（仅获取包头，最多 1 MiB / 30 秒）"
  header="$target.header"
  curl --fail --silent --show-error --location --connect-timeout 8 --max-time 30 \
    --range 0-1048575 --max-filesize 1048576 "$url" --output "$header" || {
    warn "$label：包头查询失败，保留已有安装，不下载完整包。"; return 1;
  }
  [ "$(dpkg-deb -f "$header" Package)" = "$package" ] || return 1
  [ "$(dpkg-deb -f "$header" Architecture)" = "$ARCH" ] || return 1
  latest=$(dpkg-deb -f "$header" Version) || return 1
  current=$(installed_package_version "$package")
  if version_action "$label" "$current" "$latest"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0; return 1
  fi
  say "$label：下载完整安装包（显示进度，单次最多 600 秒）"
  curl --fail --show-error --location --connect-timeout 8 --max-time 600 --retry 2 \
    "$url" --output "$target" || return 1
  if [ -n "$digest" ]; then
    printf '%s  %s\n' "$digest" "$target" | sha256sum -c - || return 1
  fi
  [ "$(dpkg-deb -f "$target" Package)" = "$package" ] || return 1
  [ "$(dpkg-deb -f "$target" Architecture)" = "$ARCH" ] || return 1
  [ "$(dpkg-deb -f "$target" Version)" = "$latest" ] || {
    warn "$label：下载期间远端版本发生变化，请重跑重新确认。"; return 1;
  }
  apt_raw install -y --no-install-recommends "$target" || return 1
  actual=$(installed_package_version "$package")
  [ "$actual" = "$latest" ] || { warn "$label：安装后版本验证失败。"; return 1; }
  printf '%s %s\n' "$package" "$actual" >> "$STATE/versions.log"
)

flclash_autostart() {
  mkdir -p "$HOME/.config/autostart" || return 1
  target="$HOME/.config/autostart/FlClash.desktop"
  if [ ! -e "$target" ]; then
    desktop=$(find /usr/share/applications -maxdepth 1 -type f -iname '*flclash*.desktop' 2>/dev/null | LC_ALL=C sort | head -n 1)
    if [ -n "$desktop" ]; then
      cp "$desktop" "$target" || return 1
    else
      cat > "$target" <<'EOF'
[Desktop Entry]
Type=Application
Name=FlClash
Exec=FlClash
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    fi
  fi
  if grep -q '^X-GNOME-Autostart-enabled=' "$target"; then
    sed 's/^X-GNOME-Autostart-enabled=.*/X-GNOME-Autostart-enabled=true/' "$target" > "$target.tmp" || return 1
    mv "$target.tmp" "$target" || return 1
  else
    printf '%s\n' 'X-GNOME-Autostart-enabled=true' >> "$target"
  fi
  if grep -q '^Hidden=' "$target"; then
    sed 's/^Hidden=.*/Hidden=false/' "$target" > "$target.tmp" || return 1
    mv "$target.tmp" "$target" || return 1
  fi
}

refresh_zsh_env() {
  refresh_zrc="${ZDOTDIR:-$HOME}/.zshrc"
  [ -r "$refresh_zrc" ] || { say '尚无 .zshrc，待官方 Oh My Zsh 安装器创建后加载。'; return 0; }
  say "自动 source $refresh_zrc，并同步后续安装所需环境"
  # zsh syntax cannot be sourced by POSIX sh. Load with zsh and transfer only
  # known environment variables through JSON, never evaluate generated shell code.
  DISABLE_AUTO_UPDATE=true zsh -d -f -i +m -c '
    zstyle ":omz:update" mode disabled
    source "$1" || exit 1
    umask 077
    /usr/bin/python3 - "$2" <<"PYENV"
import json, os, sys
from pathlib import Path
names = ("PATH", "NVM_DIR", "NVM_BIN", "NVM_INC", "http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "no_proxy", "NO_PROXY")
Path(sys.argv[1]).write_text(json.dumps({key: os.environ[key] for key in names if key in os.environ}))
PYENV
  ' ubuntu-init "$refresh_zrc" "$TMP/zsh-environment.json" </dev/null || return 1
  for env_name in PATH NVM_DIR NVM_BIN NVM_INC http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
    if /usr/bin/python3 -c 'import json,sys; raise SystemExit(sys.argv[2] not in json.load(open(sys.argv[1])))' "$TMP/zsh-environment.json" "$env_name"; then
      env_value=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]], end="")' "$TMP/zsh-environment.json" "$env_name") || return 1
      export "$env_name=$env_value"
    fi
  done
  # User shell settings may contain a stale proxy; the verified port wins for
  # this installation only, without editing unrelated user configuration.
  if [ -n "${PROXY_PORT:-}" ]; then export_proxy_env; fi
}

export_proxy_env() {
  export http_proxy="http://127.0.0.1:$PROXY_PORT" https_proxy="http://127.0.0.1:$PROXY_PORT"
  export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
  export all_proxy="$http_proxy" ALL_PROXY="$http_proxy"
  export no_proxy='localhost,127.0.0.1,::1' NO_PROXY='localhost,127.0.0.1,::1'
}

cleanup_legacy_proxy_env() {
  say '清理旧的永久代理配置，代理仅用于当前安装进程'
  for profile in "$HOME/.profile" "${ZDOTDIR:-$HOME}/.zshrc"; do
    [ -f "$profile" ] || continue
    if ! grep -Eq '^# (BEGIN|END) ubuntu-init (FlClash )?proxy$' "$profile"; then continue; fi
    backup_user_file "$profile" || return 1
    python3 - "$profile" <<'PYCLEANPROXY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
for label in ('ubuntu-init proxy', 'ubuntu-init FlClash proxy'):
    begin, end = '# BEGIN ' + label, '# END ' + label
    if s.count(begin) != s.count(end):
        raise SystemExit('旧代理配置标记不完整，保留原文件，请检查：' + str(p))
    s = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', s, flags=re.S)
p.write_text(s)
PYCLEANPROXY
    [ "$?" -eq 0 ] || return 1
  done
  refresh_zsh_env
}

flclash() {
  [ "$ARCH" = amd64 ] || { warn 'FlClash 没有匹配的 amd64 包，跳过。'; return 1; }
  say '获取 FlClash 最新正式版'
  url=$(latest_asset chen08209/FlClash 'linux-amd64\.deb$') || return 1
  deb="$TMP/flclash.deb"
  remote_deb_install FlClash flclash "$url" "$deb" || return 1
  flclash_autostart || return 1
  printf 'FlClash 已安装。退出脚本后打开 FlClash，导入订阅并启动核心，选择规则模式和系统代理，保持 TUN 关闭。\n'

}

configure_proxy() {
  printf '请先启动你当前使用的代理工具（FlClash、Termihomo 或其他兼容工具）。\n'
  printf '请输入当前本地 HTTP/混合代理端口（127.0.0.1，默认 7890）：\n> '
  IFS= read -r input || return 1
  candidate_port=${input:-7890}
  case "$candidate_port" in *[!0-9]*|'') warn '代理端口必须是数字。'; return 1 ;; esac
  [ "$candidate_port" -ge 1 ] && [ "$candidate_port" -le 65535 ] || { warn '代理端口范围应为 1–65535。'; return 1; }
  say "通过 http://127.0.0.1:$candidate_port 检查 GitHub 代理连通性"
  if ! curl --fail --silent --show-error --proxy "http://127.0.0.1:$candidate_port" --noproxy '' \
      --connect-timeout 5 --max-time 20 --retry 1 --retry-delay 2 \
      https://api.github.com/zen -o "$TMP/proxy-check"; then
    warn '代理连通性检查失败；不会在后续步骤中假设代理可用。'
    return 1
  fi
  export PROXY_PORT="$candidate_port"
  export_proxy_env
  if [ "$DE" = gnome ] && command -v gsettings >/dev/null 2>&1; then
    gsettings set org.gnome.system.proxy mode 'manual' || return 1
    gsettings set org.gnome.system.proxy.http host '127.0.0.1' || return 1
    gsettings set org.gnome.system.proxy.http port "$PROXY_PORT" || return 1
    gsettings set org.gnome.system.proxy.https host '127.0.0.1' || return 1
    gsettings set org.gnome.system.proxy.https port "$PROXY_PORT" || return 1
    gsettings set org.gnome.system.proxy.ftp host '127.0.0.1' || return 1
    gsettings set org.gnome.system.proxy.ftp port "$PROXY_PORT" || return 1
    gsettings set org.gnome.system.proxy.socks host '127.0.0.1' || return 1
    gsettings set org.gnome.system.proxy.socks port "$PROXY_PORT" || return 1
    gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.0.0.0/8', '::1']" || return 1
  else
    warn "已为当前安装进程设置代理环境变量；$DESKTOP 桌面未配置系统代理，请在桌面网络设置中选择手动代理。"
  fi
  printf '本地代理 127.0.0.1:%s 已验证；后续安装子进程将使用此代理。\n' "$PROXY_PORT"
  return 0
}

termihomo_configure_path() (
  for rc in "$HOME/.profile" "$HOME/.bashrc" "${ZDOTDIR:-$HOME}/.zshrc"; do
    if [ -f "$rc" ] && grep -q '^# BEGIN ubuntu-init local-bin$' "$rc"; then continue; fi
    backup_user_file "$rc" || return 1
    mkdir -p "$(dirname "$rc")" || return 1
    cat >> "$rc" <<'LOCALBIN' || return 1

# BEGIN ubuntu-init local-bin
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# END ubuntu-init local-bin
LOCALBIN
  done
)

termihomo_command_link() (
  target="$HOME/.local/bin/termihomo"
  [ -x "$target" ] || return 0
  link=/usr/local/bin/termihomo
  if [ -e "$link" ] || [ -L "$link" ]; then
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then return 0; fi
    warn "$link 已存在且不属于当前安装，保留原文件；请使用 $target。"
    return 1
  fi
  sudo install -d -m 0755 /usr/local/bin || return 1
  sudo ln -s "$target" "$link" || return 1
)

termihomo_finish_install() {
  termihomo_configure_path || return 1
  termihomo_command_link
}

termihomo_install() (
  printf '%s\n' '如需手动安装 Termihomo，可自行执行：'
  cat <<'TERMIHOMO_MANUAL'
sh -c 'installer=$(curl -fsSL https\://raw\.githubusercontent.com/Nyakooo/termihomo/master/install.sh) && exec sh -c "$installer"'
TERMIHOMO_MANUAL
  say '查询 Termihomo 最新正式版'
  download https://api.github.com/repos/Nyakooo/termihomo/releases/latest "$TMP/termihomo-release.json" || return 1
  python3 - "$TMP/termihomo-release.json" "$ARCH" > "$TMP/termihomo-asset" <<'PYASSET'
import json, re, sys
release = json.load(open(sys.argv[1]))
tag = release.get('tag_name', '')
if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', tag):
    raise SystemExit('Termihomo 正式版版本号无效')
name = 'termihomo-linux-' + sys.argv[2] + '.tar.gz'
asset = next((a for a in release.get('assets', []) if a['name'] == name), None)
if asset is None:
    raise SystemExit('Termihomo 缺少当前架构的 Linux 安装包')
url, digest = asset['browser_download_url'], asset.get('digest') or ''
expected_url = 'https://github.com/Nyakooo/termihomo/releases/download/' + tag + '/' + name
if url != expected_url or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
    raise SystemExit('Termihomo 发布缺少可信下载地址或 SHA-256')
print(tag[1:])
print(url)
print(digest[7:])
PYASSET
  [ "$?" -eq 0 ] || return 1
  latest=$(sed -n '1p' "$TMP/termihomo-asset")
  binary="$HOME/.local/bin/termihomo"
  current=''
  if [ ! -x "$binary" ] && command -v termihomo >/dev/null 2>&1; then binary=$(command -v termihomo); fi
  if [ -x "$binary" ]; then
    current=$(program_version "$binary" version)
    [ -n "$current" ] || { warn '无法读取已有 Termihomo 版本，保留现有安装。'; return 1; }
  fi
  if version_action Termihomo "$current" "$latest"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && { termihomo_finish_install; return $?; }; return 1
  fi
  url=$(sed -n '2p' "$TMP/termihomo-asset")
  digest=$(sed -n '3p' "$TMP/termihomo-asset")
  say '下载并校验 Termihomo 安装包'
  download "$url" "$TMP/termihomo.tar.gz" || return 1
  printf '%s  %s\n' "$digest" "$TMP/termihomo.tar.gz" | sha256sum -c - || return 1
  python3 - "$TMP/termihomo.tar.gz" "$TMP/termihomo" <<'PYEXTRACT'
import sys, tarfile
from pathlib import Path
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    member = archive.getmember('termihomo')
    if not member.isfile() or not 0 < member.size < 128 * 1024 * 1024:
        raise SystemExit('Termihomo 安装包中的可执行文件无效')
    Path(sys.argv[2]).write_bytes(archive.extractfile(member).read())
Path(sys.argv[2]).chmod(0o755)
PYEXTRACT
  [ "$?" -eq 0 ] || return 1
  actual=$(program_version "$TMP/termihomo" version)
  [ "$actual" = "$latest" ] || { warn 'Termihomo 安装包版本不匹配。'; return 1; }
  mkdir -p "$HOME/.local/bin" || return 1
  install -m 0755 "$TMP/termihomo" "$HOME/.local/bin/termihomo" || return 1
  termihomo_finish_install || return 1
  printf 'Termihomo %s 已安装。\n' "$latest"
)

termihomo_setup() {
  termihomo_install || return 1
  printf 'Termihomo 已安装。可直接运行 termihomo（通过 /usr/local/bin 中的链接）；若当前 PATH 不含 /usr/local/bin，执行 export PATH="$HOME/.local/bin:$PATH"，或直接运行 ~/.local/bin/termihomo，在界面内安装 Mihomo 内核、导入订阅、启动核心并选择节点，保持 TUN 关闭。\n'

}

proxy_setup() {
  while :; do
    printf '\n选择代理工具：\n  1) FlClash（图形界面，默认）\n  2) Termihomo（终端 TUI / CLI）\n请输入 1 或 2 [1]：'
    IFS= read -r proxy_choice || return 2
    case "$proxy_choice" in
      ''|1)
        flclash || return $?
        printf 'FlClash\n' > "$STATE/proxy-tool.tmp" || return 1
        mv "$STATE/proxy-tool.tmp" "$STATE/proxy-tool"; return $? ;;
      2)
        termihomo_setup || return $?
        printf 'Termihomo\n' > "$STATE/proxy-tool.tmp" || return 1
        mv "$STATE/proxy-tool.tmp" "$STATE/proxy-tool"; return $? ;;
      *) printf '请输入 1 或 2。\n' ;;
    esac
  done
}

nvm_node() {
  json="$TMP/nvm.json"
  download https://api.github.com/repos/nvm-sh/nvm/releases/latest "$json" || return 1
  version=$(python3 - "$json" <<'PY'
import json, re, sys
tag = json.load(open(sys.argv[1], encoding="utf-8")).get("tag_name", "")
if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag): raise SystemExit(1)
print(tag)
PY
  ) || return 1
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then NVM_DIR="$XDG_CONFIG_HOME/nvm"; else NVM_DIR="$HOME/.nvm"; fi
  export NVM_DIR
  current=''
  if [ -s "$NVM_DIR/nvm.sh" ]; then current=$(bash -c '. "$NVM_DIR/nvm.sh" && nvm --version') || return 1; fi
  if version_action nvm "$current" "${version#v}"; then
    installer="$TMP/nvm-install.sh"
    download "https://raw.githubusercontent.com/nvm-sh/nvm/$version/install.sh" "$installer" || return 1
    PROFILE="${ZDOTDIR:-$HOME}/.zshrc" bash "$installer" || return 1
    refresh_zsh_env || return 1
  else
    rc=$?; [ "$rc" -eq 1 ] || return 1
  fi
  [ -s "$NVM_DIR/nvm.sh" ] || return 1
  latest_node=$(bash -c '. "$NVM_DIR/nvm.sh" && nvm version-remote --lts') || return 1
  current_node=$(bash -c '. "$NVM_DIR/nvm.sh" && nvm current') || return 1
  case "$current_node" in v*) current_node=${current_node#v} ;; *) current_node='' ;; esac
  if version_action 'Node.js LTS' "$current_node" "${latest_node#v}"; then
    bash -c '. "$NVM_DIR/nvm.sh" && nvm install "$1" && nvm alias default "$1"' sh "$latest_node" || return 1
  else
    rc=$?; [ "$rc" -eq 1 ] || return 1
  fi
  # npm runs through nvm so it also works before a new login has loaded PATH.
  for tool in pnpm http-server nrm; do
    latest_tool=$(bash -c '. "$NVM_DIR/nvm.sh" && npm_config_fetch_timeout=60000 npm_config_fetch_retries=2 npm view "$1" version' sh "$tool") || return 1
    current_tool=$(bash -c '. "$NVM_DIR/nvm.sh" && npm list -g --depth=0 --json' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("dependencies", {}).get(sys.argv[1], {}).get("version", ""))' "$tool") || return 1
    if version_action "$tool" "$current_tool" "$latest_tool"; then
      bash -c '. "$NVM_DIR/nvm.sh" && npm_config_fetch_timeout=60000 npm_config_fetch_retries=2 npm install -g "$1@$2"' sh "$tool" "$latest_tool" || return 1
    else
      rc=$?; [ "$rc" -eq 1 ] || return 1
    fi

  done
  refresh_zsh_env
}

screenshot_setup() {
  [ "$DE" = gnome ] || { warn 'Flameshot 全局截图快捷键自动配置仅支持 GNOME。'; return 1; }
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || { warn '请在已登录的 GNOME 桌面终端配置截图。'; return 1; }
  apt install -y --no-install-recommends flameshot util-linux python3-gi gir1.2-gtk-3.0 \
    xdg-desktop-portal xdg-desktop-portal-gnome || return 1
  backup_user_file "$HOME/.local/bin/flameshot-screenshot" || return 1
  python3 - "$STATE" <<'PY'
# ubuntu-init Flameshot shortcuts: real GSettings, testable with the memory backend.
from pathlib import Path
import json, os, re, shlex, sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gio, Gtk, GLib
changed = False
def set_value(settings, key, value):
    global changed
    if settings.get_value(key).equal(value): return
    if not settings.set_value(key, value): raise RuntimeError(key)
    changed = True
home = Path.home()
root = Path(sys.argv[1]) / 'desktop-backup'
root.mkdir(parents=True, exist_ok=True)
media = Gio.Settings.new('org.gnome.settings-daemon.plugins.media-keys')
shell = Gio.Settings.new('org.gnome.shell.keybindings')
paths = media.get_strv('custom-keybindings')
base = '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/'
entries = {}
for path in dict.fromkeys(paths + [base + 'flameshot/', base + 'flameshot-print/']):
    settings = Gio.Settings.new_with_path('org.gnome.settings-daemon.plugins.media-keys.custom-keybinding', path)
    entries[path] = {key: settings.get_string(key) for key in ['name', 'command', 'binding']}
keys = ['show-screenshot-ui', 'screenshot', 'screenshot-window']
backup = root / 'screenshot-shortcuts.json'
if not backup.exists():
    backup.write_text(json.dumps({'shell': {key: shell.get_strv(key) for key in keys},
                                  'paths': paths, 'entries': entries}, indent=2) + '\n')
wrapper = home / '.local/bin/flameshot-screenshot'
wrapper.parent.mkdir(parents=True, exist_ok=True)
wrapper_text = '''#!/bin/sh
set -eu
cache="${XDG_CACHE_HOME:-$HOME/.cache}/flameshot"
mkdir -p "$cache"
if [ "${XDG_SESSION_TYPE:-}" = wayland ]; then
    exec /usr/bin/script -q -e -c 'env QT_QPA_PLATFORM=wayland /usr/bin/flameshot gui' /dev/null > "$cache/shortcut.log" 2>&1
fi
exec /usr/bin/flameshot gui > "$cache/shortcut.log" 2>&1
'''
if not wrapper.exists() or wrapper.read_text() != wrapper_text:
    wrapper.write_text(wrapper_text)
    changed = True
if wrapper.stat().st_mode & 0o777 != 0o755:
    wrapper.chmod(0o755)
    changed = True
def accelerator(binding):
    # On Ubuntu Primary is Control. Resolve it explicitly rather than asking
    # GDK for a display/keymap, which may be unavailable during configuration.
    return Gtk.accelerator_parse(re.sub(r'<Primary>', '<Control>', binding, flags=re.I))

bindings = ['<Control><Alt>a', 'Print']
targets = {accelerator(binding) for binding in bindings}
# Remove only conflicting screenshot accelerators; keep Alt+Print and unrelated keys.
for key in keys:
    set_value(shell, key, GLib.Variant('as', [x for x in shell.get_strv(key) if accelerator(x) not in targets]))
for path in paths:
    settings = Gio.Settings.new_with_path('org.gnome.settings-daemon.plugins.media-keys.custom-keybinding', path)
    if path not in [base + 'flameshot/', base + 'flameshot-print/'] and accelerator(settings.get_string('binding')) in targets:
        set_value(settings, 'binding', GLib.Variant('s', ''))
for suffix, binding in zip(['flameshot/', 'flameshot-print/'], bindings):
    path = base + suffix
    settings = Gio.Settings.new_with_path('org.gnome.settings-daemon.plugins.media-keys.custom-keybinding', path)
    set_value(settings, 'name', GLib.Variant('s', 'Flameshot 截图'))
    set_value(settings, 'command', GLib.Variant('s', shlex.quote(str(wrapper))))
    set_value(settings, 'binding', GLib.Variant('s', binding))
    if path not in paths: paths.append(path)
set_value(media, 'custom-keybindings', GLib.Variant('as', list(dict.fromkeys(paths))))
Gio.Settings.sync()
if os.environ.get('STEP_EVENTS'):
    with open(os.environ['STEP_EVENTS'], 'a') as events:
        events.write('change\n' if changed else 'skip\n')
PY
  [ "$?" -eq 0 ] || return 1
  sh -n "$HOME/.local/bin/flameshot-screenshot" || return 1
  printf '已绑定 Ctrl+Alt+A 和 Print 到 Flameshot，按需启动，无需开机常驻。首次截图如有授权弹窗，请允许。\n'
}

user_dirs_setup() {
  python3 - "$STATE" <<'PYUSERDIRS'
# ubuntu-init standard home directories: no shell evaluation or system locale changes.
from pathlib import Path
import ctypes, locale, os, re, shlex, shutil, stat, sys

home = Path.home()
config = Path(os.environ.get('XDG_CONFIG_HOME') or home / '.config')
settings = config / 'user-dirs.dirs'
locale_file = config / 'user-dirs.locale'
defaults = {
    'DESKTOP': ('Desktop', '桌面', '桌面'),
    'DOWNLOAD': ('Downloads', '下载', '下載'),
    'TEMPLATES': ('Templates', '模板', '範本'),
    'PUBLICSHARE': ('Public', '公共', '公用'),
    'DOCUMENTS': ('Documents', '文档', '文件'),
    'MUSIC': ('Music', '音乐', '音樂'),
    'PICTURES': ('Pictures', '图片', '圖片'),
    'VIDEOS': ('Videos', '视频', '影片'),
}
text = settings.read_text() if settings.exists() else ''
pattern = re.compile(r'^XDG_([A-Z]+)_DIR=(.*)$', re.M)
entries = {}
for match in pattern.finditer(text):
    key, raw = match.groups()
    if key not in defaults: continue
    if key in entries: raise SystemExit(f'XDG_{key}_DIR 重复，保留现有目录，请检查 {settings}')
    tokens = shlex.split(raw, comments=True)
    if len(tokens) != 1: raise SystemExit(f'无法解析 XDG_{key}_DIR，未迁移目录。')
    value = tokens[0]
    if value == '$HOME' or value.startswith('$HOME/'):
        value = str(home) + value[5:]
    entries[key] = Path(value)

moves, remove_empty, create, mappings, updates = [], [], [], {}, {}
# Ubuntu/Linux renameat2 refuses to overwrite even if a destination appears mid-run.
rename_no_replace = ctypes.CDLL(None, use_errno=True).renameat2
rename_no_replace.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
def move_no_replace(source, target):
    if rename_no_replace(-100, os.fsencode(source), -100, os.fsencode(target), 1):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(target))
def exists(path):
    return path.exists() or path.is_symlink()
def plan_merge(source, target):
    if not exists(target):
        moves.append((source, target))
    elif source.is_dir() and target.is_dir() and not source.is_symlink() and not target.is_symlink():
        for child in source.iterdir(): plan_merge(child, target / child.name)
        remove_empty.append(source)
    else:
        raise SystemExit(f'目录迁移存在同名冲突：{source} → {target}；未移动任何文件。')

for key, names in defaults.items():
    target = home / names[0]
    source = entries.get(key)
    if source is None:
        source = next((home / name for name in names[1:] if exists(home / name)), target)
    # Respect disabled directories, custom locations and symlinks.
    if source.parent != home or source.name not in names or source.is_symlink():
        print(f'保留自定义或已禁用的目录：XDG_{key}_DIR={source}')
        continue
    if target.is_symlink() or (exists(target) and not target.is_dir()):
        raise SystemExit(f'英文目录目标不是普通目录：{target}；未移动任何文件。')
    if exists(source) and not source.is_dir():
        raise SystemExit(f'原标准目录不是普通目录：{source}；未移动任何文件。')
    if source != target:
        if exists(source): plan_merge(source, target)
        mappings[source] = target
    if not exists(source) and not exists(target): create.append(target)
    if entries.get(key) != target: updates[key] = target

seen = set()
def replace(match):
    key = match[1]
    seen.add(key)
    if key in updates: return f'XDG_{key}_DIR="$HOME/{updates[key].name}"'
    return match[0]
new_text = pattern.sub(replace, text)
for key, target in updates.items():
    if key not in seen:
        new_text = new_text.rstrip() + f'\nXDG_{key}_DIR="$HOME/{target.name}"\n'
# Record the current desktop language, so login does not offer to translate back.
current_locale = locale.setlocale(locale.LC_MESSAGES, '').split('.')[0]
writes = {}
if new_text != text: writes[settings] = new_text
if not locale_file.exists() or locale_file.read_text().strip() != current_locale:
    writes[locale_file] = current_locale + '\n'
for bookmarks in [config / 'gtk-3.0/bookmarks', config / 'gtk-4.0/bookmarks', home / '.gtk-bookmarks']:
    if not bookmarks.is_file(): continue
    old = bookmarks.read_text()
    lines = []
    for line in old.splitlines(keepends=True):
        uri, separator, label = line.rstrip('\n').partition(' ')
        for source, target in mappings.items():
            prefix = source.as_uri()
            if uri == prefix or uri.startswith(prefix + '/'):
                uri = target.as_uri() + uri[len(prefix):]
                if label == source.name: label = target.name
                break
        lines.append(uri + separator + label + ('\n' if line.endswith('\n') else ''))
    if ''.join(lines) != old: writes[bookmarks] = ''.join(lines)

changed = bool(moves or remove_empty or create or writes)
backup = Path(sys.argv[1]) / 'desktop-backup/user-dirs'
if changed:
    backup.mkdir(parents=True, exist_ok=True)
    for path in writes:
        name = path.name if path in [settings, locale_file] else path.parent.name + '-' + path.name
        saved = backup / name
        absent = backup / (name + '.absent')
        if not saved.exists() and not absent.exists():
            if path.exists(): shutil.copy2(path, saved)
            else: absent.touch()
    # Prepare configuration files before moving data. Original paths remain valid on failure.
    staged, completed, created, committed = [], [], [], []
    originals = {path: path.read_bytes() if path.exists() else None for path in writes}
    try:
        for path, content in writes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            candidate = path.with_name(path.name + '.ubuntu-init.tmp')
            candidate.write_text(content)
            if path.exists(): candidate.chmod(stat.S_IMODE(path.stat().st_mode))
            staged.append((candidate, path))
        for path in create:
            path.mkdir()
            created.append(path)
        for source, target in moves:
            # rename on one filesystem; never overwrite an existing destination.
            if exists(target): raise RuntimeError(f'迁移期间目标已出现，停止：{target}')
            move_no_replace(source, target)
            completed.append((source, target))
        for candidate, path in staged:
            candidate.replace(path)
            committed.append(path)
    except Exception:
        for path in reversed(committed):
            if originals[path] is None: path.unlink()
            else: path.write_bytes(originals[path])
        for source, target in reversed(completed): move_no_replace(target, source)
        for path in reversed(created): path.rmdir()
        for candidate, _ in staged: candidate.unlink(missing_ok=True)
        raise
    # XDG paths are committed; now remove only emptied source directories.
    for path in remove_empty:
        try: path.rmdir()
        except OSError: print(f'保留迁移过程中仍有内容的目录：{path}')
    for source, target in mappings.items(): print(f'{source.name} → {target.name}')
    print('标准文件夹已调整为英文；系统语言未修改。建议注销重新登录以刷新应用路径。')
else:
    print('家目录标准文件夹已是英文，跳过。')
if os.environ.get('STEP_EVENTS'):
    with open(os.environ['STEP_EVENTS'], 'a') as events:
        events.write('change\n' if changed else 'skip\n')
PYUSERDIRS
}

keyboard_setup() (
  # GNOME's old XKB swap would turn keyd's Esc output back into CapsLock.
  [ "$DE" = gnome ] || { warn "当前桌面 $DESKTOP 尚未实现旧键位迁移。"; return 1; }
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gsettings >/dev/null 2>&1 || {
    warn '未检测到 GNOME 用户会话；请在登录后的桌面终端运行。'; return 1;
  }
  [ "$(gsettings writable org.gnome.desktop.input-sources xkb-options)" = true ] || {
    warn 'xkb-options 被锁定，无法清理旧键位配置。'; return 1;
  }
  current=$(gsettings get org.gnome.desktop.input-sources xkb-options) || return 1
  desired=$(python3 - "$current" "$STATE" <<'PYKEYBOARD'
import ast, json, re, sys
from pathlib import Path
options = ast.literal_eval(sys.argv[1].removeprefix('@as '))
if not isinstance(options, list) or any(not isinstance(x, str) for x in options):
    raise SystemExit('无法读取 XKB 选项列表，未修改键位。')
backup = Path(sys.argv[2]) / 'desktop-backup/keyboard-before-keyd.json'
backup.parent.mkdir(parents=True, exist_ok=True)
if not backup.exists():
    backup.write_text(json.dumps(options, ensure_ascii=False, indent=2) + '\n')
# Keep layout switching and other options which do not remap Caps/Esc.
print(repr([x for x in options if not re.search(r'caps|escape', x, re.I)]))
PYKEYBOARD
  ) || return 1
  candidate=$(candidate_package_version keyd) || return 1
  if [ -z "$candidate" ] || [ "$candidate" = '(none)' ]; then
    [ "$CODENAME" = noble ] || { warn 'APT 中找不到 keyd，请检查 universe 软件源。'; return 1; }
    say 'Ubuntu 24.04：添加 keyd 上游列出的 keyd-team PPA'
    apt install -y --no-install-recommends software-properties-common || return 1
    sudo add-apt-repository -y ppa:keyd-team/ppa || return 1
    apt_update || return 1
  fi
  keyd_before=$(installed_package_version keyd)
  apt install -y --no-install-recommends keyd || return 1
  # Debian/Ubuntu rename the executable to avoid a conflict with onak's keyd.
  if [ -x /usr/bin/keyd.rvaiya ]; then
    keyd_bin=/usr/bin/keyd.rvaiya
  elif keyd_bin=$(command -v keyd); then
    :
  else
    warn 'keyd 软件包已安装，但找不到 keyd.rvaiya 或 keyd 命令；未修改键位。'
    return 1
  fi
  # keyd selects one config per device; do not silently compete with user configs.
  sudo python3 - <<'PYKEYDCONFLICT'
from pathlib import Path
root = Path('/etc/keyd')
for path in root.glob('*.conf'):
    if path.name != 'ubuntu-init.conf' or not path.read_text().startswith('# ubuntu-init Caps/Esc swap\n'):
        raise SystemExit(f'保留已有 keyd 配置 {path}；请先合并 Caps/Esc 规则后重试。')
PYKEYDCONFLICT
  [ "$?" -eq 0 ] || return 1
  cat > "$TMP/keyboard-keyd.conf" <<'KEYDCONF'
# ubuntu-init Caps/Esc swap
[ids]
*

[main]
capslock = esc
esc = capslock
KEYDCONF
  xkb_changed=yes
  if python3 - "$current" "$desired" <<'PYXKBCOMPARE'
import ast, sys
raise SystemExit(ast.literal_eval(sys.argv[1].removeprefix('@as ')) != ast.literal_eval(sys.argv[2]))
PYXKBCOMPARE
  then xkb_changed=no; fi
  if [ "$xkb_changed" = no ] && sudo cmp -s "$TMP/keyboard-keyd.conf" /etc/keyd/ubuntu-init.conf &&
      [ "$keyd_before" = "$(installed_package_version keyd)" ] &&
      sudo systemctl is-enabled --quiet keyd && sudo systemctl is-active --quiet keyd; then
    rm -f "$STATE/keyboard-remap-mode" "$STATE/keyboard-dconf-editor-migrated" || return 1
    say 'Caps/Esc 互换：配置正确、服务已启用且运行中，跳过写入和重载。'
    record_step_event skip
    return 0
  fi
  had_config=no
  if sudo test -f /etc/keyd/ubuntu-init.conf; then
    sudo cp -a /etc/keyd/ubuntu-init.conf "$TMP/keyboard-keyd.previous" || return 1
    had_config=yes
  fi
  # Install before touching XKB, so permission/disk errors keep the old mapping.
  sudo install -d -m 0755 /etc/keyd || return 1
  if ! sudo cmp -s "$TMP/keyboard-keyd.conf" /etc/keyd/ubuntu-init.conf; then
    sudo install -m 0644 "$TMP/keyboard-keyd.conf" /etc/keyd/ubuntu-init.conf || return 1
  fi
  if { [ "$xkb_changed" = no ] || gsettings set org.gnome.desktop.input-sources xkb-options "$desired"; } &&
      python3 - "$desired" "$(gsettings get org.gnome.desktop.input-sources xkb-options)" <<'PYVERIFY'
import ast, sys
if ast.literal_eval(sys.argv[1]) != ast.literal_eval(sys.argv[2].removeprefix('@as ')):
    raise SystemExit('旧 XKB 映射清理后读回不一致。')
PYVERIFY
  then
    if sudo systemctl enable --now keyd && sudo "$keyd_bin" reload &&
        sudo systemctl is-active --quiet keyd; then
      rm -f "$STATE/keyboard-remap-mode" "$STATE/keyboard-dconf-editor-migrated" || return 1
      record_step_event change
      printf '%s\n' '已配置标准 keyd：CapsLock ↔ Esc 双向互换，统一应用于所有键盘。' \
        '旧 GNOME Caps/Esc 映射已清理；无需选择模式或手动改配置，建议注销重新登录。' \
        '请分别在 A 本机和 B 经 IPKVM 验证 Caps → Esc、Esc → CapsLock。'
      return 0
    fi
  fi
  warn 'keyd 配置未成功，恢复本次运行前的键位。'
  if [ "$had_config" = yes ]; then
    sudo cp -a "$TMP/keyboard-keyd.previous" /etc/keyd/ubuntu-init.conf || return 1
  else
    sudo rm -f /etc/keyd/ubuntu-init.conf || return 1
  fi
  gsettings set org.gnome.desktop.input-sources xkb-options "$current" || warn '旧 XKB 配置恢复失败。'
  sudo "$keyd_bin" reload || warn 'keyd 重载失败，请检查 systemctl status keyd。'
  return 1
)

chrome() {
  [ "$ARCH" = amd64 ] || { warn 'Chrome .deb 自动安装仅适用于 amd64。'; return 1; }
  remote_deb_install Chrome google-chrome-stable https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb "$TMP/chrome.deb"
}

localsend() {
  case "$ARCH" in
    amd64) pattern='linux-x86-64\.deb$' ;;
    arm64) pattern='linux-(aarch64|arm-?64)\.deb$' ;;
  esac
  url=$(latest_asset localsend/localsend "$pattern") || return 1
  remote_deb_install LocalSend localsend "$url" "$TMP/localsend.deb"
}

zed_editor() (
  say '检查 Zed 稳定版'
  case "$ARCH" in
    amd64) zed_arch=x86_64 ;;
    arm64) zed_arch=aarch64 ;;
    *) warn 'Zed 仅支持 amd64、arm64。'; return 1 ;;
  esac
  download https://api.github.com/repos/zed-industries/zed/releases/latest "$TMP/zed-release.json" || {
    step_failure 'Zed 版本信息下载失败' '检查代理是否能访问 api.github.com'; return 1;
  }
  available=$(python3 - "$TMP/zed-release.json" <<'PYZED'
import json, re, sys
release = json.load(open(sys.argv[1]))
tag = release.get('tag_name', '')
if release.get('prerelease') or release.get('draft') or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
    raise SystemExit('Zed 稳定版元数据无效')
print(tag[1:])
PYZED
  ) || return 1
  current=''
  if [ -x "$HOME/.local/bin/zed" ]; then
    current=$(program_version "$HOME/.local/bin/zed" --version)
    [ -n "$current" ] || { warn '无法读取已有 Zed 版本，保留现有安装。'; return 1; }
  elif command -v zed >/dev/null 2>&1; then
    current=$(program_version zed --version)
    [ -n "$current" ] || { warn '无法读取已有 Zed 版本，保留现有安装。'; return 1; }
  fi
  if version_action Zed "$current" "$available"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0; return 1
  fi
  apt install -y --no-install-recommends libvulkan1 libsecret-1-0 xdg-desktop-portal || {
    step_failure 'Zed 系统依赖安装失败' '检查上方 APT 错误'; return 1;
  }
  download https://zed.dev/install.sh "$TMP/zed-install.sh" || {
    step_failure 'Zed 官方安装器下载失败' '检查代理是否能访问 zed.dev'; return 1;
  }
  say "下载 Zed $available 安装包（最长等待 30 分钟）"
  download "https://cloud.zed.dev/releases/stable/$available/download?asset=zed&arch=$zed_arch&os=linux&source=install.sh" "$TMP/zed.tar.gz" 1800 || {
    step_failure 'Zed 安装包下载失败（30 分钟时限）' '检查上方 curl 错误，确认代理节点能访问 cloud.zed.dev 及其重定向下载地址'; return 1;
  }
  tar -tzf "$TMP/zed.tar.gz" >/dev/null || {
    step_failure 'Zed 安装包完整性检查失败' '重新运行下载完整安装包'; return 1;
  }
  ZED_CHANNEL=stable ZED_VERSION="$available" ZED_BUNDLE_PATH="$TMP/zed.tar.gz" sh "$TMP/zed-install.sh" || {
    step_failure 'Zed 官方安装器执行失败' '检查上方安装器错误及家目录写入权限、剩余空间'; return 1;
  }
  actual=$(program_version "$HOME/.local/bin/zed" --version)
  [ "$actual" = "$available" ] || {
    step_failure "Zed 安装后版本验证失败（预期 $available，实际 ${actual:-无法读取}）" '运行 ~/.local/bin/zed --version 查看错误'; return 1;
  }
  [ -f "$HOME/.local/share/applications/dev.zed.Zed.desktop" ] || {
    step_failure 'Zed 应用菜单文件缺失' '检查 ~/.local/share/applications 的写入权限后重跑'; return 1;
  }
  printf 'Zed %s 已安装，可从应用菜单或运行 ~/.local/bin/zed 打开。\n' "$actual"
)

chatgpt_desktop() (
  say '检查 ChatGPT 官方桌面客户端版本'
  base=https://persistent.oaistatic.com/codex-app-prod/linux/deb
  download "$base/dists/stable/main/binary-$ARCH/Packages" "$TMP/chatgpt-packages" || return 1
  python3 - "$TMP/chatgpt-packages" "$ARCH" > "$TMP/chatgpt-asset" <<'PYCHATGPT'
# ubuntu-init ChatGPT package selection: official desktop deb, never the npm Codex CLI.
from pathlib import Path, PurePosixPath
import re, subprocess, sys
selected = None
for stanza in Path(sys.argv[1]).read_text().split('\n\n'):
    fields = dict(line.split(': ', 1) for line in stanza.splitlines() if ': ' in line and not line.startswith(' '))
    if fields.get('Package') != 'chatgpt' or fields.get('Architecture') != sys.argv[2]:
        continue
    filename = fields.get('Filename', '')
    path = PurePosixPath(filename)
    if (not filename.startswith('pool/main/c/chatgpt/') or '..' in path.parts
        or not filename.endswith('.deb') or not re.fullmatch(r'[a-zA-Z0-9_./+~-]+', filename)
        or not re.fullmatch(r'[0-9a-f]{64}', fields.get('SHA256', ''))):
        raise SystemExit('ChatGPT 官方软件包元数据无效')
    version = fields.get('Version', '')
    if subprocess.run(['dpkg', '--validate-version', version], capture_output=True).returncode:
        raise SystemExit('ChatGPT 官方版本号无效')
    if selected is None or subprocess.run(['dpkg', '--compare-versions', version, 'gt', selected['Version']]).returncode == 0:
        selected = fields
if selected is None:
    raise SystemExit('ChatGPT 官方仓库没有匹配当前架构的客户端')
for key in ('Version', 'Filename', 'SHA256'):
    print(selected[key])
PYCHATGPT
  [ "$?" -eq 0 ] || return 1
  available=$(sed -n '1p' "$TMP/chatgpt-asset")
  current=$(installed_package_version chatgpt)
  if version_action 'ChatGPT 桌面客户端' "$current" "$available"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0; return 1
  fi
  filename=$(sed -n '2p' "$TMP/chatgpt-asset")
  digest=$(sed -n '3p' "$TMP/chatgpt-asset")
  say '下载 ChatGPT 官方桌面客户端（单次最多 600 秒）'
  curl --fail --show-error --location --connect-timeout 8 --max-time 600 --retry 2 \
    "$base/$filename" --output "$TMP/chatgpt.deb" || return 1
  printf '%s  %s\n' "$digest" "$TMP/chatgpt.deb" | sha256sum -c - || return 1
  [ "$(dpkg-deb -f "$TMP/chatgpt.deb" Package)" = chatgpt ] || return 1
  [ "$(dpkg-deb -f "$TMP/chatgpt.deb" Architecture)" = "$ARCH" ] || return 1
  [ "$(dpkg-deb -f "$TMP/chatgpt.deb" Version)" = "$available" ] || return 1
  # The version decision above already obtained upgrade consent.
  apt_raw install -y --no-install-recommends "$TMP/chatgpt.deb" || return 1
  printf 'chatgpt %s\n' "$(installed_package_version chatgpt)" >> "$STATE/versions.log"
  printf 'ChatGPT 桌面客户端已安装，可从应用菜单打开并登录。\n'
)

antigravity_ide() (
  say '检查 Antigravity IDE 官方独立版版本'
  download https://antigravity.google/download/ "$TMP/antigravity-download.html" || return 1
  python3 - "$TMP/antigravity-download.html" "$ARCH" > "$TMP/antigravity-asset" <<'PYANTIGRAVITY'
# ubuntu-init Antigravity selection: standalone IDE, not the App or CLI.
from html.parser import HTMLParser
from pathlib import Path
import re, sys
from urllib.parse import unquote, urlsplit
arch = {'amd64': 'x64', 'arm64': 'arm'}[sys.argv[2]]
class Downloads(HTMLParser):
    def handle_starttag(self, tag, attrs):
        if tag != 'a':
            return
        url = dict(attrs).get('href', '')
        parts = urlsplit(url)
        match = re.fullmatch(
            r'/edgedl/release2/[a-zA-Z0-9_-]+/antigravity/stable/'
            r'(\d+\.\d+\.\d+)-[0-9]+/linux-' + arch + r'/Antigravity IDE\.tar\.gz',
            unquote(parts.path))
        if parts.scheme == 'https' and parts.netloc == 'edgedl.me.gvt1.com' and match and not parts.query and not parts.fragment:
            found.add((match[1], url))
found = set()
Downloads().feed(Path(sys.argv[1]).read_text())
if len(found) != 1:
    raise SystemExit('无法确定当前架构的 Antigravity IDE 官方下载地址')
version, url = found.pop()
print(version)
print(url)
PYANTIGRAVITY
  [ "$?" -eq 0 ] || return 1
  available=$(sed -n '1p' "$TMP/antigravity-asset")
  url=$(sed -n '2p' "$TMP/antigravity-asset")
  current=$(python3 - "$HOME/.local/bin/antigravity-ide" <<'PYCURRENT'
import json, sys
from pathlib import Path
binary = Path(sys.argv[1])
if binary.is_file():
    metadata = binary.resolve().parent.parent / 'resources/app/product.json'
    print(json.loads(metadata.read_text())['ideVersion'])
PYCURRENT
  ) || return 1
  if version_action 'Antigravity IDE' "$current" "$available"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0; return 1
  fi
  say '下载 Antigravity IDE（单次最多 600 秒）'
  curl --fail --show-error --location --connect-timeout 8 --max-time 600 --retry 2 \
    "$url" --output "$TMP/antigravity-ide.tar.gz" || return 1
  python3 - "$TMP/antigravity-ide.tar.gz" "$TMP/antigravity-unpacked" "$available" <<'PYUNPACK'
import json, sys, tarfile
from pathlib import Path
root = Path(sys.argv[2])
with tarfile.open(sys.argv[1]) as archive:
    archive.extractall(root, filter='data')
app = root / 'Antigravity IDE'
if json.loads((app / 'resources/app/product.json').read_text())['ideVersion'] != sys.argv[3]:
    raise SystemExit('Antigravity IDE 归档版本不匹配')
for name in ('antigravity-ide', 'bin/antigravity-ide', 'resources/app/resources/linux/code.png'):
    if not (app / name).is_file():
        raise SystemExit('Antigravity IDE 归档缺少必要文件')
PYUNPACK
  [ "$?" -eq 0 ] || return 1
  destination="$HOME/.local/opt/antigravity-ide-$available"
  [ ! -e "$destination" ] || { warn "目标目录已存在，保留现有文件：$destination"; return 1; }
  mkdir -p "$HOME/.local/opt" "$HOME/.local/bin" "$HOME/.local/share/applications" || return 1
  "$TMP/antigravity-unpacked/Antigravity IDE/bin/antigravity-ide" --version || return 1
  mv "$TMP/antigravity-unpacked/Antigravity IDE" "$destination" || return 1
  ln -sfn "$destination/bin/antigravity-ide" "$HOME/.local/bin/antigravity-ide" || return 1
  python3 - "$destination" "$HOME/.local/share/applications/antigravity-ide.desktop" <<'PYDESKTOP'
from pathlib import Path
import sys
base = sys.argv[1]
def quoted(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'
Path(sys.argv[2]).write_text(
    '[Desktop Entry]\nType=Application\nName=Antigravity IDE\n'
    'Comment=Google Antigravity IDE\n'
    f'Exec={quoted(base + "/antigravity-ide")} %F\n'
    f'Icon={base}/resources/app/resources/linux/code.png\n'
    'Terminal=false\nCategories=Development;IDE;\n')
PYDESKTOP
  [ "$?" -eq 0 ] || return 1
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" || return 1
  fi
  printf 'antigravity-ide %s\n' "$available" >> "$STATE/versions.log"
  printf 'Antigravity IDE 已安装，可从应用菜单打开并登录，或运行 ~/.local/bin/antigravity-ide。\n'
)

trae_cn() {
  trae_current=$(installed_package_version trae-cn)
  if [ -z "$trae_current" ]; then
    confirm_update '检测到尚未安装 TRAE CN 桌面客户端，是否安装？' y || {
      record_step_event skip
      say '已跳过 TRAE CN 安装。'
      return 0
    }
  fi
  say '获取 TRAE CN 官方最新 Linux 安装包信息'
  download https://api.trae.cn/icube/api/v1/native/version/trae/cn/latest "$TMP/trae-cn-release.json" || return 1
  trae_url=$(python3 - "$TMP/trae-cn-release.json" "$ARCH" <<'PYTRAE'
# ubuntu-init TRAE CN download selection: official CN channel and matching deb architecture.
import json, sys
from urllib.parse import urlsplit, unquote
release = json.load(open(sys.argv[1]))
if release.get('success') is not True:
    raise SystemExit('TRAE CN 官方版本查询失败')
arch = {'amd64': 'x64', 'arm64': 'arm64'}[sys.argv[2]]
entries = release.get('data', {}).get('manifest', {}).get('linux', {}).get('download', [])
for entry in entries:
    if entry.get('region') != 'cn':
        continue
    url = entry.get(arch + '.deb', '')
    parts = urlsplit(url)
    if (parts.scheme == 'https' and parts.netloc == 'lf-cdn.trae.com.cn'
        and unquote(parts.path).startswith('/obj/trae-com-cn/pkg/app/releases/stable/')
        and unquote(parts.path).endswith('-linux-' + arch + '.deb')
        and not parts.query and not parts.fragment):
        print(url)
        break
else:
    raise SystemExit('TRAE CN 未提供匹配当前架构的官方中国版 deb')
PYTRAE
  ) || return 1
  remote_deb_install "TRAE CN" trae-cn "$trae_url" "$TMP/trae-cn.deb"
}

vim_setup() {
  command -v vim >/dev/null 2>&1 || { warn 'Vim 尚未安装，无法配置 .vimrc。'; return 1; }
  say '按 Ubuntu24_init.md 配置 Vim：行号、搜索与快捷键'
  backup_user_file "$HOME/.vimrc" || return 1
  cat > "$TMP/vimrc-defaults" <<'VIMDEFAULTS'
" 开启语法高亮
syntax on

" 按键映射
noremap K 5k
noremap J 5j
noremap L g_
noremap H ^

" S 保存
map S :w<CR>
" Q 退出
map Q :q<CR>
" 刷新 vimrc配置
map R :source $MYVIMRC<CR>

" 行号
set number
" 相对行号
set relativenumber
" 显示光标线
set cursorline
" 换行
set wrap
" : 命令 菜单
set wildmenu
" / 高亮搜索
set hlsearch
" 清空旧的搜索高亮
exec "nohlsearch"
" 边输入边高亮
set incsearch
" 忽略大小写搜索
set ignorecase
" 智能大小写
set smartcase
VIMDEFAULTS
  python3 - "$HOME/.vimrc" "$TMP/vimrc-defaults" <<'PYVIMRC'
from pathlib import Path
import re, sys
p, defaults = Path(sys.argv[1]), Path(sys.argv[2])
s = p.read_text() if p.exists() else ''
begin, end = '" BEGIN ubuntu-init vim', '" END ubuntu-init vim'
if s.count(begin) != s.count(end):
    raise SystemExit('Vim 配置块标记不完整，保留原配置。')
s = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', s, flags=re.S)
block = begin + '\n' + defaults.read_text().rstrip() + '\n' + end + '\n'
p.with_name(p.name + '.ubuntu-init.tmp').write_text(s.rstrip() + '\n\n' + block)
PYVIMRC
  [ "$?" -eq 0 ] || return 1
  vim -N -u "$HOME/.vimrc.ubuntu-init.tmp" -n -es -i NONE -c 'qa!' || return 1
  apply_user_config "$HOME/.vimrc.ubuntu-init.tmp" "$HOME/.vimrc" || return 1
  printf 'Vim 配置已验证：%s/.vimrc\n' "$HOME"
}

zsh_configure() {
  zrc="${ZDOTDIR:-$HOME}/.zshrc"
  template="$HOME/.oh-my-zsh/templates/zshrc.zsh-template"
  # The official installer creates the initial configuration when not installed yet.
  [ -r "$template" ] || return 0
  mkdir -p "$(dirname "$zrc")" || return 1
  backup_user_file "$zrc" || return 1
  python3 - "$zrc" "$template" <<'PYZSH'
from pathlib import Path
import re, sys
p, template = map(Path, sys.argv[1:])
s = p.read_text() if p.exists() else ''
begin, end = '# BEGIN ubuntu-init zsh', '# END ubuntu-init zsh'
if s.count(begin) != s.count(end):
    raise SystemExit('旧 zsh 配置块不完整，保留原文件。')
if begin in s:
    # Retire only our generated settings; keep user/nvm content outside the block.
    remaining = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', s, flags=re.S).strip()
    s = template.read_text()
    if remaining:
        s = s.rstrip() + '\n\n' + remaining + '\n'
elif not p.exists():
    s = template.read_text()
else:
    # An existing user configuration belongs to the user, including its comments.
    raise SystemExit(0)
p.with_name(p.name + '.ubuntu-init.tmp').write_text(s)
PYZSH
  [ "$?" -eq 0 ] || return 1
  [ -f "$zrc.ubuntu-init.tmp" ] || { record_step_event skip; return 0; }
  zsh -n "$zrc.ubuntu-init.tmp" || return 1
  apply_user_config "$zrc.ubuntu-init.tmp" "$zrc" || return 1
}

zsh_customize() {
  zrc="${ZDOTDIR:-$HOME}/.zshrc"
  [ -r "$HOME/.oh-my-zsh/themes/funky.zsh-theme" ] || { warn '缺少 funky 主题，未写入自定义配置。'; return 1; }
  for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
    [ -r "$HOME/.oh-my-zsh/custom/plugins/$plugin/$plugin.plugin.zsh" ] || {
      warn "$plugin 尚未安装，未写入自定义配置。"; return 1;
    }
  done
  backup_user_file "$zrc" || return 1
  python3 - "$zrc" <<'PYEXTRAS'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
s = p.read_text()
begin, end = '# BEGIN ubuntu-init shell extras', '# END ubuntu-init shell extras'
if s.count(begin) != s.count(end):
    raise SystemExit('自定义配置块不完整，保留原文件。')
s = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n*', '', s, flags=re.S)
# Update the native theme field and keep all of its surrounding documentation.
s, count = re.subn(r'(?m)^ZSH_THEME=.*$', 'ZSH_THEME="funky"', s)
if not count:
    s = 'ZSH_THEME="funky"\n' + s
# Merge plugins immediately before OMZ loads, after the native plugins=(...) field.
block = begin + r'''
typeset -ga plugins
plugins+=(git zsh-autosuggestions zsh-syntax-highlighting)
typeset -U plugins
''' + end + '\n'
source = re.search(r'(?m)^[ \t]*(?:source|\.)[ \t]+[^\n;]*oh-my-zsh\.sh[^\n]*$', s)
if source is None:
    raise SystemExit('未找到 Oh My Zsh 加载入口，未写入配置。')
s = s[:source.start()] + block + '\n' + s[source.start():]
# Put aliases after OMZ so its libraries cannot overwrite them.
begin, end = '# BEGIN ubuntu-init shell aliases', '# END ubuntu-init shell aliases'
if s.count(begin) != s.count(end):
    raise SystemExit('别名配置块不完整，保留原文件。')
s = re.sub(re.escape(begin) + r'.*?' + re.escape(end) + r'\n?', '', s, flags=re.S)
s = s.rstrip() + '\n\n' + begin + "\nalias ra='ranger'\nalias ter='\"$HOME/.local/bin/termihomo\"'\n" + end + '\n'
p.with_name(p.name + '.ubuntu-init.tmp').write_text(s)
PYEXTRAS
  [ "$?" -eq 0 ] || return 1
  zsh -n "$zrc.ubuntu-init.tmp" || return 1
  apply_user_config "$zrc.ubuntu-init.tmp" "$zrc" || return 1
}

validate_zsh_startup() {
  # Nested interactive shells must not take control of the installer's terminal.
  DISABLE_AUTO_UPDATE=true zsh -d -f -i +m -c '
    zstyle ":omz:update" mode disabled
    source "$1" || exit 1
    [[ -n "$ZSH_VERSION" ]]
  ' ubuntu-init "${ZDOTDIR:-$HOME}/.zshrc" </dev/null
}

zsh_setup() {
  command -v zsh >/dev/null 2>&1 || { warn 'zsh 尚未安装，保留当前默认 shell。'; return 1; }
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    say '使用 Oh My Zsh 官方安装器和原生默认配置'
    backup_user_file "${ZDOTDIR:-$HOME}/.zshrc" || return 1
    download https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh "$TMP/ohmyzsh-install.sh" || return 1
    ZSH="$HOME/.oh-my-zsh" RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
      sh "$TMP/ohmyzsh-install.sh" || return 1
    record_step_event change
    record_step_event "install	Oh My Zsh（官方安装器）"
  else
    git_update "$HOME/.oh-my-zsh" https://github.com/ohmyzsh/ohmyzsh.git || return 1
  fi
  zsh_configure || return 1
  say '下载或更新插件，完成后再写入主题、插件和别名配置'
  custom="$HOME/.oh-my-zsh/custom/plugins"
  mkdir -p "$custom" || return 1
  for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
    git_update "$custom/$plugin" "https://github.com/zsh-users/$plugin.git" || return 1
  done
  zsh_customize || return 1
  [ -r "$HOME/.oh-my-zsh/oh-my-zsh.sh" ] || return 1
  say '验证 zsh 交互启动、主题和插件加载'
  validate_zsh_startup || return 1
  zsh_path=$(command -v zsh) || return 1
  login_shell=$(getent passwd "$(id -un)" | cut -d: -f7)
  if [ "$login_shell" != "$zsh_path" ]; then
    say '配置验证通过，设置 zsh 为默认 shell'
    chsh -s "$zsh_path" || return 1
    login_shell=$(getent passwd "$(id -un)" | cut -d: -f7)
    [ "$login_shell" = "$zsh_path" ] || { warn '默认 shell 未成功改变。'; return 1; }
  fi
  refresh_zsh_env || return 1
  printf '已在安装子进程中 source 验证：%s；ra 和 ter 别名已写入配置，原终端尚未加载。\n' "${ZDOTDIR:-$HOME}/.zshrc"
  printf '%s\n' '第二阶段全部成功结束后，将自动进入 Zsh 并加载这些别名。'
}

# Back up once, including an absence marker so rollback is unambiguous.
backup_user_file() {
  python3 - "$1" "$STATE/desktop-backup" <<'PY'
from pathlib import Path
import shutil, sys
source, root = Path(sys.argv[1]), Path(sys.argv[2])
target = root / source.relative_to(Path.home())
if not target.exists() and not Path(str(target) + '.absent').exists():
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.exists():
        if source.is_dir(): shutil.copytree(source, target)
        else: shutil.copy2(source, target)
    else: Path(str(target) + '.absent').touch()
PY
}

sysmonitor_format() {
  config="$HOME/.config/indicator-sysmonitor/settings.json"
  [ -f "$config" ] || return 0
  # Older local adapters need the new sensor classes before using this template.
  grep -q 'class CpuTemperatureSensor' "$HOME/.local/share/indicator-sysmonitor/sysmonitor_common/sensors.py" 2>/dev/null || return 0
  say '更新状态栏格式：{netcomp} u {cpu} m {mem} c {cpu_temp} {fan_rpm}'
  backup_user_file "$config" || return 1
  format_changed=$(python3 - "$config" <<'PYFORMAT'
import json, sys
from pathlib import Path
config = Path(sys.argv[1])
data = json.loads(config.read_text())
desired = '{netcomp} u {cpu} m {mem} c {cpu_temp} {fan_rpm}'
if data.get('custom_text') == desired:
    print('skip')
else:
    data['custom_text'] = desired
    config.write_text(json.dumps(data, indent=2) + '\n')
    print('change')
PYFORMAT
  ) || return 1
  record_step_event "$format_changed"
}

sysmonitor() {
  say '安装 System Monitor 和低开销顶部监控（CPU/内存/网速/温度/风扇）'
  sysmonitor_format || return 1
  apt install -y --no-install-recommends git python3-gi python3-psutil \
    gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 udisks2 gnome-system-monitor || return 1
  if [ "$DE" = gnome ]; then
    if [ "$VERSION_ID" = 26.04 ]; then
      apt install -y --no-install-recommends gnome-shell-ubuntu-extensions || return 1
    else
      apt install -y --no-install-recommends gnome-shell-extension-appindicator || return 1
    fi
    gnome-extensions enable ubuntu-appindicators@ubuntu.com 2>/dev/null || \
      warn 'AppIndicator 扩展将在注销重新登录后载入。'
  fi
  if [ -x "$HOME/.local/bin/indicator-sysmonitor" ]; then
    monitor_current=$(tail -n 1 "$STATE/sysmonitor-revisions.log" 2>/dev/null || :)
    monitor_remote=$(GIT_TERMINAL_PROMPT=0 git -c http.connectTimeout=15 -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=30 ls-remote https://github.com/fossfreedom/indicator-sysmonitor.git HEAD) || return 1
    monitor_latest=$(printf '%s\n' "$monitor_remote" | awk 'NR == 1 {print $1}')
    [ -n "$monitor_latest" ] || return 1
    if [ "$monitor_current" = "$monitor_latest" ]; then
      if grep -q 'class CpuTemperatureSensor' "$HOME/.local/share/indicator-sysmonitor/sysmonitor_common/sensors.py" 2>/dev/null; then
        say '顶部监控：已是最新提交，跳过。'; record_step_event skip; return 0
      fi
      say '更新本地监控适配：增加独立 CPU 温度和风扇字段'
    else
      confirm_update "顶部监控：本地 ${monitor_current:-未知版本}，上游 $monitor_latest，是否更新？" y || { record_step_event skip; return 0; }
    fi
  fi
  git_clone --depth 1 https://github.com/fossfreedom/indicator-sysmonitor.git "$TMP/sysmonitor" || return 1
  for target in "$HOME/.local/share/indicator-sysmonitor" "$HOME/.local/bin/indicator-sysmonitor" \
      "$HOME/.config/indicator-sysmonitor/settings.json" "$HOME/.config/autostart/indicator-sysmonitor.desktop" \
      "$HOME/.local/share/applications/indicator-sysmonitor.desktop"; do
    backup_user_file "$target" || return 1
  done
  python3 - "$TMP/sysmonitor" <<'PY'
# ubuntu-init monitor installer: kept inline for the single-file download entry point.
from pathlib import Path
import json, shutil, sys
source = Path(sys.argv[1])
home = Path.home()
target = home / '.local/share/indicator-sysmonitor'
module = source / 'sysmonitor_common/sensors.py'
s = module.read_text()
anchor = '            for sensor in self.sensor_instances:\n                self.settings'
if s.count(anchor) != 1:
    raise RuntimeError('上游传感器接口已改变，停止安装，不覆盖现有程序')
s = s.replace(anchor, '            telemetry = DesktopTelemetry()\n            self.sensor_instances.extend([telemetry, CpuTemperatureSensor(telemetry), FanSpeedSensor(telemetry)])\n\n' + anchor)
s += '''

class DesktopTelemetry(BaseSensor):
    """Kernel sensors and UDisks cache only; never poll SMART hardware."""
    name = 'desktopstats'
    desc = 'CPU temperature, disk temperature and fan speed'

    def __init__(self):
        self.next_disk_read = 0
        self.disk = '—'
        self.bus = None

    def get_value(self, sensor):
        import math
        from gi.repository import Gio
        cpu = '—'
        fan = '—'
        # psutil reads hwmon/sysfs in-process; no sensors/smartctl subprocesses.
        try:
            temperatures = ps.sensors_temperatures()
            for chip in ('coretemp', 'k10temp', 'zenpower', 'cpu_thermal', 'acpitz'):
                entries = temperatures.get(chip, [])
                valid = [e.current for e in entries
                         if math.isfinite(e.current) and 0 < e.current < 150]
                if valid:
                    cpu = '{:.0f}°C'.format(max(valid))
                    break
        except (OSError, ValueError):
            temperatures = {}
        try:
            speeds = [e.current for entries in ps.sensors_fans().values()
                      for e in entries if e.current >= 0]
            if speeds:
                fan = '{} RPM'.format(int(max(speeds)))
        except (OSError, ValueError):
            pass
        if sensor == 'cpu_temp':
            return cpu
        if sensor == 'fan_rpm':
            return fan
        now = time.monotonic()
        if now >= self.next_disk_read:
            self.next_disk_read = now + 60
            disks = []
            # NVMe hwmon temperature, where the kernel exposes it.
            for chip, entries in temperatures.items():
                if chip.startswith(('nvme', 'drivetemp')):
                    disks.extend(e.current for e in entries
                                 if math.isfinite(e.current) and 0 < e.current < 150)
            try:
                if self.bus is None:
                    self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
                objects = self.bus.call_sync(
                    'org.freedesktop.UDisks2', '/org/freedesktop/UDisks2',
                    'org.freedesktop.DBus.ObjectManager', 'GetManagedObjects',
                    None, None, Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
                for interfaces in objects.values():
                    ata = interfaces.get('org.freedesktop.UDisks2.Drive.Ata', {})
                    kelvin = ata.get('SmartTemperature', 0)
                    if ata.get('SmartEnabled') and 273.15 < kelvin < 423.15:
                        disks.append(kelvin - 273.15)
            except GLib.Error:
                pass
            self.disk = '{:.0f}°C'.format(max(disks)) if disks else '—'
        return 'CPU: {} SSD: {} FAN: {}'.format(cpu, self.disk, fan)


class CpuTemperatureSensor(BaseSensor):
    name = 'cpu_temp'
    desc = 'CPU temperature'

    def __init__(self, telemetry):
        self.telemetry = telemetry

    def get_value(self, sensor):
        return self.telemetry.get_value(self.name)


class FanSpeedSensor(BaseSensor):
    name = 'fan_rpm'
    desc = 'Fan speed in RPM'

    def __init__(self, telemetry):
        self.telemetry = telemetry

    def get_value(self, sensor):
        return self.telemetry.get_value(self.name)
'''
# Upstream shells out to `ip route` every tick; use the kernel route table instead.
a = s.index('def get_default_iface():')
b = s.index('def bytes_to_human(', a)
s = s[:a] + '''def get_default_iface():
    try:
        with open('/proc/net/route') as routes:
            next(routes, None)
            for line in routes:
                fields = line.split()
                if len(fields) > 3 and fields[1] == '00000000' and int(fields[3], 16) & 1:
                    return fields[0]
    except (OSError, ValueError):
        pass
    # IPv6-only systems may not have an IPv4 default route.
    for name, stats in ps.net_if_stats().items():
        if name != 'lo' and stats.isup:
            return name
    return None

''' + s[b:]
module.write_text(s)
# Keep the app self-contained in the user's directory, with no system source patching.
for p in [module, source / 'sysmonitor_common/preferences.py',
          source / 'indicator_sysmonitor/indicator-sysmonitor']:
    text = p.read_text().replace("'/usr/share/indicator-sysmonitor'", repr(str(target)))
    text = text.replace("'/usr/share/applications/indicator-sysmonitor.desktop'",
                        repr(str(home / '.local/share/applications/indicator-sysmonitor.desktop')))
    compile(text, str(p), 'exec')
    p.write_text(text)
target.mkdir(parents=True, exist_ok=True)
shutil.copytree(source / 'sysmonitor_common', target / 'sysmonitor_common', dirs_exist_ok=True)
shutil.copy2(source / 'indicator_sysmonitor/indicator-sysmonitor', target / 'indicator-sysmonitor')
shutil.copy2(source / 'LICENSE', target / 'LICENSE')
config = home / '.config/indicator-sysmonitor/settings.json'
config.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(config.read_text()) if config.exists() else {}
data.update(custom_text='{netcomp} u {cpu} m {mem} c {cpu_temp} {fan_rpm}',
            interval=2, on_startup=True)
data.setdefault('sensors', {})
config.write_text(json.dumps(data, indent=2) + '\n')
wrapper = home / '.local/bin/indicator-sysmonitor'
wrapper.parent.mkdir(parents=True, exist_ok=True)
# shlex.quote handles spaces and shell metacharacters in a home directory.
import shlex
wrapper.write_text('#!/bin/sh\nexec /usr/bin/python3 ' + shlex.quote(str(target / 'indicator-sysmonitor'))
                   + ' --config ' + shlex.quote(str(config)) + ' "$@"\n')
wrapper.chmod(0o755)
autostart = home / '.config/autostart/indicator-sysmonitor.desktop'
autostart.parent.mkdir(parents=True, exist_ok=True)
# Desktop Exec quoting differs from shell quoting; escape reserved characters and %.
exe = str(wrapper).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
autostart.write_text('[Desktop Entry]\nType=Application\nName=System Monitor Indicator\n'
                     f'Exec="{exe}"\nX-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=5\n')
launcher = home / '.local/share/applications/indicator-sysmonitor.desktop'
launcher.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(autostart, launcher)
PY
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  git -C "$TMP/sysmonitor" rev-parse HEAD >> "$STATE/sysmonitor-revisions.log" || return 1
  printf '已配置简洁显示；CPU/风扇每 2 秒读取，硬盘每 60 秒读取缓存。无传感器显示 —；多盘显示最高温度。\n'
  printf 'System Monitor 已安装。顶部栏在注销重新登录后使用新配置。\n'
}

kimpanel_setup() {
  [ "$DE" = gnome ] || return 0
  shell_version=$(gnome-shell --version | awk '{print $3}' | cut -d. -f1) || return 1
  download "https://extensions.gnome.org/extension-info/?uuid=kimpanel%40kde.org&shell_version=$shell_version" "$TMP/kimpanel.json" || return 1
  extension_url=$(python3 - "$TMP/kimpanel.json" "$shell_version" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
version = info.get('shell_version_map', {}).get(sys.argv[2], {}).get('pk')
if info.get('uuid') != 'kimpanel@kde.org' or not isinstance(version, int):
    raise SystemExit('没有匹配当前 GNOME 的 Input Method Panel 版本')
print('https://extensions.gnome.org/download-extension/kimpanel@kde.org.shell-extension.zip?version_tag=' + str(version))
PY
  ) || return 1
  download "$extension_url" "$TMP/kimpanel.zip" || return 1
  # Validate the archive and declared GNOME compatibility before installing code.
  python3 - "$TMP/kimpanel.zip" "$shell_version" <<'PY'
import json, sys, zipfile
from pathlib import PurePosixPath
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        p = PurePosixPath(name)
        if p.is_absolute() or '..' in p.parts: raise SystemExit('不安全的扩展路径')
    meta = json.loads(z.read('metadata.json'))
    if meta['uuid'] != 'kimpanel@kde.org' or sys.argv[2] not in meta['shell-version']:
        raise SystemExit('扩展与当前 GNOME 不匹配')
PY
  [ "$?" -eq 0 ] || return 1
  if extension_action "$TMP/kimpanel.zip" "kimpanel@kde.org"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0; return 1
  fi
  backup_user_file "$HOME/.local/share/gnome-shell/extensions/kimpanel@kde.org" || return 1
  gnome-extensions install --force "$TMP/kimpanel.zip" || return 1
  # A newly installed extension is discovered by GNOME only on the next login.
  python3 - <<'PY'
from gi.repository import Gio
s = Gio.Settings.new('org.gnome.shell')
uuid = 'kimpanel@kde.org'
s.set_strv('enabled-extensions', list(dict.fromkeys(s.get_strv('enabled-extensions') + [uuid])))
s.set_strv('disabled-extensions', [x for x in s.get_strv('disabled-extensions') if x != uuid])
Gio.Settings.sync()
PY
}

wowtype_setup() {
  say '安装 WowType 并设为默认输入法'
  case "$DE" in
    gnome|xfce) ;;
    *) warn '自动输入法切换仅支持 GNOME/XFCE；其他桌面保持原配置。'; return 1 ;;
  esac
  download https://api.github.com/repos/Gloridust/WowType/releases/latest "$TMP/wowtype-release.json" || return 1
  python3 - "$TMP/wowtype-release.json" "$VERSION_ID" "$ARCH" > "$TMP/wowtype-asset" <<'PY'
import json, re, sys
from pathlib import Path

release = json.loads(Path(sys.argv[1]).read_text())
pattern = re.compile(r'wowtype_[^/]+_ubuntu' + re.escape(sys.argv[2]) + '_' + sys.argv[3] + r'\.deb')
asset = next((item for item in release['assets'] if pattern.fullmatch(item['name'])), None)
if asset is None:
    raise SystemExit('WowType 官方发布缺少匹配当前 Ubuntu 版本和架构的安装包')
url, digest = asset['browser_download_url'], asset.get('digest') or ''
if not url.startswith('https://github.com/Gloridust/WowType/releases/download/') or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
    raise SystemExit('WowType 官方发布缺少可验证的安装包或 SHA-256')
print(url)
print(digest[7:])
PY
  [ "$?" -eq 0 ] || return 1
  wowtype_url=$(sed -n '1p' "$TMP/wowtype-asset")
  wowtype_sha=$(sed -n '2p' "$TMP/wowtype-asset")
  remote_deb_install WowType wowtype "$wowtype_url" "$TMP/wowtype.deb" "$wowtype_sha" || return 1
  apt install -y --no-install-recommends fcitx5-config-qt \
    fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 \
    fcitx5-frontend-qt6 im-config python3-gi gir1.2-gtk-4.0 gir1.2-adw-1 || return 1
  for target in "$HOME/.xinputrc" "$HOME/.config/fcitx5" \
      "$HOME/.config/autostart/org.fcitx.Fcitx5.desktop"; do
    backup_user_file "$target" || return 1
  done
  if [ "$DE" = gnome ]; then
    python3 - "$STATE" <<'PYSHELLBACKUP'
from pathlib import Path
import json, sys
from gi.repository import Gio
backup = Path(sys.argv[1]) / 'desktop-backup/gnome-shell.json'
backup.parent.mkdir(parents=True, exist_ok=True)
if not backup.exists():
    settings = Gio.Settings.new('org.gnome.shell')
    backup.write_text(json.dumps({key: settings.get_value(key).print_(True)
                                  for key in settings.props.settings_schema.list_keys()},
                                 ensure_ascii=False, indent=2) + '\n')
PYSHELLBACKUP
    [ "$?" -eq 0 ] || return 1
    kimpanel_setup || warn 'GNOME 候选词面板安装失败，部分 GNOME 界面可能无法显示候选框。'
  fi
  python3 - <<'PY'
# ubuntu-init WowType configuration
from pathlib import Path
import configparser, io, os, shutil
changed = False
def write_config(path, content):
    global changed
    if path.exists() and path.read_text() == content: return
    path.write_text(content)
    changed = True
home = Path.home()
root = home / '.config/fcitx5'
root.mkdir(parents=True, exist_ok=True)
config = root / 'config'
settings = configparser.ConfigParser(interpolation=None, strict=False)
settings.optionxform = str
settings.read(config, encoding='utf-8')
if not settings.has_section('Behavior'):
    settings.add_section('Behavior')
settings['Behavior']['ActiveByDefault'] = 'True'
output = io.StringIO()
settings.write(output, space_around_delimiters=False)
write_config(config, output.getvalue())
write_config(root / 'profile',
    '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=wowtype\n\n'
    '[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n'
    '[Groups/0/Items/1]\nName=wowtype\nLayout=\n\n[GroupOrder]\n0=Default\n')
auto = home / '.config/autostart/org.fcitx.Fcitx5.desktop'
auto.parent.mkdir(parents=True, exist_ok=True)
source = Path('/usr/share/applications/org.fcitx.Fcitx5.desktop')
if not auto.exists() or auto.read_bytes() != source.read_bytes():
    shutil.copy2(source, auto)
    changed = True
if os.environ.get('STEP_EVENTS'):
    with open(os.environ['STEP_EVENTS'], 'a') as events:
        events.write('change\n' if changed else 'skip\n')
PY
  [ "$?" -eq 0 ] || return 1
  if ! grep -q '^run_im fcitx5$' "$HOME/.xinputrc" 2>/dev/null; then
    im-config -n fcitx5 || return 1
    record_step_event change
  fi
  # Do not kill IBus or restart the active input method while the user is typing.
  printf '已将 WowType 设为默认中文输入法。注销并重新登录后默认启用；Ctrl+空格切换中英文。\n'
}

docker_apt_source() {
  python3 - "$CODENAME" <<'PYAPT'
# ubuntu-init Docker APT probe: fastest reachable signed-repository endpoint.
from concurrent.futures import ThreadPoolExecutor
import sys, time
from urllib.request import ProxyHandler, Request, build_opener
candidates = ['https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu',
              'https://mirrors.ustc.edu.cn/docker-ce/linux/ubuntu',
              'https://mirrors.aliyun.com/docker-ce/linux/ubuntu']
def check(base):
    start = time.monotonic()
    try:
        with build_opener(ProxyHandler({})).open(
                Request(base + '/dists/' + sys.argv[1] + '/InRelease'), timeout=6) as r:
            data = r.read(131072)
        if not data.startswith(b'-----BEGIN PGP SIGNED MESSAGE-----'):
            return None
        return time.monotonic() - start, base
    except Exception:
        return None
with ThreadPoolExecutor(max_workers=3) as pool:
    results = [r for r in pool.map(check, candidates) if r]
# APT verifies the chosen InRelease with Docker's official signing key later.
for elapsed, base in sorted(results):
    print(base)
print('https://download.docker.com/linux/ubuntu')
PYAPT
}

docker_mirror_probe() {
  python3 - "$TMP/docker-mirrors.json" "$ARCH" <<'PY'
# ubuntu-init Docker mirror probe: anonymous OCI pull, direct network, bounded download.
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib, json, re, sys, time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, ProxyHandler, Request

CANDIDATES = ['https://docker.1ms.run', 'https://docker.m.daocloud.io',
              'https://docker.xuanyuan.me', 'https://dockerproxy.net',
              'https://docker.1panel.live']
ACCEPT = ', '.join(['application/vnd.oci.image.index.v1+json',
                    'application/vnd.docker.distribution.manifest.list.v2+json',
                    'application/vnd.oci.image.manifest.v1+json',
                    'application/vnd.docker.distribution.manifest.v2+json'])

class SecureRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != 'https':
            raise ValueError('拒绝非 HTTPS 跳转')
        result = super().redirect_request(req, fp, code, msg, headers, newurl)
        if result and urlsplit(req.full_url).netloc != urlsplit(newurl).netloc:
            result.remove_header('Authorization')
        return result

def probe(base, arch):
    start = time.monotonic()
    opener = build_opener(ProxyHandler({}), SecureRedirect())
    token = None
    def get(path, limit, authenticate=True):
        nonlocal token
        remaining = 30 - (time.monotonic() - start)
        if remaining <= 0: raise TimeoutError('测速超时')
        headers = {'Accept': ACCEPT, 'User-Agent': 'ubuntu-init-mirror-probe/1'}
        if token: headers['Authorization'] = 'Bearer ' + token
        try:
            response = opener.open(Request(base + path, headers=headers), timeout=min(8, remaining))
        except HTTPError as error:
            challenge = error.headers.get('WWW-Authenticate', '')
            error.close()
            if error.code != 401 or not authenticate: raise
            if not challenge.lower().startswith('bearer '): raise ValueError('要求账号登录')
            fields = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
            realm = fields.get('realm', '')
            if urlsplit(realm).scheme != 'https': raise ValueError('无效认证入口')
            query = {'service': fields.get('service', ''),
                     'scope': 'repository:library/alpine:pull'}
            url = realm + ('&' if '?' in realm else '?') + urlencode(query)
            # Anonymous bearer tokens are protocol handshakes, not account login.
            with opener.open(Request(url, headers={'User-Agent': headers['User-Agent']}),
                             timeout=min(8, remaining)) as r:
                auth = json.loads(r.read(65536))
            token = auth.get('token') or auth.get('access_token')
            if not token: raise ValueError('匿名认证失败')
            return get(path, limit, authenticate=False)
        with response:
            data = bytearray()
            while True:
                if time.monotonic() - start > 30: raise TimeoutError('测速超时')
                block = response.read(min(65536, limit + 1 - len(data)))
                if not block: break
                data.extend(block)
                if len(data) > limit: raise ValueError('下载超过测速大小上限')
            return bytes(data)
    try:
        manifest = json.loads(get('/v2/library/alpine/manifests/latest', 1024 * 1024))
        if 'manifests' in manifest:
            matches = [x for x in manifest['manifests']
                       if x.get('platform', {}).get('os') == 'linux'
                       and x.get('platform', {}).get('architecture') == arch]
            if not matches: raise ValueError('无匹配架构')
            digest = matches[0]['digest']
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest): raise ValueError('无效摘要')
            raw = get('/v2/library/alpine/manifests/' + digest, 1024 * 1024)
            if hashlib.sha256(raw).hexdigest() != digest[7:]: raise ValueError('清单校验失败')
            manifest = json.loads(raw)
        layer = manifest['layers'][0]
        digest = layer['digest']
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest): raise ValueError('无效层摘要')
        if not 0 < layer['size'] <= 16 * 1024 * 1024: raise ValueError('镜像层过大')
        raw = get('/v2/library/alpine/blobs/' + digest, 16 * 1024 * 1024)
        if len(raw) != layer['size'] or hashlib.sha256(raw).hexdigest() != digest[7:]:
            raise ValueError('镜像层校验失败')
        elapsed = time.monotonic() - start
        return {'url': base, 'seconds': round(elapsed, 3),
                'bytes': len(raw), 'bytes_per_second': len(raw) / elapsed}
    except Exception as error:
        # Never print anonymous tokens or HTTP response bodies.
        return {'url': base, 'error': type(error).__name__}

def rank(results):
    return sorted((r for r in results if 'bytes_per_second' in r),
                  key=lambda r: r['bytes_per_second'], reverse=True)[:3]

if __name__ == '__main__':
    with ThreadPoolExecutor(max_workers=5) as pool:
        results = list(pool.map(lambda url: probe(url, sys.argv[2]), CANDIDATES))
    for result in results:
        if 'error' in result:
            print('跳过：{}（{}）'.format(result['url'], result['error']), file=sys.stderr)
        else:
            print('可用：{} {:.2f} MiB/s（含清单/认证耗时）'.format(
                result['url'], result['bytes_per_second'] / 1024**2), file=sys.stderr)
    selected = [r['url'] for r in rank(results)]
    Path(sys.argv[1]).write_text(json.dumps({'selected': selected, 'results': results}, indent=2))
    if not selected: raise SystemExit('所有免费匿名源测速失败；保留现有 Docker 镜像配置')
PY
}

docker_mirrors() {
  say '匿名实测免费 Docker Hub 镜像源，按本机下载速度排序'
  if docker_mirror_probe; then docker_probe_rc=0; else docker_probe_rc=$?; fi
  if [ "$docker_probe_rc" -ne 0 ]; then
    [ ! -f "$TMP/docker-mirrors.json" ] || cp "$TMP/docker-mirrors.json" "$STATE/docker-mirror-probe.json"
    return "$docker_probe_rc"
  fi
  cp "$TMP/docker-mirrors.json" "$STATE/docker-mirror-probe.json" || return 1
  sudo install -d -m 0755 /etc/docker || return 1
  if sudo test -e /etc/docker/daemon.json; then
    sudo cat /etc/docker/daemon.json > "$TMP/docker-daemon.original" || return 1
  else
    printf '{}\n' > "$TMP/docker-daemon.original"
  fi
  python3 - "$TMP/docker-daemon.original" "$TMP/docker-mirrors.json" "$TMP/docker-daemon.new" <<'PY'
# ubuntu-init Docker daemon merge: preserve unrelated options; reject invalid input.
from pathlib import Path
import json, sys
config = json.loads(Path(sys.argv[1]).read_text())
if not isinstance(config, dict): raise SystemExit('daemon.json 必须是 JSON 对象')
mirrors = json.loads(Path(sys.argv[2]).read_text())['selected']
if not mirrors or not all(isinstance(x, str) and x.startswith('https://') for x in mirrors):
    raise SystemExit('没有通过检测的 HTTPS 镜像源')
config['registry-mirrors'] = list(dict.fromkeys(mirrors))
Path(sys.argv[3]).write_text(json.dumps(config, indent=2) + '\n')
PY
  [ "$?" -eq 0 ] || return 1
  sudo dockerd --validate --config-file "$TMP/docker-daemon.new" || return 1
  if python3 - "$TMP/docker-daemon.original" "$TMP/docker-daemon.new" <<'PYDOCKERCOMPARE'
import json, sys
raise SystemExit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))
PYDOCKERCOMPARE
  then
    if sudo docker info --format '{{json .RegistryConfig.Mirrors}}' > "$TMP/docker-mirrors.active" &&
        python3 - "$TMP/docker-mirrors.json" "$TMP/docker-mirrors.active" <<'PYDOCKERACTIVE'
import json, sys
expected = json.load(open(sys.argv[1]))['selected']
active = json.load(open(sys.argv[2]))
raise SystemExit([x.rstrip('/') for x in active] != [x.rstrip('/') for x in expected])
PYDOCKERACTIVE
    then
      say 'Docker 镜像源配置与运行状态一致，跳过写入和热重载。'
      record_step_event skip
      return 0
    fi
  fi
  if ! sudo test -e /etc/docker/daemon.json.before-ubuntu-init && \
      ! sudo test -e /etc/docker/daemon.json.before-ubuntu-init.absent; then
    if sudo test -e /etc/docker/daemon.json; then
      sudo cp -a /etc/docker/daemon.json /etc/docker/daemon.json.before-ubuntu-init || return 1
    else
      sudo touch /etc/docker/daemon.json.before-ubuntu-init.absent || return 1
    fi
  fi
  # Keep a per-run snapshot for rollback, distinct from the first-install backup.
  if sudo test -e /etc/docker/daemon.json; then daemon_existed=yes; else daemon_existed=no; fi
  sudo install -m 0644 "$TMP/docker-daemon.new" /etc/docker/daemon.json.ubuntu-init-new || return 1
  sudo mv /etc/docker/daemon.json.ubuntu-init-new /etc/docker/daemon.json || return 1
  if sudo systemctl reload docker; then
    # SIGHUP reload is asynchronous: check the daemon's actual state, not only exit status.
    for attempt in 1 2 3 4 5; do
      if sudo docker info --format '{{json .RegistryConfig.Mirrors}}' > "$TMP/docker-mirrors.active" && \
          python3 - "$TMP/docker-mirrors.json" "$TMP/docker-mirrors.active" <<'PY'
import json, sys
expected = json.load(open(sys.argv[1]))['selected']
active = json.load(open(sys.argv[2]))
raise SystemExit([x.rstrip('/') for x in active] != [x.rstrip('/') for x in expected])
PY
      then
        record_step_event change
        printf 'Docker 镜像源已生效；测速报告：%s/docker-mirror-probe.json\n' "$STATE"
        return 0
      fi
      sleep 1
    done
  fi
  warn 'Docker 未成功加载新镜像源，恢复本轮修改前的配置。'
  if [ "$daemon_existed" = yes ]; then
    sudo install -m 0644 "$TMP/docker-daemon.original" /etc/docker/daemon.json || return 1
  else
    sudo unlink /etc/docker/daemon.json || return 1
  fi
  sudo systemctl reload docker || warn '恢复后热重载失败，请检查 Docker 日志。'
  return 1
}

docker_engine() {
  say '安装 Docker Engine、CLI、containerd、Compose 和 Buildx（使用 sudo）'
  apt install -y --no-install-recommends ca-certificates curl || return 1
  conflicts=''
  for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q '^install ok installed$'; then
      conflicts="$conflicts $package"
    fi
  done
  if [ -n "$conflicts" ]; then
    confirm_update "检测到冲突包：$conflicts。是否移除这些软件包并安装 Docker CE（不清除容器数据）？" y || return 1
  fi
  docker_check 'Docker 软件包安装或仓库配置失败' '检查上方 APT/下载错误，确认代理可用后重跑' docker_packages "$conflicts" || return 1
  say '启动并启用 Docker 系统服务，验证 sudo Docker / Compose / Buildx'
  docker_check 'Docker 服务启动失败' '运行 sudo systemctl status docker --no-pager 和 sudo journalctl -u docker -n 50 --no-pager' sudo systemctl enable --now docker || return 1
  docker_check 'Docker version 系统验证失败' '检查上方错误；运行 sudo docker version，确认 Engine 和插件安装完整' sudo docker version --format '{{.Server.Version}}' || return 1
  docker_check 'Docker compose 系统验证失败' '检查上方错误；运行 sudo docker version，确认 Engine 和插件安装完整' sudo docker compose version || return 1
  docker_check 'Docker buildx 系统验证失败' '检查上方错误；运行 sudo docker version，确认 Engine 和插件安装完整' sudo docker buildx version || return 1
  printf 'Docker Engine、Compose 和 Buildx 已安装并通过 sudo 验证。\n'
  docker_check 'Docker 免 sudo 访问失败' '执行 id 和 ls -l /var/run/docker.sock 检查组权限；注销重登录后运行 docker version；检查 DOCKER_HOST、DOCKER_CONTEXT 是否指向其他服务' docker_user_access || return 1
  printf 'Docker Engine、Compose、Buildx 已就绪，并通过免 sudo 验证。\n'
}

docker_mirror_setup() {
  docker_check 'Docker 服务不可用，无法配置镜像源' '先处理 Docker 项目的错误' sudo docker version --format '{{.Server.Version}}' || return 1
  docker_check 'Docker 镜像源测速或配置失败' '检查上方各镜像源错误及 ~/.local/state/ubuntu-init/docker-mirror-probe.json；确认直连网络可用后重跑，原配置已保留或恢复，Docker 安装不受影响' docker_mirrors
}

# Refresh group access in a child process without changing socket permissions.
docker_user_access() {
  docker_user=$(id -un) || return 1
  if ! id -nG "$docker_user" | tr ' ' '\n' | grep -qx docker; then
    sudo groupadd -f docker || return 1
    sudo usermod -aG docker "$docker_user" || return 1
    record_step_event change
  fi
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    docker version --format '{{.Server.Version}}' || return 1
    docker compose version || return 1
    docker buildx version || return 1
  else
    # sudo initializes the target user's supplementary groups from the account
    # database. The target is explicitly this ordinary user, never root.
    sudo -u "$docker_user" -- docker version --format '{{.Server.Version}}' || return 1
    sudo -u "$docker_user" -- docker compose version || return 1
    sudo -u "$docker_user" -- docker buildx version || return 1
    DOCKER_GROUP_REFRESH=yes
  fi
  printf 'Docker、Compose 和 Buildx 免 sudo 验证通过；安装结束后的 Zsh 可直接使用。其他已打开终端需注销重登录。\n'
}

# Keep per-run repository snapshots until the accepted package transaction succeeds.
# A preparation/download failure restores sources and never uninstalls old Docker.
docker_packages() (
  conflicts=$1
  snapshot=$(mktemp -d "$TMP/docker-source.XXXXXX") || return 1
  for name in docker.list docker.sources docker.asc; do
    case "$name" in
      docker.asc) path=/etc/apt/keyrings/$name ;;
      *) path=/etc/apt/sources.list.d/$name ;;
    esac
    if sudo test -e "$path"; then
      sudo cp -a "$path" "$snapshot/$name" || return 1
    else
      : > "$snapshot/$name.absent" || return 1
    fi
  done
  restore_docker_sources() {
    for name in docker.list docker.sources docker.asc; do
      case "$name" in
        docker.asc) path=/etc/apt/keyrings/$name ;;
        *) path=/etc/apt/sources.list.d/$name ;;
      esac
      if [ -f "$snapshot/$name.absent" ]; then
        sudo rm -f "$path" || warn "无法移除本轮新建的软件源文件：$path"
      else
        sudo cp -a "$snapshot/$name" "$path" || warn "无法恢复软件源：$path；备份位于 $snapshot"
      fi
    done
  }
  trap restore_docker_sources EXIT
  trap 'exit 130' HUP INT TERM
  say '下载 Docker 官方仓库签名密钥'
  download https://download.docker.com/linux/ubuntu/gpg "$TMP/docker.asc" || return 1
  sudo install -d -m 0755 /etc/apt/keyrings || return 1
  sudo install -m 0644 "$TMP/docker.asc" /etc/apt/keyrings/docker.asc || return 1
  # Keep one active Docker repository definition to avoid Signed-By conflicts.
  if sudo test -f /etc/apt/sources.list.d/docker.sources; then
    if ! sudo test -f /etc/apt/sources.list.d/docker.sources.before-ubuntu-init; then
      sudo cp -a /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/docker.sources.before-ubuntu-init || return 1
    fi
    sudo rm -f /etc/apt/sources.list.d/docker.sources || return 1
  fi
  if sudo test -f /etc/apt/sources.list.d/docker.list && ! sudo test -f /etc/apt/sources.list.d/docker.list.before-ubuntu-init; then
    sudo cp -a /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.before-ubuntu-init || return 1
  fi
  say '测速 Docker 软件包仓库，失败时按顺序切换下一个'
  docker_apt_source > "$TMP/docker-repositories" || return 1
  repository_ready=no
  while IFS= read -r docker_repository; do
    [ -n "$docker_repository" ] || continue
    printf '尝试 Docker 软件包源：%s\n' "$docker_repository"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s %s stable\n' "$ARCH" "$docker_repository" "$CODENAME" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null || return 1
    if ! apt_update; then warn '仓库索引刷新失败，切换下一个。'; continue; fi
    repository_ready=yes
    for package in docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; do
      candidate=$(candidate_package_version "$package")
      case "$candidate" in ''|'(none)') repository_ready=no; warn "$package 没有可安装版本，切换仓库。" ;; esac
    done
    [ "$repository_ready" = yes ] && break
  done < "$TMP/docker-repositories"
  [ "$repository_ready" = yes ] || { warn '所有 Docker 软件包仓库均不可用。'; return 1; }
  APT_REPLACEMENTS="$conflicts" APT_PREFETCH=yes apt install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  trap - EXIT
)

swap_setup() {
  active=$(sudo swapon --show --noheadings --output NAME) || return 1
  if [ -n "$active" ]; then
    if printf '%s\n' "$active" | grep -qx /swapfile && [ -f "$STATE/swapfile-managed" ]; then
      swap_persist || return 1
      return 0
    fi
    printf '系统已有活动 swap，保持现状：%s\n' "$active"
    record_step_event skip
    return 0
  fi
  filesystem=$(findmnt -n -o FSTYPE / 2>/dev/null || printf unknown)
  case "$filesystem" in btrfs) warn '根文件系统是 Btrfs；本版不自动创建 swapfile。'; record_step_event skip; return 0 ;; esac
  if [ -e /swapfile ] || [ -L /swapfile ]; then
    sudo swapon /swapfile || { warn '/swapfile 已存在但无法启用；为避免覆盖，停止此项。'; return 1; }
    : > "$STATE/swapfile-managed" || return 1
    record_step_event change
    swap_persist
    return $?
  fi
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  [ -n "$mem_kb" ] || return 1
  target_kb=$((mem_kb * 2))
  cap_kb=$((8 * 1024 * 1024))
  min_kb=$((2 * 1024 * 1024))
  [ "$target_kb" -le "$cap_kb" ] || target_kb=$cap_kb
  [ "$target_kb" -ge "$min_kb" ] || target_kb=$min_kb
  free_kb=$(df -Pk / | awk 'NR==2 {print $4}')
  reserve_kb=$((2 * 1024 * 1024))
  if [ "$free_kb" -lt $((target_kb + reserve_kb)) ]; then
    warn "可用磁盘空间不足以安全创建 ${target_kb}KB swap（需额外保留 2GB），跳过。"
    record_step_event skip
    return 0
  fi
  printf '按当前内存计算 swap 目标：约 %s GB（上限 8GB，不支持休眠恢复）。\n' "$((target_kb / 1024 / 1024))"
  # Exclusive creation and restrictive permissions precede allocation. An error
  # or signal while preparing the new file removes only this invocation's file.
  sudo sh -c '
    set -eu
    umask 077
    set -C
    : > /swapfile
    trap '\''rm -f /swapfile'\'' EXIT
    trap '\''exit 130'\'' HUP INT TERM
    fallocate -l "$1" /swapfile
    mkswap /swapfile >/dev/null
    trap - EXIT
  ' ubuntu-init "${target_kb}K" || return 1
  # Keep this marker if swapon or fstab fails, so rerunning can repair persistence.
  : > "$STATE/swapfile-managed" || return 1
  sudo swapon /swapfile || return 1
  record_step_event change
  swap_persist
}

swap_persist() {
  # Treat an unreadable fstab as an error, not as a missing entry.
  sudo cat /etc/fstab > "$TMP/swap-fstab" || return 1
  if ! grep -Eq '^[[:space:]]*/swapfile[[:space:]]+[^[:space:]]+[[:space:]]+swap[[:space:]]' "$TMP/swap-fstab"; then
    printf '%s\n' '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null || return 1
    record_step_event change
  else
    record_step_event skip
  fi
}

launcher_extension() {
  extension_uuid=$1
  [ "$DE" = gnome ] || return 0
  shell_version=$(gnome-shell --version | awk '{print $3}' | cut -d. -f1) || return 1
  download "https://extensions.gnome.org/extension-info/?uuid=$extension_uuid&shell_version=$shell_version" "$TMP/launcher-extension.json" || return 1
  extension_url=$(python3 - "$TMP/launcher-extension.json" "$shell_version" "$extension_uuid" <<'PY'
import json, sys
info = json.load(open(sys.argv[1]))
version = info.get('shell_version_map', {}).get(sys.argv[2], {}).get('pk')
if info.get('uuid') != sys.argv[3]:
    raise SystemExit('扩展站返回的 UUID 不匹配')
if version is None:
    raise SystemExit(3)
if not isinstance(version, int):
    raise SystemExit('扩展版本数据无效')
print('https://extensions.gnome.org/download-extension/' + sys.argv[3] + '.shell-extension.zip?version_tag=' + str(version))
PY
  ) || {
    rc=$?
    [ "$rc" -ne 3 ] || warn "当前 GNOME $shell_version 不支持 $extension_uuid，跳过该扩展。"
    return "$rc"
  }
  download "$extension_url" "$TMP/launcher-extension.zip" || return 1
  # Validate the archive and declared GNOME compatibility before installing code.
  python3 - "$TMP/launcher-extension.zip" "$shell_version" "$extension_uuid" <<'PY'
import json, sys, zipfile
from pathlib import PurePosixPath
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        p = PurePosixPath(name)
        if p.is_absolute() or '..' in p.parts: raise SystemExit('不安全的扩展路径')
    meta = json.loads(z.read('metadata.json'))
    if meta['uuid'] != sys.argv[3] or sys.argv[2] not in meta['shell-version']:
        raise SystemExit('扩展与当前 GNOME 不匹配')
PY
  [ "$?" -eq 0 ] || return 1
  if extension_action "$TMP/launcher-extension.zip" "$extension_uuid"; then :; else
    rc=$?; [ "$rc" -eq 1 ] && return 0; return 1
  fi
  backup_user_file "$HOME/.local/share/gnome-shell/extensions/$extension_uuid" || return 1
  gnome-extensions install --force "$TMP/launcher-extension.zip" || return 1
  # A newly installed extension is discovered by GNOME only on the next login.
  python3 - "$extension_uuid" <<'PY'
import sys
from gi.repository import Gio
s = Gio.Settings.new('org.gnome.shell')
uuid = sys.argv[1]
s.set_strv('enabled-extensions', list(dict.fromkeys(s.get_strv('enabled-extensions') + [uuid])))
s.set_strv('disabled-extensions', [x for x in s.get_strv('disabled-extensions') if x != uuid])
Gio.Settings.sync()
PY
}

# Keep a working launcher running unless its binary or service environment changed.
launcher_service_setup() (
  vicinae_updated=${1:-no}
  runtime="$HOME/.config/systemd/user/vicinae.service.d/runtime.conf"
  mkdir -p "$(dirname "$runtime")" || return 1
  backup_user_file "$runtime" || return 1
  python3 - "$TMP/vicinae-runtime.conf" <<'PYVICINAEPATH'
from pathlib import Path
import os, sys
home = Path.home()
paths = [str(home / '.local/bin')]
nodes = sorted((home / '.nvm/versions/node').glob('*/bin'), key=lambda p: p.stat().st_mtime, reverse=True)
if nodes: paths.append(str(nodes[0]))
paths.extend(os.environ['PATH'].split(':'))
value = ':'.join(dict.fromkeys(paths)).replace('%', '%%').replace('\\', '\\\\').replace('"', '\\"')
Path(sys.argv[1]).write_text('[Service]\nEnvironment="PATH=' + value + '"\n')
PYVICINAEPATH
  [ "$?" -eq 0 ] || return 1
  runtime_changed=no
  if ! cmp -s "$TMP/vicinae-runtime.conf" "$runtime"; then
    apply_user_config "$TMP/vicinae-runtime.conf" "$runtime" || return 1
    runtime_changed=yes
  fi
  if [ "$runtime_changed" = yes ] ||
      [ "$(systemctl --user show -p NeedDaemonReload --value vicinae.service)" = yes ]; then
    systemctl --user daemon-reload || return 1
    runtime_changed=yes
  fi
  update-desktop-database "$HOME/.local/share/applications" || return 1
  xdg-mime default vicinae-url-handler.desktop x-scheme-handler/vicinae || return 1
  if ! systemctl --user is-enabled --quiet vicinae.service; then
    systemctl --user enable vicinae.service || return 1
    record_step_event change
  fi
  if ! systemctl --user is-active --quiet vicinae.service; then
    systemctl --user start vicinae.service || return 1
    record_step_event change
  elif [ "$vicinae_updated" = yes ] || [ "$runtime_changed" = yes ]; then
    systemctl --user restart vicinae.service || return 1
    record_step_event change
  else
    say 'Vicinae：服务配置正确且正在运行，跳过重启。'
    record_step_event skip
  fi
  "$HOME/.local/bin/vicinae" version || return 1
  systemctl --user is-active --quiet vicinae.service
)

launcher_setup() {
  [ "$DE" = gnome ] || { warn "当前桌面不支持 Copyous/Vicinae 自动适配，跳过。"; return 0; }
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || {
    warn 'Copyous/Vicinae 自动适配需要已登录的 GNOME 桌面会话。'; return 1;
  }
  apt install -y --no-install-recommends python3-gi gir1.2-gtk-3.0 gir1.2-gda-5.0 \
    gir1.2-gsound-1.0 jq desktop-file-utils xdg-utils || return 1
  copyous_supported=1
  vicinae_extension_supported=1
  launcher_extension copyous@boerdereinar.dev || {
    rc=$?; [ "$rc" -eq 3 ] || return "$rc"
    copyous_supported=0
  }
  launcher_extension vicinae@dagimg-dot || {
    rc=$?; [ "$rc" -eq 3 ] || return "$rc"
    vicinae_extension_supported=0
  }
  download https://api.github.com/repos/vicinaehq/vicinae/releases/latest "$TMP/vicinae-release.json" || return 1
  python3 - "$TMP/vicinae-release.json" "$ARCH" > "$TMP/vicinae-asset" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1]))
arch = {'amd64': 'x86_64', 'arm64': 'aarch64'}[sys.argv[2]]
asset = next(a for a in release['assets'] if a['name'] == f'Vicinae-{arch}.AppImage')
url, digest = asset['browser_download_url'], asset.get('digest', '')
if not url.startswith('https://github.com/vicinaehq/vicinae/releases/download/') or not re.fullmatch('sha256:[0-9a-f]{64}', digest):
    raise SystemExit('官方发布缺少可验证的 SHA-256，停止安装')
print(url)
print(digest.split(':')[1])
PY
  [ "$?" -eq 0 ] || return 1
  latest_vicinae=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"].lstrip("v"))' "$TMP/vicinae-release.json") || return 1
  current_vicinae=''
  if [ -x "$HOME/.local/bin/vicinae" ]; then
    current_vicinae=$(program_version "$HOME/.local/bin/vicinae" version)
    [ -n "$current_vicinae" ] || { warn '无法读取已有 Vicinae 版本，保留现有安装。'; return 1; }
  elif command -v vicinae >/dev/null 2>&1; then
    current_vicinae=$(program_version vicinae version)
    [ -n "$current_vicinae" ] || { warn '无法读取已有 Vicinae 版本，保留现有安装。'; return 1; }
  fi
  vicinae_updated=no
  if version_action Vicinae "$current_vicinae" "$latest_vicinae"; then
    asset_url=$(sed -n '1p' "$TMP/vicinae-asset")
    asset_sha=$(sed -n '2p' "$TMP/vicinae-asset")
    curl --fail --location --connect-timeout 8 --max-time 600 --retry 2 \
      "$asset_url" -o "$TMP/Vicinae.AppImage" || return 1
    printf '%s  %s\n' "$asset_sha" "$TMP/Vicinae.AppImage" | sha256sum -c - || return 1
    download https://vicinae.com/install "$TMP/vicinae-install.sh" || return 1
    bash "$TMP/vicinae-install.sh" --prefix "$HOME/.local" --appimage "$TMP/Vicinae.AppImage" || return 1
    vicinae_updated=yes
  else
    rc=$?; [ "$rc" -eq 1 ] || return 1
  fi
  python3 - "$STATE" "$copyous_supported" "$vicinae_extension_supported" <<'PY'
# ubuntu-init Copyous/Vicinae configuration
from pathlib import Path
import json, os, shlex, sys
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gio, Gtk
home = Path.home()
backup = Path(sys.argv[1]) / 'desktop-backup/launcher-settings.json'
backup.parent.mkdir(parents=True, exist_ok=True)
changes = []
def save(settings, key, value):
    if settings.get_value(key).equal(value): return
    changes.append({'schema': settings.props.schema_id, 'path': settings.props.path,
                    'key': key, 'value': settings.get_value(key).unpack()})
    if not backup.exists():
        # Persist the original snapshot before each mutation; finalize below.
        pending.write_text(json.dumps(changes, indent=2))
    if not settings.set_value(key, value): raise RuntimeError(key)
pending = backup.with_suffix('.pending.json')
def extension(uuid, schema):
    directory = home / '.local/share/gnome-shell/extensions' / uuid / 'schemas'
    source = Gio.SettingsSchemaSource.new_from_directory(str(directory), Gio.SettingsSchemaSource.get_default(), False)
    return Gio.Settings.new_full(source.lookup(schema, False), None, None)
copyous_supported = len(sys.argv) < 3 or sys.argv[2] == '1'
vicinae_extension_supported = len(sys.argv) < 4 or sys.argv[3] == '1'
from gi.repository import GLib
if copyous_supported:
    copyous = extension('copyous@boerdereinar.dev', 'org.gnome.shell.extensions.copyous')
    save(copyous, 'indicator-display', GLib.Variant('s', 'hidden'))
    save(copyous, 'open-clipboard-dialog-shortcut', GLib.Variant('as', ['<Super>v']))
if vicinae_extension_supported:
    vicinae = extension('vicinae@dagimg-dot', 'org.gnome.shell.extensions.vicinae')
    save(vicinae, 'show-status-indicator', GLib.Variant('b', False))
media = Gio.Settings.new('org.gnome.settings-daemon.plugins.media-keys')
path = '/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/vicinae/'
paths = media.get_strv('custom-keybindings')
targets = {Gtk.accelerator_parse(x) for x in (['<Super>v'] if copyous_supported else []) + ['<Super>space']}
for schema in ['org.gnome.desktop.wm.keybindings', 'org.gnome.shell.keybindings',
               'org.gnome.settings-daemon.plugins.media-keys']:
    settings = Gio.Settings.new(schema)
    for key in settings.props.settings_schema.list_keys():
        value = settings.get_value(key)
        if value.get_type_string() != 'as' or key == 'custom-keybindings': continue
        old = value.unpack()
        new = [x for x in old if Gtk.accelerator_parse(x) not in targets]
        if new != old: save(settings, key, GLib.Variant('as', new))
for entry in paths:
    settings = Gio.Settings.new_with_path('org.gnome.settings-daemon.plugins.media-keys.custom-keybinding', entry)
    if entry != path and Gtk.accelerator_parse(settings.get_string('binding')) in targets:
        save(settings, 'binding', GLib.Variant('s', ''))
settings = Gio.Settings.new_with_path('org.gnome.settings-daemon.plugins.media-keys.custom-keybinding', path)
for key, value in {'name': 'Vicinae 启动器', 'command': shlex.quote(str(home / '.local/bin/vicinae')) + ' toggle', 'binding': '<Super>space'}.items():
    save(settings, key, GLib.Variant('s', value))
save(media, 'custom-keybindings', GLib.Variant('as', list(dict.fromkeys(paths + [path]))))
Gio.Settings.sync()
if changes and not backup.exists(): pending.replace(backup)
# Absolute desktop commands also work when ~/.local/bin is absent from the GUI PATH.
desktop_changed = False
for desktop in (home / '.local/share/applications').glob('vicinae*.desktop'):
    old = desktop.read_text()
    new = old.replace('Exec=vicinae', 'Exec=' + str(home / '.local/bin/vicinae'))
    if new != old:
        desktop.write_text(new)
        desktop_changed = True
if os.environ.get('STEP_EVENTS'):
    with open(os.environ['STEP_EVENTS'], 'a') as events:
        events.write('change\n' if changes or desktop_changed else 'skip\n')
PY
  [ "$?" -eq 0 ] || return 1
  launcher_service_setup "$vicinae_updated" || return 1
  if [ "$copyous_supported" -eq 1 ]; then printf 'Copyous: Super+V，隐藏顶栏图标。\n'; fi
  printf 'Vicinae: Super+空格，登录自启；兼容的扩展已配置隐藏图标。不兼容的扩展已跳过，请保存工作后注销重登录以加载新扩展。\n'
}

git_ssh_key_setup() (
  command -v git >/dev/null 2>&1 || { warn 'Git 尚未安装，跳过 SSH 密钥生成。'; return 1; }
  git_name=$(git config --global --get user.name) || git_name=''
  case "$git_name" in
    *[![:space:]]*) say 'Git 全局用户名已配置，跳过。'; record_step_event skip ;;
    *)
      while :; do
        printf '请输入 Git 用户名（必填）：'
        IFS= read -r git_name || { warn '无法读取用户名，停止 Git 配置。'; return 1; }
        case "$git_name" in
          *[![:space:]]*) break ;;
          *) warn '用户名不能为空，请重新输入。' ;;
        esac
      done
      git config --global user.name "$git_name" || return 1
      record_step_event change ;;
  esac
  ssh_email=$(git config --global --get user.email) || ssh_email=''
  case "$ssh_email" in
    *[![:space:]]*) say 'Git 全局邮箱已配置，跳过。'; record_step_event skip ;;
    *)
      printf '%s\n' '邮箱请使用 GitHub 已绑定的邮箱或 GitHub 提供的 noreply 邮箱。'
      while :; do
        printf '请输入 Git 邮箱（必填，同时用于 SSH 密钥）：'
        IFS= read -r ssh_email || { warn '无法读取邮箱，停止 Git 配置。'; return 1; }
        case "$ssh_email" in
          *[![:space:]]*) break ;;
          *) warn '邮箱不能为空，请重新输入。' ;;
        esac
      done
      git config --global user.email "$ssh_email" || return 1
      record_step_event change ;;
  esac
  for key in "$HOME"/.ssh/id_*; do
    if [ -f "$key" ]; then
      say "检测到已有 SSH 密钥文件：$key；跳过生成，保留原文件。"
      record_step_event skip
      return 0
    fi
  done
  command -v ssh-keygen >/dev/null 2>&1 || { warn '缺少 ssh-keygen，请安装 openssh-client 后重试。'; return 1; }
  printf '%s\n' '即将在当前终端生成 SSH 公钥和私钥，请自行输入保存位置和密码（可按回车使用默认值）：'
  printf 'ssh-keygen -t ed25519 -C "%s"\n' "$ssh_email"
  ssh-keygen -t ed25519 -C "$ssh_email" || return 1
  record_step_event change
  printf 'SSH 密钥生成完成；公钥为所选私钥路径加 .pub，请妥善保存私钥。\n'
)

terminal_tools_setup() {
  apt install -y --no-install-recommends curl wget git openssh-client gpg zsh vim htop fzf ranger net-tools tmux flameshot
}

obs_studio() {
  say '安装 OBS Studio（Ubuntu 软件源）'
  apt install -y --no-install-recommends obs-studio obs-plugins || return 1
  if [ "$DE" = gnome ] && [ "$SESSION_TYPE" = wayland ]; then
    apt install -y --no-install-recommends xdg-desktop-portal xdg-desktop-portal-gnome || return 1
  fi
  command -v obs >/dev/null 2>&1 || return 1
  printf 'OBS Studio 已安装，可从应用菜单或运行 obs 打开。Wayland 录屏请选择“屏幕捕获（PipeWire）”来源，并在系统弹窗中授权。\n'
}

enter_configured_zsh() {
  # Replace the installer, keeping the user's terminal attached to a shell
  # whose interactive startup loads .zshrc and its aliases.
  [ -t 0 ] && [ -t 1 ] || return 0
  command -v zsh >/dev/null 2>&1 || return 1
  [ -r "${ZDOTDIR:-$HOME}/.zshrc" ] || return 1
  printf '\n安装结束，自动进入已加载配置的 Zsh，可直接使用 ra 和 ter。\n'
  cleanup
  TMP=""
  if [ "${DOCKER_GROUP_REFRESH:-no}" = yes ]; then
    shell_user=$(id -un) || return 1
    shell_zsh=$(command -v zsh) || return 1
    exec sudo -u "$shell_user" -- "$shell_zsh" -i
  fi
  exec zsh -i
}

main() {
  preflight
  results_init || die '无法初始化执行统计。'
  printf '\nUbuntu 初始化器 %s\n自动检查全部软件：缺失安装、最新跳过、有更新询问 [Y/n]。\n' "$INSTALLER_VERSION"
  optional '家目录标准文件夹英文名称' user_dirs_setup
  if [ ! -f "$STATE/proxy-tool" ]; then
    say '第一阶段：配置 GitHub hosts'
    run_step 'GitHub hosts' github_hosts || die 'GitHub hosts 配置失败；修复网络后重新运行。'
    say '第一阶段：探测并配置国内 APT 镜像'
    run_step 'APT 源' set_mirror || die 'APT 镜像配置失败。'
    run_step 'APT 更新升级与清理' apt_maintenance || die 'APT 更新、升级或清理失败，已停止；处理上面的错误后重新运行。'
    say '第一阶段：选择并安装代理工具'
    run_step '代理工具安装' proxy_setup || die '代理工具尚未安装完成；重新运行将重试第一阶段。'
    say '第一阶段已完成，本次到此结束。'
    printf '请先配置所选代理工具的内核、订阅和节点并启动代理，再次执行同一个脚本继续第二阶段。\n'
    print_summary
    return $?
  fi

  # The saved tool records first-stage installation, not the currently running proxy.
  say '第二阶段：验证当前本地代理并配置环境'
  run_step '本地代理验证' configure_proxy || die '代理尚不可用；请先启动并配置代理，再重新运行。'
  run_step 'APT 索引' apt_update || die '通过代理刷新 APT 索引失败，请处理后重新运行。'
  say '准备 zsh，保留用户配置，已有旧脚本配置迁移到官方模板'
  run_step 'zsh 软件包' apt install -y --no-install-recommends zsh || die 'zsh 安装失败，无法继续配置环境。'
  run_step '.zshrc 配置' zsh_configure || die '.zshrc 准备失败。'
  run_step '终端环境清理和加载' cleanup_legacy_proxy_env || die '旧代理配置清理或 .zshrc 加载失败。'
  optional '终端和截图工具' terminal_tools_setup
  optional 'Git 配置与 SSH 密钥' git_ssh_key_setup
  optional 'Vim 配置' vim_setup
  optional 'Oh My Zsh' zsh_setup
  optional 'Caps/Esc 互换（keyd）' keyboard_setup
  optional 'Flameshot 截图' screenshot_setup
  optional Chrome chrome
  optional 'Node.js 环境' nvm_node
  optional 'ChatGPT 桌面客户端' chatgpt_desktop
  optional 'Antigravity IDE' antigravity_ide
  optional 'Zed 编辑器' zed_editor
  optional 'Rust 开发环境' apt install -y --no-install-recommends cargo rustc build-essential
  optional 'TRAE CN' trae_cn
  optional 'Copyous/Vicinae' launcher_setup
  optional 'OBS Studio' obs_studio
  optional LocalSend localsend
  optional Docker docker_engine
  optional 'Docker 镜像源' docker_mirror_setup
  optional '顶部监控和 System Monitor' sysmonitor
  optional 'WowType 输入法' wowtype_setup
  optional swap swap_setup
  optional 'Remmina/scrcpy/VLC' apt install -y --no-install-recommends remmina remmina-plugin-rdp remmina-plugin-secret scrcpy vlc
  print_summary || return $?
  enter_configured_zsh
}

# Single execution entry point.
[ "$#" -eq 0 ] || die '无需参数，请直接执行此脚本。'
main
