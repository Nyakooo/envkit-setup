# envkit-setup

Ubuntu 桌面环境初始化安装器。项目入口为仓库根目录的 `install-ubuntu.sh`，测试位于 `tests/`。

交互式 POSIX `sh` 脚本，用于初始化 Ubuntu 桌面环境。面向 Ubuntu 24.04 / 26.04 GNOME；每次运行检查软件是否已安装以及是否有更新，所选代理工具配置完成并通过连通性检查后，才继续执行后续安装。

## 1. 支持范围与前置条件

| 项目 | 支持情况 |
| --- | --- |
| Ubuntu 24.04 | 主要目标，GNOME X11/Wayland |
| Ubuntu 26.04 | 支持 GNOME 50 / Wayland 的监控、System Monitor 和 Fcitx 5 桌面适配；其他软件仍需分别验证 |
| Ubuntu 22.04 | 当前未验证，脚本会在修改系统前停止 |
| 架构 | `amd64`、`arm64`；部分第三方桌面应用仅提供 `amd64` 安装包 |
| 其他桌面环境 | 基础工具和应用可继续安装；GNOME 键位、快捷键和系统代理设置会提示并跳过 |

运行前请确认：

- 在 Ubuntu 桌面终端中运行，保持终端打开并能输入选择。
- 当前用户可以使用 `sudo`，系统已有 `curl` 和 `python3`。
- 首次连接 GitHub 的网络可用。脚本必须先下载所选代理工具，不能用尚未安装的工具建立初始网络连接。

不要在整条命令前加 `sudo`。脚本只在需要系统权限时调用 `sudo`，用户配置会写入当前登录用户的主目录。

## 2. 一键运行

修改提交并推送到本仓库 `master` 分支后，可通过以下命令运行：

```sh
script=$(curl -fsSL --connect-timeout 8 --max-time 60 "https://raw.githubusercontent.com/Nyakooo/envkit-setup/master/install-ubuntu.sh") && [ -n "$script" ] && sh -c "$script"
```

在仓库根目录本地运行：

```sh
sh install-ubuntu.sh
```

脚本只有一个入口，无需任何参数，按本地状态分两个阶段执行：

1. **首次运行**：依次配置 GitHub hosts、APT 镜像源、刷新索引、升级系统软件包并清理依赖及缓存，选择并安装 FlClash 或 Termihomo，然后结束。不会在本次运行中等待 VPN 配置或安装其他软件。
2. **手动配置代理**：打开所选工具，配置内核、订阅和节点并启动本地代理。
3. **再次运行同一个脚本**：输入本地代理端口（默认 7890），验证成功后配置代理环境、刷新 APT 索引，继续安装其余软件和桌面配置。代理验证失败立即停止，配置好后重跑。

第一阶段成功后才会写入 `~/.local/state/ubuntu-init/proxy-tool`，记录首次安装的工具，仅作为阶段完成标记，不绑定当前使用的代理；失败时重跑仍执行第一阶段。后续运行保留这个状态，直接进入第二阶段进行版本检查。

软件步骤自动执行检查，并显示当前操作和判断结果：

- 未安装：自动安装。
- 本地版本等于或高于当前来源的最新版本：提示并跳过软件安装。
- 本地版本较旧：显示当前版本和目标版本，询问是否更新 `[Y/n]`；Enter/Y 更新，n 保留现有版本。
- 无法查询或比较版本：报告失败，保留现有安装，不将网络错误视为“最新版”。

APT 软件以刷新索引后的仓库候选版本为准；deb 以下载包内的版本为准；nvm、Node LTS、npm 工具和 Vicinae 查询各自上游；GNOME 扩展比较兼容当前 Shell 的版本；Git 项目比较上游 HEAD 提交。Git 更新只允许快进，有本地修改则保留并报告。Chrome、TRAE CN、LocalSend、FlClash 和 WowType 先通过 HTTP Range 读取最多 1 MiB 的 deb 包头（30 秒上限），获取真实 Debian 版本；同版、本地版本更高或拒绝更新时不下载完整安装包。包头读取失败则报告失败并保留已有安装，不回退到完整包下载。只有未安装或同意更新后才显示进度下载完整包（单次最多 600 秒、重试两次），再验证包名、架构与版本，避免二次询问。WowType 仍验证官方 SHA-256。

软件版本检查与桌面配置是两个步骤：快捷键、输入法、服务及代理等配置仍会按对应入口执行。代理订阅、代理端口等需要个人输入的步骤仍会等待输入。

