# Apple 三端 SSH 客户端 — Codex 开发任务书

> 状态：V1.2 开发草案（2026-10-26，增加完整简体中文/英文切换与浅色/深色外观切换）
> 产品名称：**ConnDock**。Xcode 工程为 `ConnDock.xcodeproj`；Target、模块和可执行文件统一使用 `ConnDock`（2026-10-28 用户授权统一内部命名）。用户 2026-10-28 授权新建独立正式 App，Bundle ID 为 `com.ruohai.conndock`，CloudKit 使用独立的 `iCloud.com.ruohai.conndock`；旧 TermAll 身份和数据不会自动迁移。
> 目标：macOS / iOS / iPadOS 原生 SSH、SFTP 与服务器管理工具。
> 交付方式：**按阶段迭代，每阶段可编译、可演示、可测试；禁止一次性生成所有功能。**
> 平台范围更新（2026-10-27）：按用户明确要求，**macOS 正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）**。不得生成、宣传或发布 Intel / Universal macOS 包；历史阶段的 Intel 编译记录不代表当前支持承诺。

## 0. 给 Codex 的执行要求（必须遵守）

你是本项目的主开发工程师。请先检查当前仓库和本机工具链（Xcode、Swift、Rust、Cargo、已安装的模拟器），读取本任务书，并依照以下规则工作：

1. **先输出 Phase 0 的具体执行计划和待确认的环境限制，然后从 Phase 0 开始实际实现。** 不要在第一次执行时直接实现全部功能。
2. 每阶段完成后提交：已完成项、改动文件、构建/测试命令与结果、未解决问题、下一阶段建议。无法运行的测试标记“未验证”，不得伪称通过。
3. 保持项目在各阶段均能独立构建；先打通真正的 SSH 链路，再扩展 UI、SFTP、监控、同步。不能用静态假数据冒充已实现的功能。
4. 使用稳定且兼容的依赖版本并锁定版本；先查阅实际库 API，不要臆造 russh / UniFFI / SwiftTerm 接口。
5. 不建立自有云后端、用户账号、业务 API、数据库服务器；只使用本地存储和 Apple CloudKit。
6. 遵循 Apple Human Interface Guidelines；如已安装 `apple-design` Skill，读取后用于设计原生 UI。不要把 WebView / Tauri 当作主 UI。
7. 任何密码、私钥、令牌或用户终端内容都不能写入日志、普通数据库或 Git。默认不开启终端录制与遥测。
8. 如果某步骤需要 Apple Developer 账号、真实设备、CloudKit Container、签名证书或 SSH 测试服务器，请使用可配置占位符或模拟适配器，列出用户需在 Xcode 完成的配置，**不要捏造账号、凭据或测试结果**。
9. README 和内部开发文档优先使用简体中文，代码标识符使用清晰英文；**用户界面必须从 Phase 0 即完整支持简体中文、英语可手动切换**，包括菜单、错误、设置、权限提示、空状态及 MCP 审批文案，严禁只预留国际化结构而没有英语翻译。
10. 每次只处理本阶段范围，不擅自添加 Docker、团队协作或应用内 AI 对话/模型 API。macOS MCP 工具调用属于本任务书明确规定的功能，须在指定阶段实施；不要提前实现。

## 1. 产品目标与原则

开发一款定位类似 FinalShell 的 SSH 客户端，视觉参考 Termius 的现代 Apple 原生设计、功能布局参考 FinalShell、终端交互参考 iTerm2。支持 Mac、iPhone、iPad，共用 SwiftUI 应用代码和 Rust SSH 核心。

原则：本地优先、SSH 直连目标服务器、可选 iCloud 配置同步、安全默认、Apple 原生、轻量高效、易于维护、保留未来复用 Rust 核心开发其他平台的可能性。

建议最低系统版本为 macOS 14、iOS/iPadOS 17（最终以实际依赖、用户设备覆盖和构建验证为准）；macOS 仅适配 Apple Silicon（M 系列，arm64），不支持 Intel，不提供 Universal macOS 包。

## 2. 技术栈（已确定，不随意替换）

| 层次 | 技术 | 职责 |
|---|---|---|
| UI | SwiftUI + SF Symbols + Apple 原生控件 | 三端界面、导航、交互、状态 |
| 国际化 | String Catalog（`.xcstrings`）+ SwiftUI Locale | 简体中文/English，应用内动态切换 |
| 外观 | SwiftUI ColorScheme + 系统语义颜色 | 跟随系统/浅色/深色，应用内即时切换 |
| 终端模拟器 | SwiftTerm | ANSI/VT/Xterm、终端输入输出渲染 |
| 监控图表 | Swift Charts | 资源监控展示 |
| SSH 核心 | Rust + Tokio + russh | TCP、认证、SSH 会话、PTY、Channels |
| SFTP | russh-sftp | 文件浏览与传输 |
| 跨语言桥接 | UniFFI | Rust ↔ Swift 类型、方法及事件 |
| 本地结构化数据 | SwiftData | 服务器、分组、外观设置、同步状态 |
| 机密信息 | Apple Keychain / Security.framework | 密码、私钥、密钥引用 |
| iCloud | CloudKit 私有数据库 + CKSyncEngine | 服务器配置的可选增量同步 |
| 日志/测试 | OSLog、Rust tracing、Swift Testing/XCTest、cargo test | 调试、质量保证 |
| macOS AI 集成 | MCP stdio + 官方 Rust `rmcp` SDK + 本地 IPC | 供 Codex/Claude Code/Cursor 安全调用 SSH 客户端 |
| 开发工具 | Xcode + RustRover + Codex | UI、Rust 核心、协同开发 |

