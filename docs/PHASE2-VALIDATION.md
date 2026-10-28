# Phase 2 实现与验证记录

> 历史范围说明（2026-10-27 更新）：macOS 已正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）。文内原有 Intel/四架构构建结果仅为历史记录，当前构建和发布范围以 `requirements.md` 与现行脚本为准。

日期：2026-10-27（Asia/Shanghai）。唯一需求为 `requirements.md`。Phase 1 真实 SSH 功能验收后，按用户确认自动推进本阶段。

**本阶段功能与本机验收已完成：构建、三端存储/Keychain/真实多标签 SSH 和移动端界面持久化验证通过；macOS 补充验收也已通过，补齐真实浅色终端截图。修正与原始证据见 `PHASE2-MACOS-ACCEPTANCE.md`。当前停在 Phase 2，等待新的 Phase 3 指令。物理设备、最低系统及正式签名仍未验收。**

## 1. 完成内容与设计

- SwiftData 使用版本化 Schema V1，保存主机、分组、收藏、备注、最近成功连接、稳定 UUID、编辑版本和删除标记。关闭自动 CloudKit 镜像，完全本机工作。
- 密码、Ed25519 私钥和口令由独立 Keychain actor 保存。配置库只保存不透明引用；默认不记住凭据，不同步、不回退到明文。macOS 使用系统登录 Keychain，iOS 使用 WhenUnlockedThisDeviceOnly。普通保存允许不提供凭据。
- 新建/编辑表单支持仅保存、保存并连接、一次性连接、认证选择、分组、收藏和备注。更换主机、端口、账号或认证方式不静默复用旧秘密；旧版本表单不能覆盖新配置。
- 先写新 Keychain 引用，再提交数据库；写入失败不提交主机。替换/删除旧凭据的系统调用失败时显示提示，保留仅含引用的清理重试队列。数据库保存成功与随后的 UI 刷新失败分别处理，避免误删已提交引用。
- macOS/iPad 侧栏与 iPhone 主机列表展示真实配置，支持搜索、收藏、最近、分组、编辑/删除、连接测试和新标签打开。只有真实成功建立的 Session 才显示已连接，连接测试实际认证 PTY 后自动断开。
- Host、标签和 SSH Session 的 UUID 分离；每次认证使用固定目标快照。切换标签保留独立 SwiftTerm 缓冲。删除配置不强制中断活动终端，关闭标签才关闭相应会话。
- 终端使用系统等宽字体，提供 10–24 的本机字号设置与跟随应用/独立浅深主题；字号即时作用于原生终端并触发 PTY resize。中英、三态应用外观保留即时切换和持久保存。
- 右侧 Inspector 展示活动会话的真实地址、账号和连接状态；资源指标与底部 SFTP 仍是明确空态。没有实现 SFTP、监控采集、iCloud、MCP。
- macOS 当前单一主窗口加独立设置窗口；iPad 支持尺寸变化但未启用多个 Scene，避免同一原生终端被多个窗口同时持有。多窗口工作区不是本阶段已实现能力。
- String Catalog 共 **195 个 key**，全部具有简体中文和英文。新增界面复用已有原生组件与中性纯白/近黑配色，没有添加外部依赖。

## 2. 实际命令与结果

最终基础验证命令：

```bash
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' \
scripts/verify.sh
```

