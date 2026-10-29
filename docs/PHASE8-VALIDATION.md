# Phase 8：连接与认证增强

日期：2026-10-28 至 2026-10-29。按用户已授权的 P1/P2 分阶段实施，本阶段范围来自 [requirements.md](requirements.md) 与 [PHASE8-PLAN.md](PHASE8-PLAN.md)。其他平台客户端继续暂缓。

## 实现与边界

- Rust 区分交互终端与 transport-only。文件与服务模式认证后不请求 PTY/shell，可使用服务器允许的 SFTP、exec 和监控；UI 不发送终端输入。原终端连接保留默认行为。
- 跳板机选择一台已保存直连主机，通过该 SSH transport 的 direct-tcpip 连接最终目标。两端分别认证、确认/核对主机指纹，缺跳板配置或凭据时失败，不改走直连；目标拥有独占跳板会话，关闭、后台取消未完成认证和启动失败时均释放它。
- keyboard-interactive 支持独立认证和密码/密钥被部分接受后的 MFA。挑战带 session/request identity、确切 user@host:port 和服务器原始提示，隐藏输入使用 SecureField，逐轮回答；最多 8 个提示、16 轮，提示/回答字节有界。取消、关闭和后台清空待答请求，旧轮次、重复或数量不匹配的答案被拒绝。答案只用于当前连接，不写入持久化、同步或日志。
- macOS Agent 使用用户明确指定的 socket 和 SHA256 公钥指纹，只让该公钥签名，不读取私钥、不做 Agent forwarding；iOS 不提供 Agent 入口。应用提供容器内专用 socket 位置及可复制的手动设置命令，不替用户启动 Agent 或加载密钥。
- 保留 App Sandbox。Local 沙盒中已验证容器内专用 Agent；容器外系统 Agent 的 socket 在本机被操作系统拒绝，目录选择和 security-scoped bookmark 也不能保证解除 Unix socket 网络限制。此情形返回专门的访问被拒绝错误，不关闭沙盒或改试其他密钥。正式 Bundle 的发行签名可用性仍需单独验收。
- SwiftData V4 增加独立连接选项实体，V3 迁移不改主机身份或凭据引用。非机密连接选项通过现有 encrypted payload 的 schema 2 同步；Agent socket 与目录书签只保存在本机。缺失/自身/嵌套跳板被拒绝；未保存连接重新打开仍保留路由和模式。
- 已升级为 schema 2 的主机保持该版本。冲突在删除优先后选择较新 schema，再比较逻辑时钟，防止旧设备离线编辑把跳板/MFA 等语义清除。新版用户明确取消跳板仍写 schema 2，并能同步为直连；旧客户端需升级后编辑这些记录。V4 本地库不承诺由旧 App 直接读取；回退二进制前应保留当前库并使用升级前备份或独立数据目录，不把旧模型强行套用到 V4 库。
- MCP 使用独立 transport-only；经跳板时两端都需相应工具授权，授权撤销或任一主机配置/凭据 revision 变化取消请求。交互认证及 Agent 配置不供后台 MCP 自动连接。
- 新增 UI 文案全部进入 String Catalog，中英共 499 个 key。依赖版本不变；桥接生成物只由脚本重建。

## 修改文件

主要涉及 Rust `ssh-core/src/session.rs`、`apple-ffi/src/ssh.rs`；Swift `TerminalSession`、`WorkspaceState`、`NewHostSheet`、`HostLibrary`、`HostLibrary+Sync`、`SyncDocument` 和 MCP 执行/授权；新增 `HostConnectionOptions.swift`、`AgentSocketAccess.swift`、`InteractiveAuthentication.swift`。同时增加真实 SSH、迁移/同步/生命周期、MCP 和三端界面测试，补上 `TerminalFocus.swift`、`TerminalSplitTests.swift` 的实际窗口附着焦点回归，更新隔离测试脚本、macOS 目录书签 entitlement 与生成工程。完整范围以本阶段 Git 提交为准。