参考上游：
- https://github.com/Eugeny/russh
- https://github.com/AspectUnk/russh-sftp
- https://github.com/migueldeicaza/SwiftTerm
- https://github.com/mozilla/uniffi-rs
- https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5

**特别说明：** SwiftTerm 当前存在较新的 API 演进，应使用选定版本对应文档和示例。UniFFI 与 Swift 并发隔离可能产生 Sendable/Actor 编译问题，桥接层必须有明确的线程与生命周期管理。先完成 PoC 再锁定最终版本。

## 3. 系统架构与边界

```text
macOS / iOS / iPadOS
└── SwiftUI
    ├── Hosts / Groups / Settings
    ├── Localization（zh-Hans / en；应用内切换）
    ├── AppearanceManager（system / light / dark）
    ├── TerminalView（SwiftTerm 的 AppKit/UIKit 包装）
    ├── SFTP UI / Transfer Queue UI
    ├── Monitor（Swift Charts）
    ├── LocalStore（SwiftData，本地权威数据）
    ├── CredentialVault（Keychain，秘密信息）
    ├── CloudSyncService（CloudKit + CKSyncEngine，可选）
    └── SSHCoreBridge（UniFFI；明确生命周期、取消、回调）
        └── Rust Core / Tokio Runtime
            ├── SSH Session Manager（russh）
            ├── PTY / Channel Manager
            ├── SFTP Manager（russh-sftp）
            ├── Monitor Collector（SSH 远程命令）
            └── Port Forward Manager（后续阶段）
                           ⇅ SSH/TCP
                        用户的远程服务器
```

边界必须清晰：
- Swift 管界面、Keychain、CloudKit、本地模型及 Apple 特有能力。
- Rust 管 SSH 会话、认证、PTY、SFTP、资源采集、异步网络任务。
- Rust 不直接依赖 SwiftData/CloudKit/SwiftUI；SwiftUI 不直接操作 russh。
- 主机配置与会话实例分离；同一 Host 可有多个 TerminalSession。
- 终端输出用字节数据块与有界缓冲进行传输，避免每字符跨 FFI 回调或频繁触发 SwiftUI 重绘。
- 通过状态机和可取消任务统一管理连接、重连、超时、关闭与错误。

## 4. UI 设计要求

### 4.1 总体视觉

采用之前确定的组合：**Termius 式简洁现代视觉 + FinalShell 式功能布局 + iTerm2 式终端交互**。**必须支持跟随系统（默认）、浅色、深色三种外观模式，用户可在 App 设置中手动切换，切换立即生效，无需重启。** 主要应用使用系统语义颜色与原生导航。深色界面可采用蓝黑基调和克制的蓝色强调色。终端不使用影响文字可读性的玻璃模糊背景。**必须支持简体中文（默认）和英语的应用内独立切换，且不依赖更改设备系统语言。**

UI 必须包含空数据、加载、连接失败、断网、无权限、同步中和同步错误等状态；无真实监控数据时显示“暂无数据”，不能显示虚构 CPU/内存值。

### 4.2 macOS 主界面

```text
┌────────────────────── 标题栏 / 工具栏 ────────────────────────┐
│ [侧栏] [开始][终端标签 …][+]           [本地终端][右栏]  │
├───────────┬─────────────────────────────┬───────────────────┤
│ 主机侧栏   │ 连接状态                    │ 服务器 Inspector │
│ 搜索      ├─────────────────────────────┤ 状态 / CPU / 内存  │
│ 收藏      │ SSH 终端（内容占主要空间）   │ 磁盘 / 网络 / 延迟 │
│ 最近连接  │                             │                   │
│ 生产环境  ├─────────────────────────────┤                   │
│ 开发环境  │ [⌄ SFTP] [传输任务] [命令]    │                   │
└───────────┴─────────────────────────────┴───────────────────┘
```

