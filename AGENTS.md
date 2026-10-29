# ConnDock 开发约定

## 唯一有效需求

- 开始任何开发前，完整阅读 `docs/requirements.md`。该文件是当前唯一有效的 V1.2 开发任务书；根目录的原始导入文件仅留存来源，不作为第二套需求。
- 产品名称及系统和 App Store Connect 显示名为 **ConnDock**，Xcode 工程为 `ConnDock.xcodeproj`；Target、模块和可执行文件统一使用 ConnDock。用户已明确要求新建独立正式 App 和独立云端容器，正式 Bundle ID 切换为 `com.ruohai.conndock`；旧 TermAll 身份和数据独立保留，不自动迁移。
- macOS 仅支持 Apple Silicon（M 系列，arm64），正式放弃 Intel；不得新增 x86_64 macOS 编译目标、Universal Mac 打包或 Intel 支持描述。发布前检查实际 App 与 XCFramework 架构。
- 严格按任务书分阶段交付。**Phase 1/2/3 的实现与本机验收已完成；Phase 4 的实现和本机测试已完成，真实云端验收尚未完成**。2026-10-28 新 ConnDock 的 Team 为 `86HC8YA388`、Bundle 为 `com.ruohai.conndock`、独立 Container 为 `iCloud.com.ruohai.conndock`、App Store Connect ID 为 `6827804281`；容器已注册并关联新 App ID，两平台 Development 签名构建与实际 entitlement 已核对，发行签名、TestFlight 和真实云端验收尚未完成，Local 配置保留既有开发身份。旧 `com.ruohai.termall` 的 TestFlight 记录和签名验证仅适用于旧身份，见 `docs/PHASE6-VALIDATION.md`，不得视作新身份已验收；旧 App 暂保留。Phase 5/6 的实现与本机验收见对应阶段记录。用户 2026-10-28 已授权剩余 P1/P2 分阶段实施，其他平台客户端暂缓；Phase 7 的终端分屏与 SSH Config 导入实现和本机验收见 `docs/PHASE7-VALIDATION.md`。Phase 8 的单跳跳板、交互认证、无 PTY 模式及 macOS 容器内专用 Agent 实现与本机验收见 `docs/PHASE8-VALIDATION.md`；不将 Local 沙盒结果视作正式签名或双设备云端验收。后续分发仍遵循用户具体授权。
- `docs/ui/macos-dark.png` 是 macOS 视觉方向参考；不要求逐像素复制。浅色配色独立设计，iPhone/iPad 必须采用各自的原生布局。

## 实现边界

- 使用 SwiftUI/SF Symbols、SwiftTerm、Rust/Tokio/russh、russh-sftp、UniFFI、SwiftData/Keychain、CloudKit/CKSyncEngine、macOS rmcp；不随意替换技术栈。
- Swift 负责 Apple UI/本地存储/凭据/同步，Rust 负责后续网络核心。SwiftUI 不直接操作 russh。
- SSH、SFTP 与监控继续遵循已验证身份和明确状态的边界。Phase 4 使用 SwiftData 本地权威存储与 CKSyncEngine 私有库，只同步非机密主机/分组/标签配置；默认关闭，凭据、主机信任、会话与设备偏好不上传。未配置或 Local 构建不创建 CloudKit 容器实例，不将 Mock 当作真实同步。MCP 默认关闭，仅 macOS 在用户显式启用、逐主机/工具授权及逐命令确认后可用；helper 不读取数据库或 Keychain。
- 所有应用 UI 文案集中维护在 `apple/Resources/Localizable.xcstrings`，每个 key 同时包含 `zh-Hans` 与 `en`；默认简体中文，应用内切换立即生效并本地保存。原生系统管理的菜单文案按平台能力处理并实测。
- 外观提供 system/light/dark，默认 system；语言、应用外观和终端主题独立保存。所有新页面同时适配中英与深浅色。
- 保护已有工作，保持最小修改；不添加无关依赖、无关重构和自建后端。
- 密码、私钥、令牌、终端内容不得写入 Git、普通数据库或日志；默认无录制、无遥测。
- iOS 真正后台后暂停输入/采集和未完成传输，清除过时排队及等待发送的输入；回前台以已有身份无命令验证原 SSH transport，再恢复输入。凭据读取及恢复操作必须校验生命周期与发起 tab；关闭后迟到结果不得复活会话。开发签名归档、未签名编译和发行检查的结果必须分开报告。

## 验证与交付

- 依赖与工具版本固定。Rust/UniFFI 生成物通过 `scripts/` 重建，不手工改生成代码。
- 变更后实际运行适当的构建、测试，优先使用 `scripts/verify.sh`。不得声称未执行的检查通过。
- 阶段交付用中文说明：完成内容、修改文件、命令与结果、未验证项、环境限制和遗留问题。
- Phase 0 必须运行 macOS、iPhone、iPad 界面并提供真实运行截图；至少验证语言、三态外观、重启保持、SwiftTerm 配色联动及真实 UniFFI 调用。