## 实际验证

- 初始 Rust/Swift 测试因缺少新增接口失败，记录 `build/phase8/core-red.log`、`swift-red.log`。回归另复现准备好的跳板未释放、目录 URL 末尾斜杠误拒绝，以及未保存连接丢失选项；修正后 AdvancedConnectionTests 7 项通过，见 `advanced-r2.log`。
- 独立只读审阅发现旧 schema 覆盖高级连接语义，新增两项同步测试实际失败：`sync-downgrade-red.log`。修正后 AdvancedConnectionTests 与 CloudSyncTests 合计 21 项通过：`sync-downgrade-green.log`。之后将 journal decode 保持抛错语义，最终统一检查再次覆盖。
- 隔离临时 OpenSSH（PermitTTY no）和独立临时 Agent 的真实核心测试最终 6 项通过，覆盖无 PTY 的 SFTP/exec/输入拒绝、跳板与最终目标指纹拒绝、精确 Agent 密钥、多轮 MFA/旧答案/重复/取消，错误回答和禁止交互，以及第 16 轮后的成功。`scripts/test-local-ssh.sh --connections`；记录 `local-connections.log`、`agent-ui-container.log`、`apple-transport-all.log`；16 轮回归先在 `mfa-last-round-red.log` 实际失败，修正后 `mfa-last-round-green.log` 为 6 项通过。此前一次 Linux Docker 核心检查 4 项通过，后续镜像/apt 环境不稳定，最终采用本机隔离 OpenSSH；未修改系统 sshd 或用户现有 Agent。
- 原交互终端真实 OpenSSH 回归 5 项通过，包含会话/键盘、流控、取消、交互命令与认证拒绝；`build/phase8/pty-regression.log`。
- `CONNDOCK_CONNECTIONS_APPLE=1 CONNDOCK_TEST_PLATFORM=all IOS_DEVICE='SSHClient iPhone 17' IPAD_DEVICE='SSHClient iPad Pro 11' MAC_BUILD_DIR=/tmp/ConnDock-DerivedData scripts/test-local-ssh.sh --connections` 成功。macOS、iPhone Simulator、iPad Simulator 各 1 项真实 transport/SFTP/exec/跳板经 UniFFI 到 Swift 的测试通过，原始日志 `build/phase8-{mac,iphone,ipad}-ssh.log`。
- macOS 容器内专用 Agent 完整 UI 连接 1 项通过，包含原生表单、目录选择、指纹确认和已连接文件模式；结果 `build/phase8-mac-ui-ssh-20261029-085812.xcresult`。最终命令为 `CONNDOCK_CONNECTIONS_APPLE=1 CONNDOCK_TEST_AGENT_IN_CONTAINER=1 CONNDOCK_TEST_METHOD=testAgentConnectionThroughForm CONNDOCK_TEST_PLATFORM=macos MAC_BUILD_DIR=/tmp/ConnDock-DerivedData scripts/test-local-ssh.sh --connections`，`build/phase8/agent-ui-final-r2.log` exit 0；同时再次通过 6 项核心真实测试。一次最终 UI 复跑因说明变长、开关超出 Mac 弹窗可视区而失败，测试改为先设置文件模式，再展开 Agent 配置，并断言值为 1；产品代码无额外改变。最终 Mac 原始截图已查看，已连接和 SFTP 列表可见，无系统窗口遮挡，位于 `build/phase8/agent-ui-final-attachments/`。先前外部 socket 的失败记录保留，明确定位到 socket connect 访问被拒绝，不计作已支持路径。
- 连接选项保存/重新编辑：macOS 1 项通过；iPhone 和 iPad 各 1 项通过，`build/phase8/options-iphone-final.log`、`options-ipad-r5.log`。移动端早期自动化失败来自首次 tap 只滚动 Form 行、全屏 swipe 将行滚出虚拟列表、iPad 坐标落到弹窗外以及滚动后首字段被虚拟化，按原始 AX 树改为在 Form 内短距离滚动和点击真实子开关，并在保存前实际断言开关已开启；没有为测试改变产品状态或绕开断言。最终 iPhone 深色、iPad 浅色原始截图均已查看，分别位于 `build/phase8/options-iphone-final-attachments/`、`options-ipad-r5-attachments/`。
- 最终 `MAC_BUILD_DIR=/tmp/ConnDock-DerivedData IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' scripts/verify.sh` exit 0，`build/phase8/verify-final2.log`：Swift strict 格式、499 个中英 key、10 项 Python 脚本测试、源码发布检查、Rust fmt/clippy 与 workspace **52 项通过、22 项 opt-in 忽略**、生成 Swift 类型检查、三个 arm64 slice、两端 Local 构建和实际 Mach-O/本地包检查均通过。macOS **108 项（跳过 6 项）**、iOS **94 项（跳过 5 项）**，0 失败；跳过项未计作通过，不代表发行签名或 Apple 已接受提交。