- 主机侧栏可隐藏、可搜索、分组可折叠，支持右键菜单。
- 中间终端支持多标签；分屏为 P1，但需要保留工作区模型和 UI 扩展位置。
- 右侧 Inspector 和底部 SFTP 均可折叠；分隔区域可拖动调整大小；记忆布局。
- macOS 使用标准 Menu Commands 和快捷键：⌘N 新建、⌘K 快速连接/查找、⌘T 新终端、⌘W 关闭当前标签、⌘, 设置等（与系统行为冲突时调整）。
- 2026-10-27 界面调整：窗口工具栏移除重复的新建、连接、断开、上传和下载按钮；新建连接使用侧栏主入口及空终端引导，连接在主机列表操作，断开在终端状态栏操作。分组标题旁常驻 `+`，取消列表中的“新建分组”操作行。系统菜单和快捷键保留。
- SFTP 支持将本机文件拖入当前远端目录；拖入时显示目标路径，同名覆盖需确认。保留文件选择上传按钮。文件浏览时显示传输摘要和进度，完整任务列表支持上传/下载进度、已传输量/总大小、百分比、取消、重试及下载保存。首版拖入不包含文件夹递归上传。
- 2026-10-28 用户授权的进一步调整：macOS“开始/终端”标签移动到原生窗口顶部，移除右上角布局按钮。主机侧栏、服务器信息面板使用箭头收起；收起后在对应窗口边缘保留展开箭头。底部 SFTP/传输任务/命令栏在收起后仍可见，可通过箭头或标签重新展开；现有宽高与显隐偏好继续本机保存。
- 同日标签样式补充：标签直接嵌入顶部，采用平直边框和顶部选中指示，去除外层工具栏玻璃分组背景；新建标签的加号紧跟最后一个标签并随标签一起滚动，不固定在窗口右侧。保留较旧 macOS 的 API 兼容分支。
- 顶部标签使用靠左工具栏布局，并按实际窗口坐标与下方终端/SFTP 内容区域左边缘对齐；调整窗口或侧栏宽度时保持对齐。侧栏收起时为系统窗口控制按钮保留必要空间。
- 2026-10-28 品牌图标更新：系统 App 图标使用用户提供的蓝底白色云朵终端图案；应用内左上角使用同款图案的黑灰白单色透明符号，随浅色/深色外观适配。macOS 侧栏收起时保留品牌图标和展开按钮，避免标题拥挤；iPhone/iPad 使用各自原生布局展示。
- 同日工具栏精简（以用户确认的示意图为准）：macOS 右上角仅保留“本地终端”和图标形式的右侧信息面板开关，后者在面板收起后仍可展开。设置入口固定在主机侧栏左下角，同时保留应用菜单和 `⌘,`；侧栏使用左上角开关及面板内收起箭头，底部使用自身标题栏箭头和标签展开/收起。移除右上角重复的设置、左侧栏和底部面板按钮，隐藏未实现的分屏入口。iPhone/iPad 沿用现有原生布局。
- 本次明确启用原 P1 中的常用命令片段：支持添加、编辑、删除，文本仅保存本机 Keychain，不记录终端历史、不进入普通数据库或 CloudKit。执行前显示完整命令和确切目标，用户主动确认后发送到该已连接终端；确认期间目标切换或连接不可用时拒绝发送，不自动重连、切换目标或执行其他命令。此入口属于用户终端操作，不改变 MCP 的授权和审批规则。
- SFTP 收藏只保存用户显式选择的路径，按主机地址、端口及用户名隔离并仅在本机保存。可收藏当前目录、目录条目或文件所在目录；点击收藏跳转，文件收藏同时选中对应条目。支持取消收藏，收藏失效沿用正常的 SFTP 错误提示。
- 终端字体使用等宽字体，禁止把终端文本通过 SwiftUI 的普通 Text 逐行拼装；应直接嵌入 SwiftTerm 原生视图。

### 4.3 iPhone

主机列表 → 连接详情 → 全屏 SSH 终端；SFTP 与监控使用独立页面/Sheet。终端提供 Esc、Tab、Ctrl、Alt、方向键的快捷工具条和复制粘贴；避开安全区域、键盘遮挡，支持横屏和软/硬键盘。

### 4.4 iPad

自适应侧边栏 + 多标签终端，支持外接键盘、触控板与多窗口尺寸变化；不简单把 macOS 界面按比例缩小。

### 4.5 首批页面

1. 服务器列表/分组/搜索。
2. 新增和编辑 SSH 连接（主机、端口、用户名、认证、分组）。
3. SSH 终端主工作区（连接状态、标签、字体及主题）。
4. SFTP 文件管理、传输任务列表。
5. Linux 系统监控。
6. 设置（外观、终端、iCloud 同步、安全、关于）。
7. macOS 专属“AI 工具接入”设置页（MCP 开关、允许访问的主机、允许的工具、审批及审计日志）。

### 4.6 国际化与多语言要求（P0，从 Phase 0 落地）

- **语言**：简体中文（`zh-Hans`，默认）和英语（`en`）。在“设置 → 通用 → 语言”中手动选择，且不需要修改 macOS/iOS 系统语言。
- 语言选项明确展示为 **简体中文 / English**；设置后立即更新正在显示的 SwiftUI 页面、导航栏、菜单、工具栏、表单字段、对话框、空状态、错误信息、提示和权限审批文案，原则上不要求重启。
- 使用 Xcode **String Catalog（`.xcstrings`）** 管理全部面向用户的 UI 文案，统一维护稳定的本地化 key；通过 `LocalizedStringKey`、`String(localized:)` 或合适的本地化封装调用，避免直接在业务逻辑中硬编码中文 UI 字符串。
- 应用内语言偏好通过 SwiftUI `Environment(\.locale, ...)` 或等效可验证的应用级注入管理；macOS 的 Commands / Menu、原生弹窗和系统产生的字符串须根据平台特性实测。原生系统文案由系统负责的部分不承诺全部强制变为所选语言。
- App 名称、品牌、IP、域名、用户名、服务器备注、远端文件名、终端原始输出、用户命令、SSH/SFTP 数据**不得被自动翻译**；只翻译应用自身 UI 文案。
- 日期、时间、数字、容量单位使用适配所选语言的格式化 API；不能通过字符串拼接硬编码词序，必要时使用本地化插值与复数规则。
- 新增 UI 必须同时增加 `zh-Hans` 和 `en` 文案；禁止依赖机器自动翻译作为最终校对结果，英文需符合常见 SSH/开发者工具术语。
- 默认语言策略：应用内未曾设置语言时，默认显示简体中文；用户主动选 `en` 后优先应用英文，即使系统语言仍是中文。语言选项持久化后下次启动继续生效。

### 4.7 外观与主题要求（P0，从 Phase 0 落地）

- **模式**：`system`（跟随系统，默认）、`light`（浅色）、`dark`（深色）。在“设置 → 外观”中以单选或原生选择控件呈现。
- 用户切换后立即影响当前应用的导航、侧边栏、列表、弹窗、工具栏、Inspector、SFTP 和监控图表；**跟随系统模式**必须响应系统深浅色变化。
- SwiftUI 层集中管理 Appearance 设置，采用 `preferredColorScheme`、系统语义色和动态资源；禁止页面散落硬编码固定黑/白背景造成主题不一致。
- SwiftTerm 终端可独立选择终端配色方案，但至少提供**与应用外观联动**选项：系统浅色时使用可读的浅色终端方案，深色时使用可读的深色终端方案。不要强行翻译或修改 ANSI 终端输出数据。
- 图标、边框、状态色和图表在两种外观下均需保证可辨识度和足够的文本对比度。Liquid Glass 只用于合适的导航和控件层，不影响终端正文可读性。
- 外观模式与语言**是两个独立设置项**；切换其中一个不能意外重置另一个。
- 首版语言和外观偏好按**当前设备本地保存**（例如 AppStorage/UserDefaults），避免在 iCloud 同步后强制其他设备改变语言或外观。若将来增加跨设备偏好同步，须另设开关。

