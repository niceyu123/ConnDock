# Phase 1 实现与验收记录

> 历史范围说明（2026-10-27 更新）：macOS 已正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）。文内原有 Intel/四架构构建结果仅为历史记录，当前构建和发布范围以 `requirements.md` 与现行脚本为准。

日期：2026-10-27（Asia/Shanghai）。依据 `requirements.md` 和本次用户授权。**SSH 功能验收通过，按用户确认自动进入 Phase 2。** 补充 macOS 表单 UI 自动化受系统认证状态阻止，不能表述为全部 UI 自动化均通过。

## 1. 实际实现

- Rust 1.99.1 / Tokio 1.48.0 / russh 0.65.0 完成真实 TCP、握手、密码和 Ed25519 私钥认证、交互 PTY、原始字节输入输出、窗口 resize、主动断开和超时/错误/取消。
- UniFFI 0.32.2 暴露拥有生命周期的会话对象、稳定错误码与事件；协议版本为 2。SwiftTerm 1.19.0 的 AppKit/UIKit 原生视图绑定真实网络输出，支持 UTF-8、ANSI、键盘和触控辅助按键。
- 未知主机必须明确确认 SHA256 指纹；本机保存信任决定，已知密钥变化强制阻止连接。弹窗确认同时校验会话与指纹，旧弹窗不能批准另一台排队主机。
- 每标签独立会话/终端缓冲；关闭标签或取消会关闭传输。读写并发，有界队列与批量 UI 读取；网络任务完成后继续投递已收到的末尾输出和退出码。
- 中英 String Catalog 共 156 key；保留独立浅/深配色、三态外观和终端主题。新连接表单支持密码、OpenSSH Ed25519 文件导入及可选口令，本阶段连接凭据不保存。
- 未开发 SFTP、监控采集、iCloud 或 MCP。未接入面板继续显示明确空状态。

## 2. 安全与测试环境

本机系统 OpenSSH 10.3p1 在随机回环端口启动，仅当前测试账号及临时 Ed25519 公钥可访问；不改变系统远程登录、系统账号或 `~/.ssh`。指纹直接从生成的主机公钥取得。

用户提供的外部服务器使用普通账号验证密码。本机 `~/.ssh/known_hosts` 已有该地址/端口的 Ed25519 记录，以该指纹严格校验后才认证；没有首次无条件信任、没有跳过校验。没有使用 root，也没有修改远端认证配置。只运行测试所需的 Shell/PTY 命令。

密码通过关闭回显的运行时输入写入权限 0600 的临时文件，完成后已删除。三端测试的临时配置读取即删除，并按运行 UUID 清理 Xcode 迁移后的容器。已核查临时私钥和配置无残留。产品无凭据/终端日志或默认录制；真实终端截图仅放在忽略的 `build/`，不加入 Git。

## 3. 实际命令与结果

| 检查 | 实际结果 | 证据 |
|---|---|---|
| `scripts/verify.sh`（覆盖 MAC_BUILD_DIR、iPhone UDID） | exit 0；格式、翻译、Clippy、Rust、四架构库、两 App Target 构建与基础单元测试通过 | `build/phase1-verify-r11.log` |
| `cargo test --locked --workspace` | 9 项通过；6 项真实服务用例按设计需显式运行 | `build/phase1-rust-last.log` |
| `cargo clippy --locked --workspace --all-targets -- -D warnings` | exit 0 | `build/phase1-clippy-last.log` |
| `scripts/test-local-ssh.sh` | 5 组真实本机 OpenSSH 用例通过 | `build/phase1-openssh-complete.log` |
| 显式运行 `openssh_password_pty_and_wrong_password` | 外部服务器密码成功、错误密码拒绝、PTY/UTF-8/ANSI/resize/Ctrl+C 通过 | `build/phase1-remote-password.log` |
| 本机 Ed25519 → Rust → UniFFI → SwiftTerm | macOS、iPhone、iPad 各 1 项通过 | `build/phase1-{mac,iphone,ipad}-ssh-20261027-075309.xcresult` |
| 外部密码 → Rust → UniFFI → SwiftTerm | macOS、iPhone、iPad 各 1 项通过；未捕获外部服务器终端截图 | `build/phase1-{mac,iphone,ipad}-ssh-20261027-085553.xcresult` |
| macOS 基础测试 | 14 通过，1 按设计跳过（SSH 专项已单独运行） | `build/macOS-unit-20261027-075448.xcresult` |
| iPhone 基础测试 | 15 通过，1 按设计跳过 | `build/iOS-unit-20261027-075448.xcresult` |
| iPad 基础测试 | 15 通过，1 按设计跳过 | `build/phase1-ipad-unit-20261027-075539.xcresult` |
| iPhone / iPad 连接表单导航 | 各 1 项通过；空表单不能建立假连接 | `build/phase1-{iphone,ipad}-form-20261027-075730.xcresult` |
| macOS 补充表单 UI 自动化 | **未通过**：Runner 初始化被系统认证状态阻止，提示“认证已取消 / System authentication is running” | `build/phase1-mac-form-20261027-075539.xcresult` |