- 合并前补跑的 `verify-precommit.log` 曾出现既有 `cancellation_during_handshake_closes_the_socket` 失败 1 次；增强原断言输出实际 Ended，未放宽结果、socket 关闭或输入拒绝断言。随后单例 50 次和旧实现 suite 100 次未再复现。静态检查发现取消通知与 socket shutdown 返回可在同一轮 select 调度竞争，worker 现于发布结束结果前复查取消标志，保留取消优先语义。修正后 4 项生命周期测试连续 **100 轮通过**（`cancel-race-green.log`），真实 SSH **6 项再次通过**（`connections-delivery.log`），并经同一审阅者只读复审。
- `verify-delivery.log` 随后在 macOS 既有分屏焦点测试失败 1 次，10 次单项重复中再出现 1 次取消分屏丢焦点（`focus-repeat.log`）。新增“终端挂载前请求焦点、换标签后拒绝旧请求”的确定性窗口测试先失败（`attach-focus-red.log`）。原恢复只 yield 一次，未覆盖原生视图晚于 layout task 挂载；改由实际 window attachment 触发带选择/视图归属/弹窗检查的弱引用回调，保留立即恢复。分屏 7 项测试连续 10 轮 **70 次全部通过**（`focus-final.log`），该小范围修正再次只读复审通过。
- 本机 Git 凭据检查钩子将认证枚举的本地化键误判为凭据赋值；改为等价的显式 return 写法后原钩子通过，未设置跳过选项、关闭检查或修改全局钩子。

## 未验证项与后续

本阶段未进行物理 iPhone/iPad、最低系统、真实企业 PAM/MFA 服务商、硬件 Agent/智能卡、跨公网跳板和长时间断网恢复专项；MFA 的真实协议测试与 Swift 生命周期测试不能等同于真实服务商整条 UI 验收。新选项的真实双设备 CloudKit 上传/下载/冲突未在本阶段执行，早前空队列同步或 entitlement 检查不能代替这些场景。Local ad-hoc 沙盒结果也不能代替新正式 Bundle 的发行签名、MCP helper、TestFlight 和发布验收。

核心 `start_via` 可接收复用父会话，App 当前只传入独占父会话。未来复用核心到其它连接管理场景时，应补上跳板迟到 channel-open/超时的独立资源验收；当前产品路径通过关闭独占父会话回收。Agent 实际验收使用 Ed25519；RSA 当前选择 SHA512，未验证仅允许 rsa-sha2-256 的服务器兼容性，后续需协商算法并补专项。

独立只读代码审阅发现的同步降级和 16 轮 MFA 问题已修正并复审；未发现剩余合并阻断。该审阅不构成独立安全认证，不能替代运行验证。

下一授权阶段为 Phase 9：本地、远程、动态端口转发，随后推进 SFTP、MCP 文件操作、可选凭据同步与 P2 运维。当前阶段不包含远端 Git 推送或应用分发。