### 4.8 设置页面最小交互（P0）

```text
设置 / Settings
├── 通用 / General
│   └── 语言 / Language: [简体中文 | English]
├── 外观 / Appearance
│   └── 模式 / Mode: [跟随系统 | 浅色 | 深色]
├── 终端 / Terminal
│   └── 终端配色 / Terminal Colors: [跟随应用 | 独立主题]
├── iCloud 同步 / iCloud Sync
└── 安全 / Security
```

**Phase 0 验收演示**：Mac 与 iPhone/模拟器各演示一次 `简体中文 ↔ English` 和 `跟随系统 ↔ 浅色 ↔ 深色`，并通过重新启动验证配置保持；至少主页、设置页、占位终端界面和 macOS 工具栏均具备两种语言及外观。不得只创建空翻译文件而不实际接线。

## 5. 第一版功能范围（MVP）

### P0：必须可用

**主机管理**：新增、编辑、删除、分组、收藏、最近连接、搜索、连接测试；本地持久化。

**SSH**：密码和 Ed25519 密钥登录；根据实际支持情况验证现代 RSA-SHA2；首次连接主机指纹确认、后续密钥变更阻断；交互 PTY；UTF-8、ANSI、窗口 resize、心跳/断线、明确的错误提示；多终端标签。

**SFTP**：列目录、上级目录、上传/下载、重命名、删除、新建目录、进度、取消、失败重试；文件以流式/分块方式传输，允许大文件且内存占用有界。

**Linux 监控**：通过 SSH 在远程执行预定义只读命令，从 `/proc/stat`、`/proc/meminfo`、`/proc/net/dev`、`/proc/uptime` 及 `df` 采集指标；默认 5 秒刷新，可停用。权限不足或非 Linux 时显示明确提示。

**本地配置与安全**：SwiftData、Keychain、独立终端字体与主题设置、**应用内简体中文/英语完整切换、跟随系统/浅色/深色三态外观即时切换**、非敏感日志。

**iCloud**：允许手动启用配置同步；正常工作不依赖 iCloud 登录；关闭同步不删除已有本地配置。同步凭据属于单独开关，首版可以先仅支持同步非机密配置并显式提示其他设备重新输入凭据，待验证后添加可同步 Keychain。

**macOS AI/MCP 集成（V1 必须交付，安排在 Phase 5）**：本地 MCP stdio 服务；用户主动启用并指定授权主机；AI 可列主机、查询资源/服务状态、浏览授权目录；任意 SSH 命令必须在 Mac 端经过操作级用户确认。所有权限由 App/MCP 服务端独立强制校验。

### P1：首版稳定后追加

终端分屏、SSH 跳板机、keyboard-interactive / MFA、SSH Agent、端口转发、本地和远程双栏 SFTP、远程文件编辑、断点续传、快捷命令片段、SSH Config 导入、可同步凭据。

### P2：后续增强

Docker 管理、批量运维、可扩展监控、其他平台客户端、MCP 高危写操作自动化。不在 MVP 期间提前开发。

## 6. 核心数据模型建议

**Host**：`id(UUID)`、`displayName`、`hostname`、`port(Int)`、`username`、`authMethod`、`credentialRef`、`groupId`、`notes`、`favorite`、`sortIndex`、`createdAt`、`updatedAt`、`deletedAt?`、`syncRevision`。

**HostGroup**：`id`、`name`、`sortIndex`、`createdAt`、`updatedAt`、`deletedAt?`。

**TerminalProfile**：`id`、`name`、`fontName`、`fontSize`、`theme`、`scrollbackLimit`、`cursorStyle`、`bellEnabled`。

**HostTrustRecord（仅本地）**：`host`、`port`、`algorithm`、`fingerprint`、`trustedAt`、`lastCheckedAt`。

**SFTPTransfer（仅本地）**：`id`、`sessionId`、`remotePath`、`localBookmarkOrURL`、`direction`、`bytesTransferred`、`totalBytes?`、`status`、`error?`。

**AppSettings**：默认 TerminalProfile、iCloud 开关、隐藏面板状态等。**应用语言（zh-Hans/en）和外观模式（system/light/dark）在第一版按设备存储于 AppStorage/UserDefaults，不进入 CloudKit 同步模型**，以避免不同设备互相覆盖设置。**不将密码/私钥或认证材料放入这些表中。**

同步对象使用稳定 UUID 与 CKRecord ID 映射、修改版本以及 tombstone（删除标记）；避免依赖 SwiftData 唯一约束作为跨设备去重机制。数据库迁移按版本管理。

## 7. Rust ↔ Swift API 协议（设计目标，不是臆造的现成库 API）

Rust 层暴露稳定的应用级 API，不直接暴露 russh 内部结构：

