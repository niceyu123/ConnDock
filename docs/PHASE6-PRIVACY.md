# ConnDock 隐私与权限说明

本文件记录当前实现，供 App Store 隐私申报与用户文案核对。面向用户的中英文正文见 [ConnDock 隐私政策草稿](PRIVACY.md)。发布前填写隐私联系邮箱和生效日期，确认公开 HTTPS 地址并接入设置页与 App Store Connect。应用内对应说明统一来自 `apple/Resources/Localizable.xcstrings`，覆盖简体中文和英语。

## 当前数据流

| 数据 | 保存/传输边界 | 清理与控制 |
| --- | --- | --- |
| 主机地址、用户名、分组、标签 | 本机 SwiftData；用户显式启用 CloudKit 后，仅非机密配置进入该用户 iCloud 私有库 | 删除主机/分组；关闭同步保留本地配置，已上传记录不自动清空 |
| 密码、私钥、口令 | 仅在选择记住时进入设备 Keychain；认证时送入本机 Rust SSH 核心，以 SSH 协议连接选定服务器 | 不写入普通数据库、不通过 MCP 导出、不参与 iCloud 同步；删除主机时清理引用及凭据，失败进入待清理队列 |
| 加密配置备份 | 用户主动导出时，配置和已保存的 SSH 凭据经 AES‑256‑GCM 加密后写到用户选择的位置 | 应用不保存备份密码；用户自行管理导出文件及副本。导入凭据写入本机 Keychain，不进入 CloudKit |
| 主机信任指纹 | 本机独立偏好存储；首次确认或指纹变化遵循现有信任策略 | 不随主机配置同步；无法读取可信记录时拒绝自动信任 |
| 终端输入与输出 | 当前会话内存及 SwiftTerm 有界滚动缓存 | 默认无会话录制、遥测或终端内容日志；关闭会话停止任务，应用不提供持久恢复终端内容 |
| 上传、下载 | 用户选择的文件与服务器之间经 SFTP 传输；下载完成前在 App 私有缓存暂存 | 通过原生文件授权/导出；用户可清除任务副本，突然退出可能留下系统可清理缓存；断网可能留下远端未提交临时文件 |
| 服务器指标 | 经已验证 SSH 身份执行固定只读采集，保留本次有限历史 | 隐藏、断开或后台后停止采集，不发送至开发者服务 |
| MCP（仅 macOS） | 默认关闭；用户逐主机/工具授权，任意命令逐次在主 App 审批；结果交给用户主动接入的本机 AI 客户端 | 撤销/关闭后拒绝新请求；外部客户端如何处理结果由其自身设置决定，批准前应检查目标、命令及输出范围 |
| MCP 审计 | 本机有限记录工具、主机 UUID、时间、结果、耗时及命令摘要 | 不保存密码、私钥、完整命令、路径、终端输出；审计不参与同步 |
| 语言、外观、主题与工具偏好 | 本机偏好 | 可在设置修改；不随 CloudKit 配置同步 |

当前没有广告 SDK、分析 SDK、自建数据接收后端或跟踪域。PrivacyInfo 声明 `NSPrivacyTracking=false`，采集列表为空。填写商店隐私标签时，应对照最终构建核对开发者及集成的第三方合作方是否可访问或保留用户数据，并分别核对用户选择的 SSH 服务器、CloudKit 私有库与外部 MCP 客户端的传输边界。隐私政策仍须向用户说明这些功能的数据处理。 [Apple App Privacy 填报说明](https://developer.apple.com/app-store/app-privacy-details/)

## 平台权限与后台

- 主 App 只连接用户选择的 SSH/SFTP 服务器。两平台的本地网络用途说明由 String Catalog 生成原生 `InfoPlist.strings`，不维护第二份 UI 文案。是否实际弹出系统授权由平台、地址与网络环境决定；Local 模拟器通过不证明真机 LAN 授权成功。
- macOS 主 App 保留沙盒、网络客户端和 MCP 本机 socket 所需网络服务端能力。helper 独立沙盒，仅网络客户端和专用 App Group；不授予数据库、Keychain、CloudKit 或网络服务端能力。真实 Team/App Group 沙盒验收仍见 Phase 5 待办。
- iOS/iPadOS 真正进入后台后拒绝新终端输入、清空未发送队列、取消未完成认证/传输及指标采集。恢复时先验证原 SSH transport；失败后手动重连，不自动取凭据认证。操作系统可随时挂起或终止连接，没有后台常驻承诺。
- macOS 普通失焦不触发会话暂停。应用无屏幕录制、麦克风、摄像头或通讯录权限。

## Required Reason API 清单

| 资源 | 类别/理由 | 实际目的 |
| --- | --- | --- |
| 主 App | UserDefaults `CA92.1` | 应用自身语言、外观、信任与工具偏好 |
| 主 App/helper | FileTimestamp `C617.1`、`3B52.1` | App/专用 group 容器内文件生命周期，以及用户明确选择的文件元数据 |
| 主 App/helper | SystemBootTime `35F9.1` | 任务超时、间隔、经过时间；不上传启动时间或构建设备指纹 |

声明针对当前 Swift/Rust 静态依赖与用途；依赖升级或新增 API 后须重新核对。依据 Apple 的 [隐私清单说明](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) 和 [Required Reason API 分类](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)。正式上传前还需在 Xcode 检查归档隐私报告，与 App Store Connect 的实际回答一致。

加密出口分类待核对。按正式构建和上架地区一并核对 Rust SSH 内嵌加密、系统 CryptoKit AES‑256‑GCM 和 CommonCrypto PBKDF2‑HMAC‑SHA256 配置备份，再据此确认 `ITSAppUsesNonExemptEncryption` 及所需文件。 [Apple 加密出口说明](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