| 检查 | 结果 | 证据 |
|---|---|---|
| 最终 `scripts/verify.sh` | **exit 0**：格式、翻译、Clippy、Rust、四架构 XCFramework、macOS/iOS 两 App 构建、两端基础测试通过 | `build/phase2-macos-acceptance-verify.log` |
| `cargo test --locked --workspace` | 9 通过；6 个真实服务用例按设计默认忽略，专项另行执行 | 同上 |
| `cargo clippy --locked --workspace --all-targets -- -D warnings` | exit 0 | 同上 |
| macOS 基础测试 | 22 通过，2 按设计跳过，0 失败；新增终端辅助功能输入区回归 | `build/macOS-unit-20261027-110000.xcresult` |
| iPhone 基础测试 | 22 通过，2 按设计跳过，0 失败 | `build/iOS-unit-20261027-110000.xcresult` |
| iPad 基础测试 | 22 通过，2 按设计跳过，0 失败 | `build/phase2-ipad-unit-final.xcresult` |
| 本机真实 OpenSSH Rust 集成 | 5 组均通过：生命周期/信任/PTY、异常中断、4 MiB 双向流控、top、拒绝未授权认证 | `build/phase2-local-openssh-final.log` |
| SwiftData → 真实 Keychain → Rust/UniFFI → 双 SSH Session | macOS、iPhone、iPad 各 1 通过，0 跳过 | `build/phase2-{mac,iphone,ipad}-ssh-20261027-100319.xcresult` |
| iPhone 界面保存/重启/语言与外观 | 1 通过，0 跳过 | `build/phase2-iphone-persistence-r1.xcresult` |
| iPad 界面保存/重启/语言与外观 | 1 通过，0 跳过 | `build/phase2-ipad-persistence-r1.xcresult` |
| macOS 常规 UI 全套 | **6 通过，0 失败**，含表单、保存/重启、中英与三态外观、布局与独立终端主题 | `build/phase2-macos-ui-acceptance-final.xcresult` |
| macOS 真实 SSH 完整 UI | **1 通过，0 跳过**，含导入私钥、核对指纹、键盘输入、远端标记、浅深切换与主动断开 | `build/phase2-mac-ui-ssh-20261027-105734.xcresult` |
| 翻译与格式复核 | 195 key 中英完整；Swift 格式、Shell 语法通过 | `scripts/check-localizations.swift`、`swift-format lint --strict`、`bash -n` |

基础测试中跳过的 2 项是需要一次性配置的原生 SSH 专项；Phase 1 基础链路已在上一阶段实测，本阶段保存凭据/多标签专项在独立配置下实际执行，不把 skip 算作通过。

存储测试覆盖磁盘重开、主机/分组操作、搜索/收藏/最近、普通数据库无测试密码、凭据写失败不提交、身份变化撤销旧引用、旧版本编辑冲突、分组名称冲突，以及凭据删除失败后的重试。系统 Keychain 测试在三端实际执行新增、读取、删除，没有用测试内存适配器代替正向验收。

真实原生专项从临时 Keychain 取 Ed25519 材料建立两个 SSH PTY，分别输入标记和中文/Emoji/ANSI 命令，确认输出隔离、标签切换保留会话、已活动主机复用标签、连接测试真实成功后断开且不写最近记录、字号变化实际更新终端尺寸，以及语言/外观变化后继续输入输出。删除配置后原 Session 仍在，关闭其中一标签不影响另一会话。

Phase 1 已在用户提供的外部真实服务器用普通账号通过密码成功/错误密码验收，三端原生密码链路也已通过，详见 `PHASE1-VALIDATION.md`。本阶段没有重新读取用户密码、没有使用 root 或修改远端认证配置；新增保存凭据的真实 SSH 专项使用本机临时 Ed25519。正式外部服务的“保存密码后重启自动连接”尚未单独执行。

## 3. 排查、修正与未验证项

- 早期 iOS 测试关闭代码签名，系统 Keychain 返回 `-34018`。保留模拟器 ad-hoc 签名后真实读写/删除通过，已修正两个验证脚本；没有填写虚构 Team 或降低存储安全性。
- 本机 OpenSSH 测试最初受用户交互 Shell 启动时序影响。临时服务现在固定系统 Bash、UTF-8 locale 和真实 PS1，Rust 在收到实际提示符后才输入命令；不更改用户 Shell 或 `~/.ssh`。5 组回归已全部通过。
- iPhone 字号断言最初在切回标签、原生视图尚未重新附着时运行；改为等待真实附着和字体变化后验证，三端专项通过。
- 早期 macOS 表单测试 `r1`、`r3` 快照异常，`r2` 系统截图失败。补充排查取得正常辅助功能树后，确认连接按钮确实未呈现：macOS 的 `.confirmationAction` 分组只显示保存。改成明确的原生底部操作行后，保留原断言，专项 2 项和最终常规 6 项均通过。早期失败保留为历史证据，不代表当前结果。
- macOS SwiftTerm 默认未暴露原生辅助功能输入区；先用回归测试复现，再加入 textArea 角色与连接时可用状态，不公开原始终端 AX value。随后通过真实鼠标/键盘操作 SSH 终端，验证远程 Shell 实际收到命令。
- macOS SwiftTerm 离屏浅色截图仍不能正确包含终端图层；本次改为成功连接后的实际窗口 XCTest 截图，已补齐白底中文浅色与近黑底英文深色运行图。测试使用原生拖动将窗口放入主屏，避免副屏系统截图失败；关闭自动测试录屏，只保留显式截图。未反色、重绘或合成终端内容。
- 物理 iPhone/iPad、最低系统版本、Intel Mac 运行、正式签名的 Keychain 身份、外接键盘/中文 IME、加密私钥文件选择器与口令交互仍待专门验收。Phase 0 的模拟器系统级外观 UI 自动化问题未在本阶段声称修复。