```text
SSHCore
  connect(host, authRequest, hostKeyVerifier) -> SessionId
  disconnect(sessionId)
  openTerminal(sessionId, rows, columns, terminalType="xterm-256color") -> TerminalId
  sendTerminalInput(terminalId, bytes)
  resizeTerminal(terminalId, rows, columns)
  closeTerminal(terminalId)
  subscribeSessionEvents(sessionId, callback)

SFTPService
  listDirectory(sessionId, remotePath)
  makeDirectory(sessionId, remotePath)
  rename(sessionId, source, destination)
  delete(sessionId, remotePath)
  upload(sessionId, localHandle, remotePath) -> TransferId
  download(sessionId, remotePath, localHandle) -> TransferId
  cancelTransfer(transferId)
  subscribeTransferEvents(transferId, callback)

MonitorService
  startLinuxMonitoring(sessionId, intervalSeconds) -> MonitorId
  stopMonitoring(monitorId)
  subscribeMonitorEvents(monitorId, callback)
```

上述是概念接口。具体回调、文件句柄、`Data`/byte buffer 类型必须根据 UniFFI 实际能力调整。跨语言接口不要让 Rust 直接读 Swift 沙盒文件路径：优先由 Swift 获取有授权的文件资源，再明确设计跨 FFI 文件读写/安全拷贝接口。不得直接把 Keychain 里的凭据转换为可持久化明文字段。

**状态机**：`idle → connecting → verifyingHostKey → authenticating → connected → disconnecting → disconnected`，并定义 `failed(error)`；任何阶段均可显式取消。所有取消和断开均应释放 Rust Task、SSH Channels 与订阅回调。

**并发原则**：所有网络工作在 Tokio 中执行；Swift 主线程只负责 UI 更新；FFI 回调限流、批量输出、避免循环引用和数据竞争。

## 8. iCloud 同步与安全设计

- **本地权威存储**：SwiftData **不直接开启自动 CloudKit 镜像**，由 `CloudSyncService` 读取本地变更并通过 CKSyncEngine 同步 CloudKit Private Database，避免同时使用两套自动同步机制导致双重写入。
- **同步内容**：主机名称、主机地址、端口、用户名、分组、收藏、备注、部分终端设置。每项仅限用户开启同步后上传。
- **不自动同步**：密码、私钥、主机信任决定、终端输出、命令历史、临时文件、正在运行的会话、SFTP 临时任务。
- **隐私**：IP、域名、用户名、备注等可能敏感的字段使用 `CKRecord.encryptedValues`，不将敏感数据放到 recordName 或明文字段中；先验证 CKRecord Schema 和查询限制。
- **同步可靠性**：本地更新日志/outbox、版本与删除标记、去重、冲突规则、账号切换检测、断网重试、同步状态展示。关闭同步只停止远程复制，不直接删除本地数据。删除云端副本必须独立确认。
- **凭据**：默认只存在本机 Keychain；未来用户主动选择后，再使用可同步 Keychain 条目。设备绑定/Secure Enclave 私钥不允许假定可跨设备迁移。
- **前后台**：严格遵守 iOS 生命周期；普通 SSH 不保证后台永久存活；前台恢复检查连接状态并给出重连选项，可建议用户在服务器使用 tmux。
- **Entitlements**：macOS App Sandbox Outgoing Connections；本地端口转发后续按需启用 Incoming Connections；iCloud/CloudKit 容器和必要后台能力由 Xcode 配置。所有标识符使用用户项目中的真实值，不填假证书。

## 9. 建议项目目录

```text
ConnDock/
├── README.md
├── docs/
│   ├── PRD.md
│   ├── ARCHITECTURE.md
│   ├── DESIGN.md
│   ├── SECURITY.md
│   └── PHASES.md
├── apple/
│   ├── ConnDock.xcodeproj  # 由 XcodeGen 生成
│   ├── Apps/
│   │   ├── macOS/
│   │   └── iOS/
│   ├── Shared/
│   │   ├── Models/
│   │   ├── Storage/
│   │   ├── Localization/          # String Catalog + Locale 管理
│   │   ├── Appearance/            # 跟随系统 / 浅色 / 深色
│   │   ├── Security/
│   │   ├── Services/
│   │   └── Components/
│   ├── Features/
│   │   ├── Hosts/
│   │   ├── Terminal/
│   │   ├── SFTP/
│   │   ├── Monitoring/
│   │   ├── CloudSync/
│   │   ├── AIIntegration/   # macOS-only；Phase 5
│   │   └── Settings/
│   └── Packages/SSHCoreBridge/
├── rust-core/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   └── crates/
│       ├── ssh-core/
│       ├── sftp-core/
│       ├── monitor-core/
│       ├── tunnel-core/        # P1 再实现
│       ├── mcp-server/         # macOS-only；Phase 5
│       └── apple-ffi/
├── scripts/
│   ├── build-rust-apple.sh
│   ├── generate-bindings.sh
│   ├── build-xcframework.sh
│   └── verify.sh
├── tests/
└── .github/workflows/
```

配置目标仅覆盖：`aarch64-apple-darwin`、`aarch64-apple-ios`、`aarch64-apple-ios-sim`。macOS App、Rust 库和 XCFramework 的 macOS slice 均仅包含 arm64；不构建 `x86_64-apple-darwin`，不再合并 Universal macOS 静态库，也不支持 Intel iOS 模拟器。通过静态库与 XCFramework 给 Swift 调用，构建流程必须自动化且可重复；发布前检查实际 Mach-O 与 XCFramework 架构。

## 10. 分阶段交付与验收

### Phase 0 — 仓库骨架和设计基础

**实现**：检测本机环境；初始化 Git 目录、Cargo Workspace、Xcode macOS/iOS 工程、共享 Swift 模块；集成基本导航、**完整的 zh-Hans/en String Catalog、应用内即时语言切换、system/light/dark 三态主题控制及设置页**、依赖版本管理；添加 README、架构图、脚本和初始测试。可先用明确标注的 Preview Mock 展示 UI，但不得冒充 SSH/监控实现。