真实本机用例覆盖：有效/无效或未授权 Ed25519、未知主机确认/拒绝、主机指纹改变、交互 `pwd`/`ls -la`/`top`、UTF-8/ANSI、Ctrl+C、`stty size` 回读、正常退出/退出码/末尾输出、取消、重连、突然传输中断、满输出队列取消、4 MiB 双向流控。另有不依赖 SSH 服务的连接拒绝、握手超时、握手期间取消与对象释放测试。

三端原生测试还检查真实终端已附着在显示窗口、ANSI 红色单元格、iOS `insertText` 路径的 Ctrl+C、调整实际窗口后的服务端行列，以及连接中切换中英与深浅外观仍能输入输出。测试按 SwiftTerm 字形读取滚动缓冲，跳过双宽字符占位；尺寸回读使用明确标记，避免 Shell 提示符/回显设置造成误判。

## 4. 运行截图

六张 PNG 来自本机真实 SSH 会话和原生运行窗口，与 XCTest 原始附件逐字节一致。截图索引：`build/phase1-screenshots/README.md`，包括 macOS/iPhone/iPad 的简中深色与英文浅色。没有制作静态 SSH 输出或伪造服务器指标。

## 5. 修改与新增文件

- 约定与文档：`AGENTS.md`、`README.md`、`docs/ARCHITECTURE.md`、`docs/PHASE1-PLAN.md`、`docs/PHASE1-TESTING.md`、本记录。唯一任务书与原始导入文件未改。
- Rust：`rust-core/Cargo.toml`、`Cargo.lock`；`ssh-core/Cargo.toml`、`src/lib.rs`、`src/session.rs`、`tests/{policy,lifecycle,openssh}.rs`；`apple-ffi/Cargo.toml`、`src/lib.rs`、`src/ssh.rs`。
- Apple 核心：`Shared/Models/WorkspaceState.swift`、`Shared/Security/HostTrustStore.swift`、`Shared/Components/{WorkspaceRoot,MobileWorkspace}.swift`；`Features/Hosts/NewHostSheet.swift`；`Features/Terminal/{TerminalSession,NativeTerminalView,TerminalWorkspace}.swift`。
- 资源与工程：`Resources/Localizable.xcstrings`、`project.yml` 与生成工程、macOS `SSHClient.entitlements`、`SSHCoreBridge/BridgeProbe.swift`。新增出站网络与用户选中文件只读权限。
- 测试：`Tests/FoundationTests.swift`、`Tests/SSHTrustTests.swift`、`Tests/SSHIntegrationTests.swift`、`UITests/PhaseZeroUITests.swift`。
- 脚本：`verify.sh`、`export-screenshots.swift`、`test-local-ssh.sh`、`test-apple-ssh.sh`。UniFFI 生成物通过既有脚本重建，不手工编辑。

## 6. 限制与 Phase 2

- 真实物理 iPhone/iPad、外接键盘/中文 IME、最低系统版本与 Intel Mac 运行尚未验证；当前是 Apple Silicon macOS + 两台 iOS 27 模拟器。
- 私钥的真实正向验收使用未加密 Ed25519；加密文件选择器/口令交互尚需专门实测。MFA、SSH Agent、主机 CA 证书不在本阶段范围。
- Phase 0 记录的 iOS 模拟器系统级外观切换 UI 测试问题，本轮未声称修复。已验证应用内即时切换，以及原生 trait 驱动的 SwiftTerm 配色。
- macOS 的补充 UI Runner 系统认证阻断待环境允许后重跑；保持沙盒和权限，不通过扩大权限绕开。
- 按用户确认进入 Phase 2：SwiftData 主机/分组持久化、Keychain、保存/编辑连接表单、分组/搜索/收藏/最近、多会话切换与原生设备布局；仍不开发 Phase 3 以后的功能。
