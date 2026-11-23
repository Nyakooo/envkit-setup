# envkit-setup

Ubuntu 桌面环境初始化脚本。配置软件源、代理、开发工具和桌面环境，支持重复运行。

## 运行要求

- Ubuntu 24.04 / 26.04，推荐 GNOME 桌面。
- 支持 `amd64`、`arm64`；部分应用仅支持 `amd64`。
- 已安装 `curl`、`python3`，当前用户可使用 `sudo`。
- 在已登录桌面的终端中运行，首次运行需能访问 GitHub。

**使用普通用户运行，不要在整条命令前加 `sudo`。**

## 快速开始

```sh
script=$(curl -fsSL --connect-timeout 8 --max-time 60 "https://raw.githubusercontent.com/Nyakooo/envkit-setup/master/install-ubuntu.sh") && [ -n "$script" ] && sh -c "$script"
```

本地运行：

```sh
sh install-ubuntu.sh
```

| 步骤 | 执行内容 |
| --- | --- |
| 1. 首次运行 | 配置 GitHub hosts 和 APT 镜像，检查系统升级、清理依赖与缓存，安装所选代理工具后结束 |
| 2. 配置代理 | 打开代理工具，配置内核、订阅和节点，启动本地 HTTP/混合代理 |
| 3. 再次运行 | 输入代理端口（默认 `7890`），验证通过后继续安装其余软件和配置 |
| 4. 安装完成 | 查看结果汇总，保存工作后注销并重新登录 |

FlClash 默认选中，使用规则模式并关闭 TUN；Termihomo 按界面提示配置 Mihomo 内核。后续可使用任意兼容的本地代理工具。

## 安装菜单

以下是脚本的安装清单，便于查漏补缺。脚本按流程执行，不提供逐项勾选菜单。

### 网络与系统