**验收**：两个 Apple Target 均能构建/运行（未具备真机则至少模拟器与可用 macOS Target）；`cargo test` 通过；CI/本地脚本清晰；**简体中文/英语和三种外观可在应用设置中即时切换并持久化，macOS/iPhone 至少覆盖主页、设置页、终端占位页**；输出环境问题清单。

### Phase 1 — SSH PoC（最高优先级）

**实现**：Rust SSH 连接 → UniFFI → SwiftTerm，实际 SSH 密码/密钥登录，主机身份验证、PTY、输入输出、resize、关闭、错误/取消；覆盖 macOS 和 iOS 设备或模拟器。

**验收**：真实 SSH 测试服务器上能运行 `pwd`、`ls -la`、`top`/`htop`（环境具备时），颜色/键盘正确；主机指纹变化被拦截；连接中途断网能正确收尾，无明显任务泄漏。不能仅用模拟字符输出代替集成测试。

### Phase 2 — 主机管理与核心 UI

**实现**：SwiftData 主机与分组、Keychain、主机连接表单、侧边栏、多标签终端、终端外观、iPhone/iPad 适配、macOS Inspector 容器与底部 SFTP 容器的基本布局。**新增 UI 页面同步补齐中英文 String Catalog 与两种主题的适配。**

**验收**：重启应用后主机配置仍在；密码不落普通数据库；可在多标签之间切换 SSH Session；主 UI 符合设计并有空/错误/加载状态。

### Phase 3 — SFTP 与 Linux 监控

**实现**：完整基本文件操作、传输进度/取消/失败提示、Linux `/proc` 监控采集解析、Swift Charts；UI 面板折叠和资源释放。

**验收**：小文件与至少 2GB 测试文件传输；传输过程内存有界、可取消；网络断开给出明确错误；监控指标与服务器端基准命令结果大致一致，非 Linux 清晰提示不支持。

### Phase 4 — iCloud 同步

**实现**：CKSyncEngine、手动开启/关闭、CloudKit 私有库、加密敏感配置字段、变更队列、同步状态、离线重试、跨设备冲突与删除同步。首先**只同步非机密配置**。

**验收**：设备 A 新增/修改/删除主机，设备 B 最终同步一致；断网修改后可恢复同步；关闭同步后本地仍可用；不会把密码/私钥同步进 CloudKit。若缺少 Apple 账号或多台设备，用 MockSyncTransport 进行单元测试并明确标注真实云端端到端测试未完成。

### Phase 5 — macOS AI/MCP 工具接入（V1 必须）

**实现**：在不修改 iOS/iPadOS 发布逻辑的前提下，构建签名的 macOS MCP stdio 辅助程序；用 Rust 官方 `rmcp` SDK 实现 MCP Tools；借助本地 IPC（优先评估 XPC，或受访问控制的 Unix domain socket）向正在运行的 macOS 主应用请求 Host、Keychain/认证和 SSH Core 服务。不要让 MCP 进程直接读取主应用数据库文件或导出 SSH 密码/私钥。增加 AI 工具接入设置页面：默认关闭，启用后逐主机授权、工具权限、单次命令审批、撤销、调用日志。首版至少支持 `list_hosts`、`get_host_info`、`get_server_metrics`、`get_service_status`、`sftp_list`、`ssh_exec`（逐操作确认）；其他写操作按风险延后。`ssh_exec` 必须显示准确目标主机、用户名、原始命令、超时与可能输出范围，App 拒绝后不能执行。运行主应用未启动时应清晰报错并指导打开应用，或实现经过签名与安全验证的唤起机制，不允许绕过审批的无界离线直连。

**验收**：Codex CLI 通过 stdio 成功列出用户授权主机，取得真实的服务器指标；未经授权的主机不可见；任意 `ssh_exec` 必须先在 macOS App 弹出审批并执行精确批准的内容；用户拒绝后无远程执行；MCP 关闭后新请求拒绝；日志不包含凭据；模拟被注入指令的远程日志不会导致额外工具调用被 MCP 服务器自行执行；空闲无常驻 HTTP 监听和无云端依赖；Mac App Store 沙盒、helper 签名、跨进程通信需有真实构建验收记录。

### Phase 6 — 安全、稳定性、发布准备

**实现**：单元和集成测试、长连接、多标签、内存泄漏、后台恢复、权限和 Keychain 验证；设置和隐私文案；App 图标占位（名称未定）；构建签名与 TestFlight 准备。

**验收**：编译、自动化测试、静态检查通过，人工验收清单完整；无法验证的 App Store / iCloud 真机步骤显式列为待办。

## 11. 测试矩阵

- SSH：有效/错误密码、有效/无效私钥、未知主机、指纹改变、超时、错误端口、主机掉线、断网重连、并发会话、PTY 改尺寸。
- 终端：中文与 Emoji、颜色、Ctrl+C、Tab、Esc、光标和选择、滚动大量文本、窗口大小变化、外接键盘。
- SFTP：空目录、中文文件名、特殊字符文件名、小/大文件、同名覆盖、权限不足、取消、网络中断。
- 监控：Linux 版本差异、`/proc` 权限不足、网卡变化、CPU 两次采样、断开停止采集。
- 存储与安全：重启持久化、Keychain 存取、主机信任决定、本地数据库不出现明文秘密、日志脱敏。
- CloudKit：首次启动、未登录 iCloud、跨设备新增/修改/删除、同一记录并发修改、长时间离线、账号切换、关闭同步保留本地数据。
- MCP（macOS）：默认关闭、仅授权主机可见、远程只读预定义采集、任意命令逐次审批、拒绝后无副作用、敏感路径泄露防护、调用日志、并发/超时/输出限制、主 App 退出、Helper 签名/沙盒、Codex stdio 实测。
- 国际化/外观：在 macOS、iPhone、iPad 上验证 zh-Hans/en 即时切换、手动切换后重启保持、系统语言与应用语言不同、常见按钮/错误/菜单中英文覆盖、长英文文本不截断；验证 system/light/dark 和系统外观变化、终端主题联动、两种主题下的文本对比度。
- 平台：macOS Apple Silicon（M 系列，arm64）、arm64 iPhone 模拟器/真机、iPad 布局、不同窗口尺寸、iOS 前后台切换；Intel macOS 与 x86_64 模拟器不在支持或发布验收范围。

