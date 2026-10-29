# SyncPilot 使用指南

[English](USER-GUIDE.md) · **简体中文**

在 Linux 桌面窗口中管理官方 Resilio Sync 守护进程。

## 当前可用状态

AGPL-3.0 许可的免费 Linux 维护项目。Resilio 的独立许可和服务限制仍适用；SyncPilot 不设付费层。

## 平台与安装

仅支持 Linux。官方 rslsync 二进制及其条款独立于 SyncPilot；Windows/macOS 移植不是当前交付。

从[官方 Releases](https://github.com/turlamai/syncpilot/releases)选择明确标注系统和架构的附件，阅读该版本说明并核对附带校验文件。未列出的附件或平台不视为已交付。预览构建可能没有系统发行者签名或公证；不要为安装而关闭系统安全保护。

## 第一次使用

1. 先使用可丢弃的测试文件夹启动，确认所选守护进程二进制与版本。
2. 通过官方界面连接第二台测试设备，双向验证一个小文件。
3. 提供重要文件夹前，测试守护进程停止重启、登录自启与恢复。

## 数据、备份与恢复

备份 ~/.local/share/site.jrtx.syncpilot 前退出 SyncPilot 并停止 rslsync，包含 syncpilot-settings.json、rslsync.conf、storage/。实际同步文件需另做备份；删除会传播，同步不等于备份。

## 联网、密钥与隐私

界面与控制代理绑定本地回环。官方 Resilio 守护进程会向配置的对端发送文件，也可能访问发现和中继服务。SyncPilot 在本地运行不表示同步文件不会离开电脑。

## 已知限制

第三方兼容、守护进程鉴权恢复及各安装形态更新仍在 #10 跟进。服务或静态安装可能需要运维者管理更新。

## 更新与卸载

先备份数据，再阅读目标版本说明。应用内检查更新不一定能安装当前渠道的更新；按手册区分便携包、系统安装器和源码安装。不要绕过失败的验签或用来源不明的文件覆盖程序。更新失败时保留现有数据与错误信息，使用可信发行包恢复；卸载程序通常不等于删除独立的数据目录，删除个人数据前先确认备份。

## 获得帮助

在 [GitHub Issues](https://github.com/turlamai/syncpilot/issues) 反馈，中文或英文均可。提供版本、系统与架构、安装渠道、复现步骤、预期和实际结果。先用合成样本复现；不要附上密钥、授权文件、数据库、原始私密文档或完整日志。公开支持不承诺响应时限。

## 深入阅读

- [详细手册](../docs/guide.html)
- [更新](../docs/UPDATE.md)
- [守护进程接口](../docs/api-verified.md)
- [项目说明与开发入口](../README.zh-CN.md)
- [现行许可证](../LICENSE)