| 项目 | 具体内容 | 执行方式 |
| --- | --- | --- |
| GitHub hosts | 从 GitHub520 获取并校验映射，更新 `/etc/hosts` | 第一阶段 |
| APT 镜像 | 清华、USTC、阿里云测速，失败回退 Ubuntu 官方源 | 第一阶段，按架构选择 |
| 系统维护 | 更新索引、升级软件包、`autoremove`、`autoclean` | 升级先询问，清理自动执行 |
| 代理工具 | FlClash / [Termihomo](https://github.com/Nyakooo/termihomo) | 二选一；FlClash 仅 `amd64` |
| 本地代理 | 连通性验证、安装进程代理变量、GNOME 系统代理 | 第二阶段 |
| Swap | `/swapfile`，内存的两倍，最低 2 GB、最高 8 GB | 自动配置；已有活动 Swap、Btrfs 或空间不足时跳过 |

### 终端与开发

| 项目 | 具体内容 | 执行方式 |
| --- | --- | --- |
| 下载与版本控制 | `curl`、`wget`、`git`、`openssh-client`、`gpg` | 自动检查安装 |
| 终端工具 | `zsh`、`vim`、`htop`、`fzf`、`ranger`、`net-tools`、`tmux` | 自动检查安装 |
| Zsh 配置 | Oh My Zsh、funky 主题、git 插件、zsh-autosuggestions、zsh-syntax-highlighting | 自动配置，设为默认 Shell |
| Vim 配置 | 语法高亮、行号、搜索、移动与保存快捷键 | 自动配置 |
| Git 身份 | 全局 `user.name`、`user.email` | 已配置则直接跳过，仅缺失项必填；邮箱只输入一次，使用 GitHub 已绑定邮箱或 noreply 邮箱 |
| SSH 密钥 | Ed25519 密钥，复用上述邮箱 | Git 配置完成后生成；已有 `~/.ssh/id_*` 文件则保留并跳过，路径和密码交互输入 |
| Node.js | nvm、最新 LTS Node.js、npm | 自动检查安装 |
| npm 工具 | `pnpm`、`http-server`、`nrm` | 全局安装，逐项检查版本 |
| Rust | `cargo`、`rustc`、`build-essential` | 从 Ubuntu 软件源安装 |
| Docker | Docker CE、CLI、containerd、Compose、Buildx | 自动安装并启用服务；替换冲突包前询问 |
| Docker 镜像加速 | 毫秒镜像、DaoCloud、DockerProxy、1Panel、轩辕节点 | 匿名测速，选取通过校验的最快至多三个入口 |

Git 身份按全局配置逐项检查，已有值不询问、不覆盖。缺失时先补齐身份，再检查 SSH 密钥；邮箱只输入一次。生成密钥后，需自行将公钥添加到 GitHub，私钥保留在本机。

### 桌面应用

| 项目 | 用途 | 执行方式 |
| --- | --- | --- |
| Google Chrome Stable | 浏览器 | 自动检查安装，仅 `amd64` |
| ChatGPT | 桌面客户端 | 自动检查安装 |
| [Antigravity IDE](https://antigravity.google/download/) | Google 独立开发环境 | 在 ChatGPT 之后自动检查安装，支持 `amd64`、`arm64` |
| TRAE CN | 开发工具 | 首次安装先询问 |
| LocalSend | 局域网文件传输 | 自动检查安装 |
| Remmina | 远程桌面，含 RDP 和凭据存储插件 | 自动检查安装 |
| scrcpy | Android 投屏 | 自动检查安装 |
| VLC | 媒体播放 | 自动检查安装 |
| OBS Studio | 录屏与直播，含 `obs-plugins` | 自动安装；GNOME Wayland 补齐录屏 portal |
| Flameshot | 截图 | 自动安装；GNOME 下配置快捷键 |
| Vicinae | 启动器，含兼容的 GNOME 扩展 | 自动安装并配置登录自启 |
| Copyous | 剪贴板历史 | 安装并启用兼容的 GNOME 扩展；无匹配版本时跳过 |
| indicator-sysmonitor | 顶部栏网络、CPU、内存、温度与风扇监控 | 自动配置登录自启；无传感器数据显示 `—` |
| GNOME System Monitor | 系统资源监视器 | 自动检查安装 |
| WowType | Fcitx 5 中文输入法，含配置工具及兼容的 GNOME 候选词面板 | 自动安装并设为默认中文输入法；自动切换支持 GNOME/XFCE |

Antigravity IDE 从官方下载页获取当前架构的独立版，安装到 `~/.local/opt/antigravity-ide-<版本>/`，添加应用菜单入口和 `~/.local/bin/antigravity-ide` 命令。首次打开需登录 Google 账号；重跑按 IDE 版本判断是否更新，旧版本目录保留。

依赖包由对应步骤安装。GNOME 扩展按当前 Shell 版本匹配；不兼容时提示跳过。

## 默认配置

| 项目 | 配置结果 |
| --- | --- |
| CapsLock / Esc | 通过 keyd 双向互换，保留已有自定义 keyd 配置；冲突时停止该项 |
| 截图 | `Ctrl+Alt+A`、`Print` 调用 Flameshot，移除这两个按键的冲突绑定 |
| 启动器 | `Super+空格` 打开 Vicinae |
| 剪贴板 | `Super+V` 打开 Copyous，隐藏顶部栏图标 |
| 输入法 | 英文键盘 + WowType，默认 `Ctrl+空格` 切换中英文；保留已有输入法软件包和词库 |
| Zsh 别名 | `ra` → ranger，`ter` → `~/.local/bin/termihomo` |
| 标准目录 | 桌面、下载、文档、图片、音乐、视频、模板、公共目录改为英文名，迁移内容并更新书签；不改变系统语言 |
| Docker 权限 | 当前用户加入 `docker` 组；其他已打开的终端需注销重登录后生效 |

标准目录迁移遇到同名文件冲突时停止该项；自定义目录及符号链接保持原样。第二阶段全部成功后自动进入 Zsh，输入 `exit` 返回原终端。

## 更新与重跑

| 本地状态 | 处理方式 |
| --- | --- |
| 未安装 | 自动安装；TRAE CN 除外，先询问 |
| 已是最新版或更高版本 | 跳过安装 |
| 有更新 | 显示版本差异，询问 `[Y/n]` |
| 无法获取或比较版本 | 报告失败，保留已有安装 |

配置按实际状态检查，必要时重新应用上述默认值。每次运行结束列出成功、失败、跳过及本次安装和更新明细。

关键前置步骤失败会停止流程；独立项目失败后继续其他项目。处理错误后重新运行同一命令即可，无需删除阶段状态。

## 使用注意

- 本脚本会修改系统软件源、桌面配置和用户配置，建议先保存工作。
- GNOME 设置需要可用的桌面会话总线；出现 dconf / D-Bus 警告时，检查对应设置是否实际生效。
- Copyous 会在本机保存剪贴板历史，请按需设置敏感应用排除规则。
- Docker 测速绕过当前 Shell 的 HTTP 代理直连候选服务；`docker` 组具有管理宿主机的权限。
- 首次截图或 OBS 屏幕捕获可能需要系统授权；输入法、顶部栏及新扩展需注销重登录。
- 不支持休眠恢复；完整安装仍需在目标 Ubuntu 桌面上验收。

## 备份与恢复

状态目录：`~/.local/state/ubuntu-init/`。首次备份保留，重跑不覆盖。

| 内容 | 位置 |
| --- | --- |
| 用户配置、快捷键备份 | `~/.local/state/ubuntu-init/desktop-backup/` |
| 原 APT 源 | `~/.local/state/ubuntu-init/ubuntu.sources.original` |
| 原 hosts | `/etc/hosts.before-ubuntu-init` |
| 原 Docker 配置 | `/etc/docker/daemon.json.before-ubuntu-init` |
| Docker 镜像测速结果 | `~/.local/state/ubuntu-init/docker-mirror-probe.json` |
| Flameshot 日志 | `~/.cache/flameshot/shortcut.log`（遵循 `XDG_CACHE_HOME`） |

用户文件备份按相对家目录的路径保存；`.absent` 表示原文件不存在。JSON 设置备份需按对应设置项恢复，不能直接覆盖 dconf 数据库。

恢复 APT 源（备份存在时）：

```sh
sudo cp -a "$HOME/.local/state/ubuntu-init/ubuntu.sources.original" /etc/apt/sources.list.d/ubuntu.sources
sudo apt-get update
```

若原本没有 `ubuntu.sources`，删除脚本新建的该文件后刷新索引。GNOME 系统代理可在“设置 → 网络 → 网络代理”中关闭；脚本导出的代理变量只影响安装进程及其子进程。

## 开发验证

```sh
sh -n install-ubuntu.sh
python3 -m unittest discover -s tests -v
```

测试使用临时目录和模拟命令，不运行整机安装。部分桌面测试需要系统 Python 的 `gi`、`psutil` 及 Fcitx 5 desktop 文件。