## 12. 完成标准（Definition of Done）

- 本阶段功能真正可运行，不仅有静态 UI。
- 提交真实构建和测试记录；有失败必须说明。
- 新功能包含基本测试或明确的手动验收步骤。
- 每个错误可定位、可提示，不因网络异常直接崩溃。
- 所有异步任务可以取消，离开页面或断开连接后无明显资源泄漏。
- 文档、接口及必要配置同步更新；没有密钥、证书或密码进入 Git。
- 视觉与交互保持三端一致的设计体系，但不牺牲原生交互。全部新增 UI 文案有简体中文和英语翻译，系统/浅色/深色设置可用且切换后不需重启。
- macOS MCP 只在用户启用、授权和审批下操作远端；敏感操作不可仅依赖 AI 客户端自身的确认框。

## 13. Codex 第一次执行的具体指令

**现在只完成 Phase 0，允许为 Phase 1 提前做最小的依赖与构建验证。不要一次性开发 SSH/SFTP/iCloud/MCP 的完整功能。特别注意：本 V1.2 已将中英文动态切换与三态外观模式升级为 Phase 0 必须验收的正式功能。**

请依次：

1. 检测现有仓库（如果已有内容，保护既有代码）和 Xcode / Rust / Cargo / Simulator 环境。
2. 确认最低系统版本和构建方式，列出依赖版本及选型理由。
3. 建立 Monorepo、Rust Cargo Workspace、macOS/iOS SwiftUI 工程、Shared 模块和测试脚手架。
4. 建立可实际切换的简体中文 / English 多语言设置、`system/light/dark` 三态外观设置，持久化且即时生效；构建基础路由与 macOS 三栏+底部面板的可运行占位 UI；iPhone 提供主机列表和终端占位页。**首页、设置、菜单、占位页必须全部接入 String Catalog，不可只留空结构。** 所有假数据清楚标注 Preview/Mock。
5. 建立 Rust Core、UniFFI 和 Swift Bridge 的最小可调用示例，验证返回一个简单值或版本号。
6. 增加 `scripts/verify.sh`，尽可能统一执行 Cargo 格式检查/测试和 Xcode 构建（缺少工具时准确报告）。
7. 编写 `README.md`（运行步骤）及 `docs/ARCHITECTURE.md`（架构、职责、风险）。
8. 报告生成的文件树、执行的命令、通过/失败的结果和下一阶段 Phase 1 的开发清单。

**完成后停止在 Phase 0，等待下一条开发指令。**


## 14. macOS AI 工具接入详细方案（新增）

### 14.1 功能定位与范围

macOS 版可以向 Codex、Claude Code、Cursor 及兼容 MCP 的其他 AI 工具暴露 SSH 管理能力。**这里的 AI 是外部客户端主动调用本机工具，不是在 SSH 客户端内集成模型或聊天 UI**。本功能只在 macOS 实现；iPhone / iPad 保持正常 SSH 功能，不运行 MCP Server。

典型场景：用户在 AI 工具中提出“查询 Web-01 的 CPU、内存、磁盘和指定 systemd 服务状态”，AI 调用 MCP 工具，由 ConnDock 使用已保存的连接信息访问服务器，结构化返回结果。对于需要执行任意 Shell 命令的请求，macOS 主应用必须独立弹出操作级确认窗口。

### 14.2 进程与信任边界

```text
Codex / Claude Code / Cursor
      │ MCP stdio（AI 客户端启动签名的辅助程序）
      ▼
conndock-mcp（Rust + rmcp，独立进程）
      │ 本机 IPC（优先 XPC 或经鉴权的 Unix socket）
      ▼
macOS ConnDock App
      ├─ 用户启用开关、主机白名单、工具授权、操作审批、审计日志
      ├─ HostRepository / Keychain / 主机密钥信任校验
      └─ UniFFI → Rust SSH Core → SSH/SFTP → 用户的目标服务器
```

- stdio 是首版唯一必需 MCP 传输。**不默认开放 127.0.0.1 HTTP，更不能监听 0.0.0.0**。以后确需 HTTP 时另做配对、Origin 检查、访问认证与权限审查。
- MCP Helper 不负责存储密码和私钥，也不能通过工具输出将它们暴露给 AI；需要操作目标时，由主应用使用受保护的凭据完成 SSH 连接。
- Helper 必须采用 Apple 支持的嵌入式命令行工具签名方案；核验 App Sandbox、entitlements、Keychain 权限和 App Store 分发可行性，不能因为调试版本能运行就认为可发布。
- AI 工具通过已配置的本地 MCP Helper 调用应用，不需要自建服务器，也不需要产品侧 AI 模型 API 密钥。
- 主应用未运行或处于锁定状态时，不执行需要审批的请求；提示用户打开 ConnDock。所有远程操作由授权状态机统一管理。
- 不信任 MCP 客户端自述的进程名或工具标注即视为身份认证；首版由用户明确安装/配置受信任的 MCP 客户端，服务器侧仍逐项实施授权。

