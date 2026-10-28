# Phase 7：终端分屏与 SSH Config 导入

日期：2026-10-28。用户授权剩余 P1/P2 分阶段实施；其他平台客户端随后明确暂缓。完整后续范围见 [REMAINING-STAGES.md](REMAINING-STAGES.md)。本阶段只交付下列两项，并不代表剩余 P1/P2 或发行验收全部完成。

## 实现

- macOS 与 iPad regular 支持左右/上下两窗格；macOS 使用原生 HSplitView/VSplitView，iPad 使用可拖动、可无障碍调整的分隔条。iPhone compact 继续显示所选单标签。
- 可创建新空窗格或组合已有标签。每个标签只挂载一份既有原生终端和独立会话；不复制输入或自动重连。取消分屏保留两个标签，关闭窗格释放该会话并优先选择同组邻居。分组仅在本次工作区保存。
- 当前窗格由真实鼠标/first responder 或主动选择决定。底部 SFTP、监控、命令仍以 selectedSession 为目标。终端协议自动回复不能改变该选择；布局重挂载后恢复所选输入焦点。
- macOS 在布局菜单提供入口，⌘D 左右分屏、⇧⌘D 上下分屏；标签右键也可操作。iPad 在终端工具栏提供分屏菜单。
- 三端主机页提供 SSH Config 文件选择、预览、勾选和导入结果；没有 User 时可补默认用户名。重复名称/连接身份跳过，不覆盖。保存复用 HostLibrary 与同步 outbox，不自动连接或读取凭据。
- 支持明确 Host 别名、HostName/User/Port、Host 通配/否定规则、引号和注释、首值优先。IdentityFile 只作为密钥认证提示，不读取或保存路径。Include/Match/不确定语法阻断全文，其他未支持指令阻断匹配主机并解释原因。
- 文件限 256 KiB、8192 行、每行 8192 字节、256 个主机；仅普通 UTF-8 文件，读取 max+1 字节复查大小。全部新增文案接入 String Catalog，中英共 473 个 key。

## 修改范围

- `WorkspaceState.swift`、新增 `TerminalSplit.swift`：标签组合、选择、关闭和迟到焦点保护。
- `TerminalWorkspace.swift`、新增 `TerminalFocus.swift`、`NativeTerminalView.swift`、`LocalShellSession.swift`、`TerminalSession.swift`：窗格、原生视图和焦点。
- `WorkspaceRoot.swift`、`MobileWorkspace.swift`、`HostSidebar.swift`：菜单/平台入口。
- 新增 `SSHConfigParser.swift`、`SSHConfigImporter.swift`、`SSHConfigImportView.swift` 及相应测试。
- `TerminalSplitTests.swift`、`TerminalSplitUITests.swift`、String Catalog、生成工程和阶段文档。

## 实际检查

- 最终 `MAC_BUILD_DIR=/tmp/ConnDock-DerivedData scripts/verify.sh` 已 exit 0：Swift strict 格式、473 个 key、本地化引用、Python 脚本测试、源码发布预检、Rust fmt/clippy/test、UniFFI 重建/Swift 类型检查、XCFramework 重建、两平台 Local 构建、arm64 架构及本地包检查均通过。最终日志 `build/phase7/verify-final.log`；macOS **96 项（5 跳过）**、iOS **84 项（4 跳过）**，0 失败。Rust workspace 52 项通过、16 项 opt-in 网络测试忽略；忽略项不算通过。早期完整检查另见 `build/phase7/verify.log`。
- 分屏模型最初因缺少 API 编译失败，记录 `split-red.log`；实现后通过。远端协议回复切换焦点由新增回归测试实际复现（`reply-focus-red.log`），移除 send delegate 中的焦点更新后通过。
- 真实 NSWindow/NSHostingView 测试复现改变方向/取消分屏丢失 first responder；将恢复任务的 identity 扩展为选择和分屏布局后，分屏专项 **6 项全部通过**，`build/phase7/split-final.log`。
- macOS UI 两条真实流程通过：本地终端→分屏→切焦点→改变方向→取消→保留标签，以及 NSOpenPanel 选择临时配置→预览→保存→主机列表出现；共 3 项中 2 通过、1 平台条件跳过。`build/phase7/ui-r3.log`、`ui-r3.xcresult`。
- iPad Simulator 的分屏菜单、两个窗格的屏幕边界、焦点选择及取消分屏 **1 项通过**，`build/phase7/ipad-ui-final.log`；iPhone Simulator 导入入口和不显示分屏菜单 **1 项通过**，`build/phase7/iphone-ui.log`。iPad 初始 app.screenshot 存在裁切异常，XCUIScreen 的最终原始截图已查看，两个窗格完整，附件位于 `build/phase7/screenshots-ipad-final/`。
- UI 初始失败来自实际 AX 元素类型/继承标识与测试查询不符；按结果包原始 AX 树调整查询后通过。早期失败日志保留。截图为原始测试附件，macOS 部分被其它前台系统窗口遮挡，不将其视作完整无遮挡视觉验收。
- 独立只读审阅反馈的协议回复焦点问题已修正；审阅未代替主流程测试，也不构成独立安全认证。

## 限制与后续

本阶段没有物理 iPhone/iPad、最低系统、长连接/外接键盘、真实双 SSH 窗格网络与正式分发包专项验收。现有真实 CloudKit、新身份正式 MCP 沙盒和发行验收继续独立保留。SSH Config 未支持的连接语义不会静默降级；跳板机、Agent/MFA 等仍留待对应阶段。

下一阶段为 SSH 连接与认证增强，之后依次处理转发、SFTP、MCP 文件操作、可选凭据同步及 P2 管理功能。本阶段按用户后续指令提交并整合到本地 `main`，不包含远端推送或发布上传。