启动时会从 [GitHub520](https://github.com/521xueweihan/GitHub520) 的 HTTPS 地址获取最新 hosts，校验公网 IP 和 GitHub 域名后更新 `/etc/hosts`，首次备份为 `/etc/hosts.before-ubuntu-init`；重跑替换同名域名映射并保留其他域名。下载或校验失败时保留原配置并提示。hosts 不保证所有网络都能直连 GitHub。

## 3. 代理工具二选一

第一阶段会显示选择菜单：

1. FlClash：图形界面，按 Enter 默认选择。
2. [Termihomo](https://github.com/Nyakooo/termihomo)：终端 TUI/CLI，支持 Linux amd64/arm64。

只检查和安装所选工具，缺失自动安装、最新版跳过、旧版询问 `[Y/n]`。Termihomo 从指定仓库最新正式版下载当前架构的发布包，校验 GitHub 发布 API 的 SHA-256 和包内程序版本后安装到 `~/.local/bin/termihomo`。

FlClash 安装后配置登录自启动。第一阶段结束后，请自行打开 FlClash，导入订阅、启动核心、选择规则模式并保持 TUN 关闭。Termihomo 安装到 `~/.local/bin/termihomo`，并在 `.profile`、`.bashrc` 和 `${ZDOTDIR:-$HOME}/.zshrc` 中配置 PATH。新开终端即可运行 `termihomo`；已有终端先执行 `export PATH="$HOME/.local/bin:$PATH"`，也可使用绝对路径启动。安装时会显示以下命令，用户也可以自行手动执行：

```sh
sh -c 'installer=$(curl -fsSL https\://raw\.githubusercontent.com/Nyakooo/termihomo/master/install.sh) && exec sh -c "$installer"'
```

第一阶段结束后运行它，在界面内安装 Mihomo 内核、导入订阅/本地 YAML、启动核心并选择节点。另一个代理核心占用同一端口时，请先停止它。脚本不会自动卸载另一款工具。

第二次及以后运行时，输入你当前实际使用的本地 HTTP/混合代理端口，默认 `127.0.0.1:7890`。无论首次安装的是 FlClash 还是 Termihomo，都可以切换到任意兼容的本地代理工具；脚本只验证端口上的代理是否可用，不根据历史工具名判断当前程序。脚本验证代理能够访问 GitHub，成功后仅在当前安装进程导出代理变量，并在 GNOME 配置系统代理；会清理旧脚本写入 `.profile` 和 `.zshrc` 的代理块。验证失败则停止，保留第一阶段状态以便重试。Termihomo 后台核心的登录自启动请在应用中按需配置。

## 4. 系统更新与安装内容

如果选择自动设置镜像，脚本会并行检查每个候选的当前发行版、更新和安全仓库中目标架构的 `Packages.xz` 索引（HEAD 请求，不下载完整索引），选择可用且响应较快的一项。amd64 使用清华、USTC 和阿里云的 `ubuntu` 源，arm64 使用 `ubuntu-ports` 源；都不可用时分别回退到 Ubuntu 官方主源/安全源或 `ports.ubuntu.com/ubuntu-ports`。第一阶段配置源后立即按顺序执行以下命令；每步显示进度，任一步失败即停止，后续命令不执行：

```sh
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get autoremove -y
sudo apt-get autoclean
```

这一步按用户要求自动升级系统软件包。第二阶段仍按每个软件的版本判断是否安装、跳过或询问更新。

这些网络准备步骤在 FlClash 配置前运行，依赖当前网络或 APT 镜像。安装代理工具后结束第一阶段；其余软件留到配置好代理后的下一次运行。

| 分类 | 内容 |
| --- | --- |
| 终端与截图 | curl、wget、git、gpg、zsh、Vim、htop、fzf、ranger、net-tools、tmux、Flameshot |
| Zsh 配置 | Oh My Zsh 官方安装器与完整模板；安装插件后补充 funky 主题、插件和 ra 别名，保留注释 |
| GNOME | 使用标准 keyd 双向互换 CapsLock/Esc；截图单独配置，`Ctrl+Alt+A` 和 Print 调用 Flameshot 的 Wayland 适配脚本，其他快捷键保留 |
| 浏览器与开发工具 | Google Chrome Stable、nvm 最新正式版、Node.js 最新 LTS、pnpm、http-server、nrm、ChatGPT 官方桌面客户端、TRAE CN |
| Rust 开发环境 | 自动检查并配置，从 Ubuntu 软件源安装 `cargo`、`rustc` 和 `build-essential` |
| 桌面应用 | LocalSend 最新正式版、Remmina、scrcpy、VLC |
| 录屏与直播 | 自动检查并配置 OBS Studio，使用 Ubuntu 软件源；GNOME Wayland 补齐录屏 portal |
| Docker | 自动检查并配置 Docker Engine、Compose、Buildx；自动选择国内软件包源，并匿名测速配置 Docker Hub 镜像加速 |
| 系统监控 | 自动检查并配置 indicator-sysmonitor + GNOME System Monitor；自动配置简洁显示、硬件温度和风扇，并加入用户登录自启动 |
| 中文输入 | 自动安装 WowType，作为唯一的中文输入法并默认启用；GNOME 自动尝试安装匹配版本的候选词面板 |
| Swap | 可选按内存计算 swapfile，目标约为内存两倍、最低 2GB、最高 8GB；已有活动 swap、Btrfs 或空间不足时跳过，不支持休眠恢复 |

第三方发布版本会动态获取，不固定在脚本编写时的旧版本。FlClash 和 Chrome 的自动 `.deb` 安装当前仅支持 `amd64`；不匹配时会提示跳过。

OBS Studio 随统一流程自动检查并安装。

使用 Ubuntu 24.04/26.04 软件源提供的 `obs-studio` 和 `obs-plugins`（含 PipeWire 录屏插件），不额外添加 PPA、不固定版本。GNOME Wayland 下自动补齐 `xdg-desktop-portal` 和 `xdg-desktop-portal-gnome`；打开 OBS 后，添加“屏幕捕获（PipeWire）”来源并完成系统授权即可录屏。脚本不自动启动 OBS，不修改现有场景或录制配置。

## 5. 超时、中断与重跑

- `curl` 连接超时 8 秒、单次总时限 60 秒，最多重试两次。
- 镜像探测并行进行，每个候选镜像约 6 秒上限。
- APT 网络请求超时 30 秒、最多重试两次；APT/dpkg 锁最多等待 300 秒。
- Git 设置连接超时和低速中断；nvm 下载及 npm 安装设置时间限制和有限重试。
- Ctrl+C 会停止当前步骤。已经完成的安装会保留；处理问题后重新运行脚本即可重试。
- 如果安装中断导致 dpkg 状态未完成，脚本会尝试 `apt-get -f install` 修复。仍失败时，按终端错误处理后再重跑。
- 独立应用步骤失败会显示失败状态，脚本可继续其他步骤；系统更新、源配置或代理前置步骤失败会停止后续依赖这些步骤的工作。

脚本不会因某项失败而标记“全部成功”。软件包安装、FlClash 代理验证、源配置、用户配置都可在修复问题后重跑。

## 6. 恢复 APT 源与取消代理

修改 Ubuntu 源前，脚本会把原有 `ubuntu.sources` 备份到：

```text
~/.local/state/ubuntu-init/ubuntu.sources.original
```

若该备份文件存在，可用以下命令恢复：

```sh
sudo cp -a "$HOME/.local/state/ubuntu-init/ubuntu.sources.original" /etc/apt/sources.list.d/ubuntu.sources
sudo apt-get update
```

如果原来没有 `ubuntu.sources`，脚本会新建它。要恢复这种情况，删除新文件后再运行 `sudo apt-get update`。

要取消命令行代理，删除 `~/.profile` 和 `~/.zshrc` 中 `BEGIN/END ubuntu-init proxy` 标记之间的内容。GNOME 系统代理可在“设置 → 网络 → 网络代理”中改回“关闭”。第三方安装包版本记录在 `~/.local/state/ubuntu-init/versions.log`。

## 7. 顶部栏、System Monitor 与中文输入

顶部栏监控模板如下（即使软件已是最新版，重跑脚本也会更新此格式）：

```text
{netcomp} u {cpu} m {mem} c {cpu_temp} {fan_rpm}
```

`cpu_temp` 是 CPU 温度（如 `55°C`），`fan_rpm` 是风扇转速（如 `3000 RPM`），无数据时显示 `—`。末尾显示如 `c 55°C 3000 RPM`。旧版监控适配会在重跑时补齐这两个字段。

`u` 是处理器使用率，`m` 是内存使用率，`RPM` 是每分钟转数。监控只有一个常驻 Python 进程，CPU 温度与风扇每 2 秒从内核读取；硬盘每 60 秒读取 UDisks 已有 SMART 缓存或 NVMe 内核传感器，不调用 `smartctl`、不主动刷新 SMART、不主动唤醒硬盘。网络接口通过内核路由表探测，不再每 2 秒创建 `ip` 子进程。

硬件路径自动发现，不绑定 ThinkPad、某个 SSD 型号或 `/dev/sda`。多个 CPU/风扇/硬盘传感器显示所选类别的最大值；无传感器或无 SMART 缓存时显示 `—`。`SSD` 是简洁版固定标签，实际也可能包括 SATA 机械盘。ARM 机器仍取决于内核是否暴露受支持的 CPU 温度传感器。

24.04 和 26.04 均从上游源码安装用户目录副本，无需 PPA、Meson 或修改系统 Python 文件。源码提交号记录在 `~/.local/state/ubuntu-init/sysmonitor-revisions.log`，上游接口变化时明确停止。26.04 使用 `gnome-shell-ubuntu-extensions`，24.04 使用 `gnome-shell-extension-appindicator`。GNOME System Monitor 同时由 APT 安装，顶部菜单中的 System Monitor 可直接调用。

统一流程自动配置 WowType，无需单独确认。

- 从 [WowType 官方发布页](https://github.com/Gloridust/WowType/releases) 获取匹配 Ubuntu 24.04 或 26.04 和当前架构（amd64 或 arm64）的最新安装包，校验 SHA-256 后由 APT 安装。
- Fcitx 5 输入法列表只配置英文键盘和 WowType，登录后默认启用 WowType。已有输入法软件包和词库会保留。
- GNOME 从官方扩展站选择与当前 Shell 主版本相符的 Input Method Panel，验证 ZIP 元数据后安装。若扩展安装失败，脚本仍会启用 WowType，部分 GNOME 界面可能无法显示候选框。
- `im-config` 管理 GTK/Qt/XWayland 环境变量，不在 `.bashrc` 中堆叠全局变量。GNOME 原生 Wayland 通过 Fcitx 的 IBus 协议前端工作；不禁用 GNOME 的 IBus 系统组件。

**保存工作后注销并重新登录一次**，顶部监控及输入法设置才会完整应用。默认 `Ctrl+空格` 切换中英文。脚本不会强制注销、杀死正在使用的输入法或关闭应用。少数 Electron/Chromium 应用若自行禁用了 Wayland IME，仍需在对应应用开启输入协议；脚本不批量改写所有第三方应用启动参数。自动输入法切换目前仅支持 GNOME/XFCE，KDE 会明确跳过，避免覆盖其虚拟键盘配置。

首次覆盖用户文件前，原内容备份到 `~/.local/state/ubuntu-init/desktop-backup/`，目录结构相对用户主目录保持一致；原文件不存在时写入 `.absent` 标记。重跑不会覆盖最初的备份。每次运行都会应用上面的监控显示格式，并将输入法列表设为英文键盘和 WowType。

要恢复原输入法，在终端执行 `im-config -n ibus`，移走 `~/.config/autostart/org.fcitx.Fcitx5.desktop`，然后注销重新登录。若之前使用其他输入框架，恢复备份中的 `.xinputrc`。恢复配置文件时，将备份目录中的对应文件复制回主目录；`.absent` 表示该文件原本不存在。GNOME Shell 原设置另存为 `desktop-backup/gnome-shell.json`（GVariant 文本值）；旧版 `gnome-shell.dconf` 历史备份保留。

## 8. Flameshot 默认截图入口

Flameshot 截图配置随统一流程自动执行。

在已登录的 GNOME 桌面终端中运行。脚本自动安装 Flameshot、`util-linux` 和 GNOME 截图 portal，生成 `~/.local/bin/flameshot-screenshot`，将 **Ctrl+Alt+A 和 Print** 绑定到该脚本，并移除这两个键对系统截图及其他自定义动作的冲突绑定；保留 Alt+Print 等其他快捷键。

Wayland 使用 Flameshot [官方排查指南](https://flameshot.org/docs/guide/wayland-help/)中的 shell/PTY 启动方式，显式设置 `QT_QPA_PLATFORM=wayland`；X11 直接调用 `flameshot gui`。不添加开机自启动，不自动打开截图界面；每次登录后快捷键依然有效，按键时才启动 Flameshot。首次截图若弹出屏幕共享授权窗口，需要允许。截图日志写入 `~/.cache/flameshot/shortcut.log`（遵循 `XDG_CACHE_HOME`，每次启动覆盖）。

首次改动前，原截图快捷键、自定义快捷键列表及动作记录到 `~/.local/state/ubuntu-init/desktop-backup/screenshot-shortcuts.json`，已有启动脚本也通过通用用户文件备份逻辑保存。重跑不会覆盖初始备份或新增重复项。此配置仅在 GNOME 下自动应用，Ubuntu 24.04/26.04 的 X11/Wayland 会按实际会话选择启动方式；本机 Ubuntu 26.04 Wayland 已通过该启动方式成功将截图复制到剪贴板，其他环境未逐一实机验收。

## 9. Docker 一键安装和国内镜像测速

Docker 及镜像源随统一流程自动检查并配置。

完整安装流程中的 Docker 步骤自动检查并配置。支持 Ubuntu 24.04/26.04、amd64/arm64，安装 Docker CE、Compose 插件和 Buildx，启用开机启动，并将当前用户加入 docker 组（注销重新登录后免 sudo）。若发现 docker.io、Podman 兼容命令或独立 containerd/runc 等冲突包，会列出实际软件包并询问 `[Y/n]` 是否切换到 Docker CE；拒绝时停止 Docker 步骤。确认后先准备签名密钥和仓库，再按版本选择确认安装/更新项，并预下载完整 APT 安装计划；预下载成功后，由同一次 APT 安装操作替换冲突包，不单独提前卸载、不清除容器数据。准备、下载或安装命令失败时恢复本轮修改前的 Docker 软件源文件与密钥（含原本不存在的情况）；已开始执行的 dpkg 安装操作不保证自动回滚，需按实际错误修复后重跑。

这里有两种不同的“源”：

1. **Docker 安装包源**：并行探测清华、USTC、阿里云 Docker CE 仓库中当前 Ubuntu 代号的 `InRelease`，按响应速度排序逐个尝试，索引更新失败或五个组件任一缺少候选版本时切换下一个；最后尝试 Docker 官方仓库。APT 仍用从 Docker 官方下载的签名密钥验证软件包，不关闭签名检查。这是仓库响应测速，不代表大文件下载带宽排名。
2. **Docker Hub 镜像加速源**：并行测试下列公开免费入口，使用匿名 Registry 协议握手，不调用 `docker login`，不读取个人 Docker 登录凭据。选取实际下载成功的至多三个地址，按下载速度排序，写入 `/etc/docker/daemon.json` 的 `registry-mirrors`。

| 服务 | 候选地址 | 运营方说明 |
| --- | --- | --- |
| 毫秒镜像 | `https://docker.1ms.run` | [官网](https://1ms.run/)提供免费公共加速入口；引用本服务来源为“毫秒镜像” |
| DaoCloud | `https://docker.m.daocloud.io` | [官方项目](https://github.com/DaoCloud/public-image-mirror)公布了白名单、限流和缓存规则 |
| DockerProxy | `https://dockerproxy.net` | [官方配置说明](https://dockerproxy.net/docs) |
| 1Panel | `https://docker.1panel.live` | [官方配置说明](https://1panel-dev.github.io/docs/v2/user_manual/containers/setting/) |
| 轩辕免费节点 | `https://docker.xuanyuan.me` | [官方免费入口](https://xuanyuan.cloud/free)为公共测试节点，无速度保障，有请求限额 |

测速直接访问网络，绕过当前 shell 的 HTTP 代理，避免把 FlClash 的出口速度当作国内直连速度。实际读取 `alpine:latest` 对应本机架构的清单和第一个镜像层，并核对层大小及 SHA-256；拒绝登录网页、错误清单、损坏数据和要求账号密码的入口。匿名 Bearer token 只是 Registry 协议握手，不需要注册或登录。每个候选设时间限制，单层上限 16 MiB；速度包含认证、清单及镜像层下载耗时。不会运行测试镜像，也不往 Docker 镜像库导入测试内容。

**不存在对所有网络都永久最快、永久免费不限量的固定排名。** 每次执行都会重新测试；超时、403、限流或校验失败的源会被排除，通过几个就配置几个。全部失败时保留现有镜像源配置，Docker 部分报告失败，修复网络后可重跑。当前内置源只处理 Docker Hub 公共镜像，不替换 GHCR、Quay 或私有仓库地址。

配置只替换 `registry-mirrors`，保留 `data-root`、日志、DNS 等已有设置。先运行 `dockerd --validate`，首次备份原文件为 `/etc/docker/daemon.json.before-ubuntu-init`（原本不存在时写入同名 `.absent` 标记），然后热重载并核对 `docker info` 中实际生效的地址；若加载失败，恢复本轮修改前的配置。换镜像源使用 [Docker 支持的 SIGHUP 热重载](https://docs.docker.com/reference/cli/dockerd/#configuration-reload-behavior)，不主动重启已有容器。Docker 软件包安装/升级本身仍可能由包管理器启动或重启服务。

成功的测速记录位于 `~/.local/state/ubuntu-init/docker-mirror-probe.json`。本次 Ubuntu 26.04 网络实测中，DaoCloud、毫秒镜像均通过匿名下载和摘要校验，轩辕节点超时；安装包源检测成功。这只是测试时的本机结果，脚本不会硬编码该排序。Docker 官方也已[列出 Ubuntu 26.04 为支持系统](https://docs.docker.com/engine/install/ubuntu/)；国内软件包仓库参见[清华说明](https://mirrors.tuna.tsinghua.edu.cn/help/docker-ce/)和[USTC 说明](https://mirrors.ustc.edu.cn/help/docker-ce.html)。

## 10. 验证状态与限制

验证命令（在仓库根目录）：

```sh
sh -n install-ubuntu.sh
python3 -m unittest discover -s tests -v
```

测试在临时 HOME 中运行，不执行 APT、不修改当前桌面。覆盖 WowType 默认启用与重复执行、原始备份不覆盖、传感器有/无数据、硬盘缓存避免重复查询、带空格路径和生成脚本的语法。测试需要系统 Python 的 `gi`、`psutil`，以及已安装的 Fcitx 5 desktop 文件。设置 `SYSMONITOR_UPSTREAM=/path/to/indicator-sysmonitor` 可以对实际上游源码重复运行同一组监控安装测试。

2026-11-20 在当前工作区验证：`sh -n install-ubuntu.sh` 通过，`python3 -m unittest discover -s tests -v` 的 80 项测试全部通过。这些检查不等同于在全新 Ubuntu 24.04/26.04 桌面上执行完整安装，也不能验证所有应用的实际候选词位置及第三方软件的运行行为。

脚本采用明确支持范围、网络超时、步骤失败提示和可重跑设计；无法保证任意第三方软件源、驱动、网络或未来上游版本都兼容。各步骤逐项报告结果；失败后继续独立步骤。

## 11. Copyous 剪贴板历史与 Vicinae 启动器

Copyous 和 Vicinae 随统一流程自动检查并配置。

- Copyous：**Super（Win）+ V** 打开剪贴板历史，隐藏顶部栏图标，扩展随登录启用。
- Vicinae：**Super + 空格** 显示/隐藏启动器，用户级 systemd 服务登录自启，隐藏顶部栏图标。
- 自动替换上述两个快捷键的冲突绑定，保留其他快捷键；包括移除 GNOME 默认通知栏 Super+V 和输入源切换 Super+空格。通知栏仍可使用 Super+M，Fcitx 中英文切换仍为 Ctrl+空格（以已有配置为准）。

Copyous 与 Vicinae GNOME 扩展从 GNOME 官方扩展站按当前 Shell 主版本选择，验证 UUID、兼容版本及 ZIP 路径后安装。**Copyous 当前支持 GNOME 48–51，不支持 Ubuntu 24.04 原装 GNOME 46**；没有匹配版本时提示并跳过该组件，继续其余安装，不修改被跳过组件的快捷键或设置；Vicinae 配套 GNOME 扩展不兼容时仅跳过扩展，仍安装启动器。网络、校验或安装错误仍正常报告失败。Ubuntu 26.04 的 GNOME 50 有匹配版本。安装后保存工作，注销并重新登录一次加载新扩展；脚本不会强制注销。

Vicinae 使用[官方安装方式](https://docs.vicinae.com/install/linux)安装到 `~/.local`：获取最新稳定版对应 amd64/arm64 的 AppImage，核对 GitHub 发布 API 给出的 SHA-256 后交给官方安装器解包，无需 FUSE。大文件下载单次最多 600 秒、重试两次。服务显式补齐用户 bin 和已有 nvm Node 路径，桌面入口使用绝对路径，并注册 `vicinae://` 链接。不会额外授予键盘设备访问或提权能力；部分高级输入注入功能仍可能需要上游文档中的额外配置。

快捷键和图标原设置首次备份至 `~/.local/state/ubuntu-init/desktop-backup/launcher-settings.json`，扩展目录及服务 PATH 配置使用相同目录的通用备份逻辑。重跑保留首次备份、不增加重复快捷键，会重新应用上述默认设置并更新应用。不会清除剪贴板数据库或已有 Vicinae 应用配置。剪贴板历史会保存在本机，请在 Copyous 偏好设置中按需设置敏感应用排除规则。


## 12. 重复运行与版本判断验证（0.6.0）

新增 6 项隔离测试，覆盖未安装自动安装、相同/更高版本跳过、旧版本 Y/n、输入流关闭保留版本、查询失败、APT 混合包选择、拒绝更新时固定已安装版本、deb 包比较及本地 Git 快进更新。测试不执行主机软件安装。

## 13. 使用 keyd 双向互换 CapsLock/Esc

用于重装系统后初始化，也支持以后重复运行查漏补缺。在 A 的已登录 GNOME 桌面终端执行（不要在整条命令前加 sudo）：

```sh
sh install-ubuntu.sh
```

第二阶段自动安装、配置并启用 keyd，不需要选择模式、填写设备号或修改配置。完成后保存工作，注销重新登录。

使用标准 keyd 配置 `/etc/keyd/ubuntu-init.conf`，统一应用于所有键盘，不区分本地或 IPKVM，不包含 GL-RM1 设备特判：

```ini
# ubuntu-init Caps/Esc swap
[ids]
*

[main]
capslock = esc
esc = capslock
```

这是 **Caps → Esc、Esc → CapsLock 的真正双向互换**。[keyd 官方说明](https://github.com/rvaiya/keyd)介绍了它的 evdev/uinput 系统输入层实现，可用于 Wayland、X11 和 TTY。Ubuntu 26.04 使用发行版软件包；Ubuntu 24.04 若没有 keyd 候选版本，自动添加上游列出的 [keyd-team PPA](https://launchpad.net/~keyd-team/+archive/ubuntu/ppa)，刷新索引后安装。软件包仍按安装器的版本比较规则处理。

Debian/Ubuntu 软件包将可执行文件重命名为 `/usr/bin/keyd.rvaiya`，服务名仍为 `keyd`。脚本优先使用该命令，兼容上游的 `keyd` 命令；找不到命令时在修改键位前停止。

迁移通过 `gsettings` 清除 GNOME 中涉及 Caps/Esc 的 XKB 选项，保留其他布局切换选项并读回验证。新的改键不依赖 dconf-editor 或 dconf-cli；GNOME 自身的设置后端保留。旧 XKB 设置首次备份至 `~/.local/state/ubuntu-init/desktop-backup/keyboard-before-keyd.json`，保留此前历史备份；配置成功后删除旧 `keyboard-remap-mode` 和 `keyboard-dconf-editor-migrated` 状态，不再弹出本机/远程二选一。WowType 的 GNOME Shell 备份也改为通过 Gio 写入 `desktop-backup/gnome-shell.json`，不再调用 dconf 命令。

重跑先检查 keyd 软件包更新；配置一致、服务已启用且运行正常、包版本没有改变时，跳过写入和重载。配置缺失、旧映射冲突、服务停用或包版本更新时会继续修复，不会叠加交换或覆盖首次备份。服务启动、重载或 XKB 校验失败时，恢复本次运行前的 XKB 和脚本管理的 keyd 文件。若已有其他用户 keyd 配置，此项报告冲突路径并保留配置，避免覆盖用户改键。

自动测试覆盖全新安装、旧配置迁移、重复运行和失败恢复，服务调用使用隔离桩。尚未通过真实 GL-RM1 验证；不根据“B 已改键”这一信息推断应排除 KVM。实际按键需在 A 本机和 B 经 GL-RM1 两条路径上确认：Caps 能退出 Vim 插入模式，Esc 能切换大写锁定。

撤销本脚本的改键：删除 `/etc/keyd/ubuntu-init.conf` 后执行 `sudo /usr/bin/keyd.rvaiya reload`（上游安装使用 `sudo keyd reload`）；需要恢复 GNOME 旧配置时，将 JSON 备份中的列表用 `gsettings set org.gnome.desktop.input-sources xkb-options` 写回。


ChatGPT 官方桌面客户端随第二阶段检查，包名为 `chatgpt`。从 [OpenAI 官方 Linux 软件包仓库](https://learn.chatgpt.com/docs/linux/linux-app)获取匹配 amd64/arm64 的版本信息，先比较本地版本，缺失自动安装、最新跳过、旧版询问 `[Y/n]`。安装前验证 SHA-256、包名、架构和版本；不再安装 npm 的 Codex CLI。安装完成后从应用菜单打开 ChatGPT 并登录。


## 14. Zsh 与 Oh My Zsh 修复

Oh My Zsh 配置按以下顺序执行：

1. 首次安装运行官方 `tools/install.sh`，以完整默认 `.zshrc` 模板为基础，保留官方说明注释。已有 Oh My Zsh 检查更新，已有用户配置先备份并保留；旧脚本的精简管理块迁移到完整官方模板，保留块外用户设置。
2. 下载或更新 `zsh-autosuggestions`、`zsh-syntax-highlighting`，未下载完成时不写入插件启用配置。
3. 检查主题和插件文件确实存在，再将原生 `ZSH_THEME` 字段设为 `funky`；在 Oh My Zsh 的 source 之前合并 `git` 和两个插件，保留已有插件并去重；在 source 之后添加 `alias ra='ranger'` 和 `alias ter='"$HOME/.local/bin/termihomo"'`。重复运行替换同一管理块，不重复添加插件或别名，保留官方注释及其他用户配置。
4. 验证 zsh 启动后设置默认 shell，再继续其他安装步骤。nvm 初始化完全由后续 nvm 官方安装器添加，本步骤不生成或修改 nvm 配置。

官方安装器不启动新 shell 或中断后续步骤；网络安装失败时不生成精简替代模板。

交互启动验证通过后才设置默认 shell，并通过账户记录读回检查；不依据可能过期的 `$SHELL` 环境变量判断。第二阶段全部成功后自动进入交互式 Zsh；完整登录环境可注销重登录。


Docker 安装验收现在先执行 `sudo docker version`、`sudo docker compose version`、`sudo docker buildx version`，确认系统级服务与三个命令正常，再测速并配置镜像源。镜像源失败会单独报告，避免把已成功的 Engine/Compose 安装混淆为未安装；重跑重新测速。软件包源与镜像源分别排序，镜像源从五个候选中选实际校验成功的最快至多三个。当前网络实测 DaoCloud 和毫秒镜像通过，其余三个未通过，实际选择始终以运行当次结果为准。


## 15. TRAE CN 中国版

第二阶段自动从 [TRAE CN 官方下载渠道](https://www.trae.cn/ide/download)查询最新 Linux deb，按 amd64/arm64 选择中国区安装包，校验包名 `trae-cn` 和架构后安装。产品展示版本与 deb 包版本不同，因此以包内 Debian 版本进行本地比较：缺失时先询问是否安装 `[Y/n]`（在下载之前），已安装时按实际包版本判断最新跳过或旧版询问更新。读取包版本仅下载最多 1 MiB 的包头，不用产品展示版本或 URL 路径版本代替 Debian 版本；只有确认安装/更新后才下载完整包，大包单次下载最多 600 秒、重试两次。不会自动启动应用或替用户登录。


环境配置顺序：第二阶段先验证代理并在当前进程导出代理变量，刷新 APT 后安装 zsh、准备 `.zshrc`，再清理旧的永久代理配置并自动加载；代理变量仅保留在当前安装进程。Oh My Zsh 配置完成、nvm 初始化写入和 Node 安装完成后也会自动加载 `${ZDOTDIR:-$HOME}/.zshrc`。由于主脚本为 POSIX sh，由 zsh 子进程执行 `source`，通过 JSON 同步 PATH、nvm 和代理环境给后续安装；不执行拼接的环境变量代码。父 shell 本身不会改变；第二阶段全部成功后自动将安装器替换为交互式 Zsh，加载持久化配置并接收用户后续命令。


## 16. Vim 配置与终端环境清理

第二阶段安装 Vim 后，按脚本内置的 `.vimrc` 配置语法高亮、绝对/相对行号、光标行、搜索行为、H/J/K/L 移动及 S 保存、Q 退出、R 重载配置。首次备份到 `desktop-backup/.vimrc`，保留自定义内容，重复运行替换同一配置块，Vim 无界面校验通过才写入正式文件。

`.zshrc` 使用原生 Oh My Zsh 配置，保留用户设置和 nvm 初始化；旧脚本的永久代理块自动从 `.zshrc` 和 `.profile` 删除。当前安装流程仍显式使用已验证的代理，不把固定端口写进新终端的启动配置。

安装 Oh My Zsh 与插件后补充 `alias ra='ranger'` 和 `alias ter='"$HOME/.local/bin/termihomo"'`，保留其他用户别名。

Caps/Esc 双向互换由标准 keyd 配置统一应用，详见第 13 节。


zsh 环境加载与启动验证采用禁用作业控制的嵌套子进程，并仅在该子进程关闭 Oh My Zsh 自动更新询问、使用空标准输入，避免 `suspended (tty input)` 中断后续键位和 TRAE CN 步骤。回归测试通过伪终端中的交互式 zsh 启动安装器，验证该路径不会挂起。


## 17. 执行结果汇总

每次运行结束以编号列表逐项列出本次已执行的软件/配置功能与成功、失败、跳过状态，并显示各状态数量，按顶层软件/配置项目统计，每项只记一次，不重复累加内部依赖包。项目完全无需安装/更新或用户拒绝安装/更新时记为跳过；完成安装、更新或配置时记为成功；命令失败记为失败，并列出失败项目。混合项目中部分软件已是最新但其他软件安装成功时，整个项目记为成功。

两个阶段各自汇总本次执行结果。关键步骤失败提前停止时也打印已执行项目的汇总；独立步骤失败继续执行其余步骤，最终有失败项目时返回非零退出码。统计按本次运行初始化，不累加历史运行。

最终列表后单列“本次新安装”和“本次已更新”，显示软件名及版本（更新显示旧版本 → 新版本）；没有则显示“无”。只有成功完成的步骤才计入这两份明细，失败或拒绝更新不算已更新。配置成功不等于软件升级。第一阶段的系统软件升级先模拟列出可更新项目，再整体询问是否升级；升级后比较真实包清单，记录实际发生的版本变化。


## 18. 重复执行时按实际状态跳过（0.8.0）

每次仍刷新 APT 索引，查询软件包、Git 仓库和官方发布的最新版本，保留原有的缺失安装、最新版跳过、旧版询问更新规则。配置正确时只跳过不必要的写入和服务操作，不用“已执行过”的标记跳过整个项目。

- **键位**：keyd 配置与 XKB 状态正确、服务启用且运行中、包版本未变化时，不写配置或重载；仍检查软件包更新，并修复缺失配置、停用的服务。
- **Vim/Zsh**：候选配置通过校验且内容与现有文件相同时，保留原文件及时间戳；Oh My Zsh 与插件仍检查上游更新。修复 Zsh 管理块重复运行累积空行的问题；没有旧代理块时不重写 `.profile` / `.zshrc`。
- **截图与输入法**：只写入不同的快捷键值、Flameshot 启动脚本、Fcitx5 配置和自启文件；`.xinputrc` 已选择 fcitx5 时不重复调用 im-config，不重启正在使用的输入法。
- **Vicinae**：配置和服务均正常时不重启；软件更新、服务环境变化或服务停用时才重载/重启/启动。快捷键和图标设置相同也不重复写入。
- **Docker**：仍进行仓库检查和镜像源测速；测速选出的配置与磁盘配置、Docker 实际加载的镜像源一致时，跳过配置写入与热重载。磁盘与运行状态不一致时仍修复，不重启容器。
- **顶部监控**：格式已符合预期时不重写配置，仍检查上游版本。

重复执行的测试检查文件内容、时间戳、服务调用记录，以及更新和缺失修复是否继续执行。测试使用临时主目录与服务桩，不运行整机安装或改动当前键位。


## 19. 标准家目录使用英文名称（0.8.1）

每次执行脚本时自动检查 8 个 XDG 标准目录，仅调整目录名称及对应路径，不改变系统中文界面、LANG、区域设置或输入法：

| 中文目录 | 英文目录 |
| --- | --- |
| 桌面 | Desktop |
| 下载 | Downloads |
| 文档 | Documents |
| 图片 | Pictures |
| 音乐 | Music |
| 视频 | Videos |
| 模板 | Templates |
| 公共 | Public |

使用 `~/.config/user-dirs.dirs`（支持 `XDG_CONFIG_HOME`）确定当前标准目录，迁移其中内容并更新 XDG 路径和相关 GTK 书签。`go`、`snap`、`workspace`、应用数据和其他自建目录不处理；自定义路径、指向家目录的禁用项及目录符号链接保留。

已有英文目标目录时，先检查全部迁移计划，无同名文件冲突才合并，保留原有英文目录内容；同名文件冲突时该步骤报告具体路径，不移动任何文件或覆盖内容。文件移动或配置提交失败时尝试恢复原位置。原目录配置和书签首次备份至 `~/.local/state/ubuntu-init/desktop-backup/user-dirs/`。

已是英文且目录存在时跳过，不改变目录配置文件时间戳；缺失的标准目录会补建。`user-dirs.locale` 记录当前会话语言，避免仅因目录改成英文而在下次登录提示改回中文，它不设置系统语言。完成后建议保存工作并注销重新登录，让桌面和应用重新读取目录路径。

### Git SSH 密钥

第二阶段安装 Git 和 `openssh-client` 后，检查当前用户的 `~/.ssh/id_*` 密钥文件；已有则跳过，不覆盖原文件。没有时，先提示输入邮箱（必填，无默认值；空白输入会重新提示，输入结束时停止生成密钥），再在当前终端使用所填邮箱执行以下命令：

```sh
ssh-keygen -t ed25519 -C "your-email@example.com"
```

请自行输入保存位置和密码。默认生成 `~/.ssh/id_ed25519`（私钥）和 `~/.ssh/id_ed25519.pub`（公钥）。若选择其他位置，后续运行可再次提示生成，请自行保留并使用已有密钥。

第二阶段全部成功后，脚本清理临时文件并自动以 `exec zsh -i` 进入交互式 Zsh，启动时加载 `.zshrc`，可直接使用 `ra` 和 `ter`，无需手动 source。此 Zsh 替换的是安装器进程；输入 `exit` 会返回启动安装器的原 shell。第一阶段安装代理后仍直接结束，不进入 Zsh。

SSH 密钥检查单独列为“Git SSH 密钥”，每次第二阶段运行都会执行，与软件包是否已是最新版无关；检测到文件时输出具体路径并在汇总中标记跳过。

Termihomo 安装后创建 `/usr/local/bin/termihomo` 到用户安装文件的符号链接，供当前终端直接查找（需 PATH 包含 `/usr/local/bin`）。已有其他同名文件时保留并报告冲突。`ter` 固定指向 `~/.local/bin/termihomo`，更新该路径下的程序后仍有效。

## 20. 安装失败恢复改进（0.8.2）

- 保留原有两阶段安装、软件选择、版本比较、更新确认和结果汇总流程。
- 加载用户 `.zshrc` 后保留 PATH/nvm 环境，但为本次安装重新应用已验证的代理端口，防止旧代理变量覆盖它；用户自定义代理行不被改写。
- Ubuntu 源按 amd64/arm64 分流，探测目标架构索引，避免仅凭 `InRelease` 可达选中不匹配的仓库。
- Docker 在预下载完成后统一替换冲突包；失败时恢复本轮的软件源与密钥。镜像源仍按当次网络实测选择，不改变既有测速、摘要校验和热重载规则。
- 新 swapfile 先以 0600 权限独占创建，分配或格式化失败/中断会清理本轮新文件，不覆盖已有文件。启用成功但 `fstab` 写入失败时保留管理标记，重跑可修复持久化；其他已有活动 swap 保持原样。
- Flameshot 将 Ubuntu 的 `<Primary>` 快捷键别名按 `<Control>` 比较，避免无可用 GDK 显示时漏清理冲突，保留不冲突的快捷键。

新增隔离回归测试覆盖上述失败和重跑路径；测试不安装主机软件、不调用主机 Docker 服务，也不创建真实 swap。完整桌面安装仍需在目标 Ubuntu 虚拟机或实机中验收。


Docker 安装后自动将当前普通用户加入 `docker` 组，并以该用户验证免 sudo 的 Engine、Compose 和 Buildx。安装结束自动进入的 Zsh 会刷新 docker 组权限，可直接运行 `docker ps`、`docker compose` 和 `docker buildx`；其他已打开终端注销重新登录后生效。安装软件和系统配置本身仍需 sudo。docker 组具有管理宿主机的权限；脚本不会开放 Docker socket 的全员读写权限。


Docker 与 Docker 镜像源分别汇总：镜像源测速/热重载失败不会再把已安装且可访问的 Engine 标成失败。Docker 失败会显示具体阶段（软件包、服务、插件或免 sudo 权限）、退出码和处理命令；这些原因也保留在最终汇总中。所有镜像源测速失败时仍保存 `~/.local/state/ubuntu-init/docker-mirror-probe.json`，保留原 Docker 配置。其他步骤未提供详细原因时，汇总至少列出失败命令及退出码。


修复免 sudo 验证的 `sg: not found`：不再依赖 `sg`/`newgrp`。当前会话尚未加载 docker 组时，通过 `sudo -u 当前用户名 -- ...` 重新初始化该普通用户的组列表，验证 Engine、Compose、Buildx，并在安装结束以同一普通用户进入 Zsh。sudo 仅用于安装期间刷新组权限；进入后的 Docker 命令不加 sudo，也不以 root 身份运行 Zsh。