### 14.3 MCP 工具定义（先易后难）

| MCP Tool | 输入建议 | 输出 | 授权策略 | 优先级 |
|---|---|---|---|---|
| `list_hosts` | 无 | 已获授权的 `host_id`、别名、分组 | 启用 MCP 且主机被允许 | V1 |
| `get_host_info` | `host_id` | 脱敏的连接信息和可用状态 | 主机允许 | V1 |
| `get_server_metrics` | `host_id` | CPU/内存/磁盘/网络结构化数据 | 只读专用采集器 | V1 |
| `get_service_status` | `host_id`, `service_name` | 服务状态、近期状态变更 | 限制允许的服务名、结构化执行 | V1 |
| `sftp_list` | `host_id`, `path` | 远程目录元数据 | 受限目录白名单及路径规范化 | V1 |
| `ssh_exec` | `host_id`, `command`, `timeout` | `exit_code`, `stdout`, `stderr` | 每条任意命令要求 Mac App 精确审批 | V1 |
| `sftp_read_file` | `host_id`, `path` | 文件内容（可截断） | 敏感路径和内容审批、额度限制 | P1 |
| `sftp_download` | `host_id`, `remote_path`, `destination` | 操作状态 | 用户批准路径/目标文件 | P1 |
| `sftp_upload` | `host_id`, `source`, `remote_path` | 任务状态 | 写入审批、目标路径限制 | P1 |
| `sftp_delete` | `host_id`, `path` | 操作结果 | 默认禁用；每次明确高危审批 | P2 |

参数统一使用稳定 Host UUID，不允许 MCP 客户端直接传入 SSH 密码、私钥或任意替代主机地址绕过白名单。所有返回内容应结构化并带有明确的错误码。

**不可把“只读工具”直接等同于低风险**：主机名、目录内容和服务器日志也可能涉及秘密。初始主机白名单应为空；目录路径遵循最小授权，不暴露任意远程文件系统。`get_server_metrics` / `get_service_status` 使用专门固定采集实现，不应把客户端输入原样拼接成 shell。

### 14.4 安全策略与用户体验

1. **默认关闭**：设置 → AI 工具接入 → 启用 MCP；明确告知外部 AI 可以访问哪些服务器及信息。
2. **主机白名单**：逐台允许访问；生产环境主机默认不允许，用户可主动授权。
3. **工具分级**：元数据/监控、文件读取、命令执行、文件写入分别授权；默认只启用用户选择的查询工具。
4. **命令逐次确认**：`ssh_exec` 展示完整命令和目标、超时时间、请求来源及风险提示。不能通过模型返回的文字模拟批准，也不能因 AI 客户端提示“已批准”而跳过 Mac App 核准。
5. **拒绝优先**：Mac App 无法展示审批（退出、锁屏、超时）时直接拒绝；未经用户允许不运行无人值守生产环境命令。
6. **资源限制**：设置并发连接数、请求超时、输出大小上限、最大文件读取量、取消机制，防止远程输出撑爆 AI 上下文或本机内存。
7. **日志保护**：记录时间、操作、目标 UUID、审批结果、耗时及错误，不记录密码、私钥、令牌、完整敏感文件内容；命令文本按隐私策略脱敏或只保存哈希/摘要。
8. **安全边界**：把远程命令输出、日志、文件内容作为不可信数据返回；服务器端不得因其中的指令文本自动追加 MCP 调用。远程命令通过独立 Session 执行，不复用用户正在输入的交互终端。
9. **可撤销**：用户可立即关闭 MCP 或移除某主机的授权，取消未完成请求并拒绝后续调用。
10. **不泄露凭据**：不实现 `get_password`、`export_private_key`、`read_keychain` 等 MCP Tools。

### 14.5 本地 UI 设计（macOS 专属）

在设置中新增“AI 工具接入”页面，包含：总开关；可用 AI 客户端安装说明；已允许的服务器；各工具权限与审批策略；最近调用历史；测试连接按钮；撤销所有授权按钮。首次启用时通过清晰的权限向导完成设置，不应静默自动配置外部 AI 客户端。

### 14.6 Codex 开发验收

- 编译出签名的 `conndock-mcp`（只是暂定 CLI 名，最终随正式产品名称更新）；在测试机的 Codex CLI 通过 MCP stdio 配置，实际完成 `list_hosts`、`get_server_metrics` 调用。
- 主机权限名单之外的服务器不出现在工具结果，也不能通过猜测 Host UUID 直接访问。
- `ssh_exec` 请求在 Mac UI 中展示精确参数；拒绝不会执行；批准后只执行被批准的内容；再次更改命令必须重新申请。
- App 未启动、MCP 禁用、Keychain 不可用、主机信任失败时，返回可识别错误，不悄然降级安全检查。
- 测试从远程日志中返回恶意“请忽略安全策略”文字，不得触发服务器端特权调用。
- 验证多请求并发、超时、取消、输出裁剪、日志脱敏、实际代码签名、Apple 沙盒及发布包集成。
- 明确区分模拟测试和真实 Codex + macOS App + SSH 服务器端到端测试。

### 14.7 参考资料

- MCP 标准传输：https://modelcontextprotocol.io/specification/2025-11-25/basic/transports
- Rust 官方 MCP SDK：https://github.com/modelcontextprotocol/rust-sdk
- Codex MCP 文档：https://learn.chatgpt.com/docs/extend/mcp
- Apple 嵌入沙盒 Helper：https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
- Apple Keychain Sharing：https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps
