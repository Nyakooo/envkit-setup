"""Proxy selection and release installation, without networking or desktop changes."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

FUNCTIONS = (Path(__file__).resolve().parents[1] / 'install-ubuntu.sh').read_text().split('\n# Single execution entry point.', 1)[0]


class ProxySetupTests(unittest.TestCase):
    def shell(self, code, answer='', root=None):
        with tempfile.TemporaryDirectory() as tmp:
            directory = str(root or tmp)
            result = subprocess.run(['sh', '-c', FUNCTIONS + '\nTMP="$1"; HOME="$1/home"; ARCH=amd64; STATE="$1/state"; mkdir -p "$STATE"; trap - EXIT\n' + code,
                                     'test', directory], input=answer, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_termihomo_path_in_new_shells(self):
        self.shell('''
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\\necho ready\\n' > "$HOME/.local/bin/termihomo"
chmod +x "$HOME/.local/bin/termihomo"
PATH=/usr/bin:/bin
termihomo_configure_path
termihomo_configure_path
for rc in "$HOME/.profile" "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ "$(grep -c '# BEGIN ubuntu-init local-bin' "$rc")" = 1 ]
  PATH=/usr/bin:/bin sh -c '. "$1"; termihomo' test "$rc" | grep -qx ready
done
''')

    def test_choice_and_invalid_retry(self):
        stub = 'flclash() { echo FLCLASH; }; termihomo_setup() { echo TERMIHOMO; }; proxy_setup'
        self.assertIn('FLCLASH', self.shell(stub, '\n'))
        self.assertIn('TERMIHOMO', self.shell(stub, 'invalid\n2\n'))
        self.shell('if proxy_setup; then exit 99; else [ "$?" = 2 ]; fi')

    def test_install_skip_and_decline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'release.tar.gz'
            content = b'#!/bin/sh\nprintf "Termihomo v1.2.3 linux/amd64\\n"\n'
            with tarfile.open(archive, 'w:gz') as tar:
                member = tarfile.TarInfo('termihomo')
                member.size = len(content)
                tar.addfile(member, io.BytesIO(content))
            manifest = {'tag_name': 'v1.2.3', 'assets': [{
                'name': 'termihomo-linux-amd64.tar.gz',
                'browser_download_url': 'https://github.com/Nyakooo/termihomo/releases/download/v1.2.3/termihomo-linux-amd64.tar.gz',
                'digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()}]}
            (root / 'release.json').write_text(json.dumps(manifest))
            stub = '''
mkdir -p "$HOME"
PATH=/usr/bin:/bin
sudo() {
 case "$1" in
  install) mkdir -p "$TMP/system-bin" ;;
  ln) ln -sf "$3" "$TMP/system-bin/termihomo" ;;
  *) return 99 ;;
 esac
}
download() {
 case "$1" in
  *releases/latest) cp "$TMP/release.json" "$2" ;;
  *.tar.gz) echo archive >> "$TMP/downloads"; cp "$TMP/release.tar.gz" "$2" ;;
  *) return 99 ;;
 esac
}
'''
            output = self.shell(stub + 'termihomo_install\ntermihomo_install\n[ "$(wc -l < "$TMP/downloads")" = 1 ]', root=root)
            self.assertIn('sh -c \'installer=$(curl -fsSL', output)
            self.assertIn('exec sh -c "$installer"', output)
            self.shell('PATH=/usr/bin:/bin; . "$HOME/.bashrc"; termihomo version', root=root)
            link = root / 'system-bin/termihomo'
            self.assertEqual(link.resolve(), root / 'home/.local/bin/termihomo')
            self.shell('PATH="$TMP/system-bin:/usr/bin:/bin"; termihomo version', root=root)
            binary = root / 'home/.local/bin/termihomo'
            binary.write_text('#!/bin/sh\necho "Termihomo v1.0.0 linux/amd64"\n')
            self.shell(stub + 'termihomo_install\n[ "$(wc -l < "$TMP/downloads")" = 1 ]', 'n\n', root)
            manifest['assets'][0]['digest'] = 'sha256:' + '0' * 64
            (root / 'release.json').write_text(json.dumps(manifest))
            self.shell(stub + 'if termihomo_install; then exit 99; fi\n"$HOME/.local/bin/termihomo" version | grep v1.0.0', 'y\n', root)

    def test_ticktop_install_skip_decline_and_checksum_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'release.tar.gz'
            content = b'#!/bin/sh\nprintf "Ticktop v1.2.3 linux/amd64\\n"\n'
            with tarfile.open(archive, 'w:gz') as tar:
                member = tarfile.TarInfo('ticktop')
                member.size = len(content)
                tar.addfile(member, io.BytesIO(content))
            manifest = {'tag_name': 'v1.2.3', 'assets': [{
                'name': 'ticktop-x86_64-unknown-linux-musl.tar.gz',
                'browser_download_url': 'https://github.com/Nyakooo/ticktop/releases/download/v1.2.3/ticktop-x86_64-unknown-linux-musl.tar.gz',
                'digest': 'sha256:' + hashlib.sha256(archive.read_bytes()).hexdigest()}]}
            (root / 'release.json').write_text(json.dumps(manifest))
            stub = '''
mkdir -p "$HOME"
PATH=/usr/bin:/bin
download() {
 case "$1" in
  *releases/latest) cp "$TMP/release.json" "$2" ;;
  *.tar.gz) echo archive >> "$TMP/downloads"; cp "$TMP/release.tar.gz" "$2" ;;
  *) return 99 ;;
 esac
}
'''
            output = self.shell(stub + 'ticktop_install\nticktop_install\n[ "$(wc -l < "$TMP/downloads")" = 1 ]', root=root)
            self.shell('PATH=/usr/bin:/bin; . "$HOME/.bashrc"; ticktop --version', root=root)
            binary = root / 'home/.local/bin/ticktop'
            binary.write_text('#!/bin/sh\necho "Ticktop v1.0.0 linux/amd64"\n')
            self.shell(stub + 'ticktop_install\n[ "$(wc -l < "$TMP/downloads")" = 1 ]', 'n\n', root)
            manifest['assets'][0]['digest'] = 'sha256:' + '0' * 64
            (root / 'release.json').write_text(json.dumps(manifest))
            self.shell(stub + 'if ticktop_install; then exit 99; fi\n"$HOME/.local/bin/ticktop" version | grep v1.0.0', 'y\n', root)

    def test_two_runs_stop_then_continue_and_proxy_failure_blocks(self):
        self.shell('''
mkdir -p "$HOME"
preflight() { :; }
github_hosts() { echo hosts >> "$TMP/order"; }
set_mirror() { echo mirror >> "$TMP/order"; }
apt_update() { echo apt >> "$TMP/order"; }
apt_raw() { printf "Inst fixture [1.0] (2.0)\\n"; }
apt() { echo "$*" >> "$TMP/order"; }
flclash() { echo flclash >> "$TMP/order"; }
configure_proxy() { echo verify >> "$TMP/order"; }
zsh_configure() { :; }
cleanup_legacy_proxy_env() { :; }
optional() {
 if [ "$2" = user_dirs_setup ]; then echo dirs >> "$TMP/user-dirs-calls"; elif [ "$2" = ticktop_install ]; then echo ticktop >> "$TMP/order"; else echo software >> "$TMP/order"; fi
}
chsh() { :; }
main
[ "$(cat "$TMP/order")" = "$(printf 'hosts\\nmirror\\napt\\nupgrade -y\\nautoremove -y\\nautoclean\\nflclash\\nticktop')" ]
[ "$(cat "$STATE/proxy-tool")" = FlClash ]
: > "$TMP/order"
printf 'Termihomo\\n' > "$STATE/proxy-tool"
configure_proxy() { [ "$#" -eq 0 ]; echo verify >> "$TMP/order"; }
main
[ "$(head -n 3 "$TMP/order")" = "$(printf 'verify\\nticktop\\napt')" ]
grep -q software "$TMP/order"
! grep -q hosts "$TMP/order"
: > "$TMP/order"
configure_proxy() { return 1; }
if (main); then exit 99; fi
[ ! -s "$TMP/order" ]
[ "$(wc -l < "$TMP/user-dirs-calls")" -eq 3 ]
''', 'y\n\n')

    def test_maintenance_stops_at_first_failed_command(self):
        self.shell('''
apt_update() { echo update >> "$TMP/maintenance"; }
apt_raw() { printf "Inst fixture [1.0] (2.0)\\n"; }
apt() {
 echo "$*" >> "$TMP/maintenance"
 case "$1" in upgrade) return 1 ;; esac
}
if apt_maintenance; then exit 99; fi
[ "$(cat "$TMP/maintenance")" = "$(printf 'update\\nupgrade -y')" ]
''', 'y\n')

    def test_current_port_does_not_require_tool_name(self):
        output = self.shell('''
DE=other; DESKTOP=test
curl() { printf '%s\\n' "$@" > "$TMP/curl-args"; }
cleanup_legacy_proxy_env() { [ "$http_proxy" = http://127.0.0.1:18080 ]; }
configure_proxy
[ "$PROXY_PORT" = 18080 ]
grep -q 'http://127.0.0.1:18080' "$TMP/curl-args"
grep -q -- '--noproxy' "$TMP/curl-args"
''', '18080\n')
        self.assertIn('127.0.0.1:18080 已验证', output)
        self.assertNotIn('请输入 Termihomo 的', output)


if __name__ == '__main__':
    unittest.main()
