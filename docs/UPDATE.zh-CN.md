# SyncPilot 更新

SyncPilot 应用内更新器（构建于 `rivet/distribution`）的完整契约。本页是唯一权威文档；README 只做摘要。

[English](UPDATE.md) · **简体中文**

## Feed（更新源）

- 通道：`stable`——签名的通道 manifest 是 **`update-stable.json`**，从固定位置
  `https://github.com/turinglambdaai/syncpilot/releases/latest/download`
  获取；manifest *内部*的产物 URL 则钉死在具体 release tag 上。
- manifest 用 **Ed25519 签名**（key id `syncpilot-2026-10`）。公钥内嵌在应用里
  （`racket/syncpilot/version.rkt`）；签名校验失败的 manifest——或携带的
  大小/SHA-256 与未签名文件不符的——在任何提供或下载动作之前就被拒绝。
- 每个 GitHub release 同时附带明文 `<tarball>.sha256` 校验文件，供手动验证。

## 检查

- **每天一次静默自动检查**，在启动时进行。节流逻辑在后端
  （`app/backend.rkt`）：24 小时内的检查直接返回 `throttled`、不触网；每次完成的检查会把时间戳写进设置的
  `last-update-check-at`。
- UI 里的手动检查（`force`）总是执行，不受节流限制。

## 下载

- 有可用更新时**应用内后台下载**，进度通过 `update-state` RPC 呈现到 UI。
- 下载内容在信任之前，先对照签名 manifest 校验字节数与 SHA-256。
- 下载有最大体积上限保护；任何失败都会丢弃 `.partial` 半成品文件。

## 应用——更新器按安装形态各做什么

更新器从不安装任何东西，也没有任何对话框宣称装好了。它完成验证后，把验证过的
`syncpilot-<version>-linux-<arch>.tar.gz` 交给你——对话框显示文件路径（可选中复制）和打开文件夹按钮，并明说下一步由你完成。这一步是什么，取决于安装形态：

| 安装形态 | 更新交接 |
|---|---|
| **tar.gz / zip**（便携） | 把验证过的 tar.gz 解压覆盖应用目录，重启 `RivetHost`。 |
| **deb** | 从 release 页下载新版 `.deb`，直接装在旧版之上：`sudo apt install ./syncpilot-<version>-linux-amd64.deb`。 |
| **rpm** | 同理走包管理器：`sudo dnf install ./syncpilot-<version>-linux-x86_64.rpm`（或 `zypper in ./…rpm`）。 |
| **AppImage** | 从 release 页下载新 AppImage，替换旧文件。release 资产带 `.sha256` 校验文件——替换前先核对。 |

对 deb、rpm 和 AppImage 安装来说，应用内验证过的 tar.gz 是更新*信号*——证明新版本存在且完整——真正的替换由包管理器或文件替换完成。每个 release 为每份资产附带
`.sha256` sidecar 和合并的 `SHA256SUMS`，正是为这一步手动验证准备的。

更新器只写 `<data-dir>/updates` 之下。守护进程的状态
（`~/.local/share/site.jrtx.syncpilot`——`rslsync.conf`、`storage/`、设置）永远不会被更新触碰，任何更新路径都不会自替换正在运行的应用。

## 恢复与故障模式

- **守护进程崩溃。** 默认 `restart-on-crash: true` 时，看门狗按指数退避重启守护进程——2 秒起步、每次翻倍、60 秒封顶——同时手动停止会被尊重、绝不"重启"。关闭该设置时，守护进程状态转为*已崩溃*（"daemon exited unexpectedly"）。证据：`racket/tests/manager-test.rkt`。
- **端口被占。** 配置的 Web UI 端口上若应答的是不同凭据（遗留系统服务、其他用户的守护进程），SyncPilot 拒绝收编并显式报错：错误信息给出端口号和两条出路——退出外来守护进程，或在托盘 → SyncPilot Settings 里改端口。无法通过认证的守护进程绝不会被盲驱动。证据：`manager-test.rkt`（外来守护进程用例）。
- **缺少 rslsync / 首次下载失败。** 启动页提供 sha256 钉定的 CDN 下载；瞬时失败重试 3 次（2 秒、4 秒退避），然后给出可操作的错误提示（网络建议，或手动安装 + 设置路径）——取回器的 bug 不再伪装成网络错误。证据：`racket/tests/install-test.rkt`。
- **退出与卸载都保留数据。** 要紧的东西都在 `~/.local/share/site.jrtx.syncpilot`（设置、`rslsync.conf`、`storage/`），加上首启代装时的 `~/.local/bin/rslsync`。卸载应用（deb/rpm remove、删除 AppImage 或便携目录）只移除应用本体；数据目录留到你亲手删除为止。开启 `keep-daemon-on-exit` 时守护进程脱离并继续同步；否则通过其 API 正常关闭（最后手段才是 kill）。证据：`settings-test.rkt`、`manager-test.rkt`（keep/stop 路径）。
- **故障文案脱敏。** 错误只呈现端口、路径、HTTP/errno 字符串和补救建议——绝无凭据、令牌或同步配置。生成的 `rslsync.conf`（0600 权限）是唯一保存 Web UI 凭据的文件；回环代理按请求注入凭据、不记录头。更新对话框文字可选中，可直接复制不必手抄。证据：`manager.rkt` / `install.rkt` / `updater.rkt` 的错误字符串审计、`proxy-test.rkt`。

## 信任边界

SyncPilot 自身只暴露在回环上：守护进程用应用生成的凭据绑定
`127.0.0.1:<端口>`，web view 加载的代理监听 `127.0.0.1` 的临时端口、按请求注入凭据——守护进程从不响应未认证请求，也唯有官方 rslsync 会触碰你的密钥和文件。SyncPilot 本身没有账户、没有许可校验、没有遥测、没有更新门禁：签名验证是唯一的门，它保护的是你，不是向你去售卖。

## 已知缺口

- **更新不自动替换**——验证过的 `tar.gz` 落在 `<data-dir>/updates` 下；应用它仍是上表所列的手动步骤。无论哪种形态，守护进程状态
  （`~/.local/share/site.jrtx.syncpilot`）都不会被触碰。