当前环境是 Apple Silicon macOS 27.0、Xcode 27.1，iPhone 17 与 iPad Pro 模拟器。最低部署版本仍为 macOS 14 / iOS 17；最低版本和真机未运行。macOS ad-hoc 重建后系统可能再次要求 Keychain 授权。

## 4. 运行截图与秘密清理

截图索引为 `build/phase2-screenshots/README.md`。共 27 张原始 XCTest PNG：原有 17 张三端验收图，加 macOS 常规表单/分组/主机列表 6 张，以及本次真实 SSH 浅深界面、私钥导入完成表单、指纹确认 4 张。导出文件与对应 XCTest 附件逐字节一致，保存在忽略的 `build/`，不加入 Git。

临时主机密钥、登录密钥、未授权登录密钥和一次性配置均已核查无残留；本次测试服务退出时停止。真实 Keychain 专项结束时检查临时引用已删除。SwiftData 可能在异步作用域结束后继续持有 SQLite 句柄，因此测试不立即 unlink 仍被打开的文件；无秘密的独立测试数据库留给系统临时目录清理。

## 5. 新增与修改文件

以下为本阶段功能文件清单；整个仓库尚无首次 Git 提交，当前 Git 显示为 untracked，不能用工作区状态冒充按阶段的提交差异。没有自动提交或推送，用户已有 Artwork/图标工作保留。

新增：

- `apple/Shared/Models/HostModels.swift`
- `apple/Shared/Storage/HostLibrary.swift`
- `apple/Shared/Security/KeychainCredentialStorage.swift`
- `apple/Features/Hosts/HostGroupSheet.swift`
- `apple/Features/Hosts/SavedHostList.swift`
- `apple/Tests/HostPersistenceTests.swift`
- `apple/Tests/KeychainTests.swift`
- `docs/PHASE2-PLAN.md`
- `docs/PHASE2-TESTING.md`
- `docs/PHASE2-VALIDATION.md`
- `docs/PHASE2-MACOS-ACCEPTANCE.md`

修改：

- `AGENTS.md`、`README.md`、`docs/ARCHITECTURE.md`、`docs/PHASE1-TESTING.md`、`docs/PHASE1-VALIDATION.md`（固定历史证据路径，避免后续日志覆盖）
- `apple/Shared/Appearance/AppPreferences.swift`
- `apple/Shared/Models/WorkspaceState.swift`
- `apple/Shared/Components/WorkspaceRoot.swift`、`MobileWorkspace.swift`
- `apple/Features/Hosts/NewHostSheet.swift`
- `apple/Features/Terminal/TerminalSession.swift`、`NativeTerminalView.swift`、`TerminalWorkspace.swift`
- `apple/Features/Settings/SettingsScreen.swift`
- `apple/Features/Monitoring/MonitorPanel.swift`（只显示已有本机配置/会话信息，未实现监控）
- `apple/Apps/macOS/SSHClientApp.swift`
- `apple/project.yml` 与重新生成的工程/Info.plist
- `apple/Resources/Localizable.xcstrings`
- `apple/Tests/FoundationTests.swift`、`SSHTrustTests.swift`、`SSHIntegrationTests.swift`
- `apple/UITests/PhaseZeroUITests.swift`
- `rust-core/crates/ssh-core/tests/openssh.rs`（仅真实服务测试的 Shell 就绪等待与诊断，无 SSH 产品逻辑改动）
- `scripts/verify.sh`、`test-local-ssh.sh`、`test-apple-ssh.sh`、`export-screenshots.swift`

## 6. 后续建议

macOS 完整表单自动化与浅色运行截图已补齐，当前等待界面设计确认和新的 Phase 3 指令。Phase 3 建议实现 russh-sftp 基本文件操作、分块传输、进度/取消/断网失败，以及 Linux 只读监控采集和真实图表；物理设备/正式签名等发布检查另行完成。不得在当前交付中声称这些后续能力已经实现。
