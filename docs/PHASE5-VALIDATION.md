# Phase 5 — macOS AI/MCP 本机验证记录

日期：2026-10-27。依据唯一任务书 `requirements.md` 第 10/14 节，按用户指令进入 Phase 5。

**状态：Phase 5 功能实现及 Local 本机链路验收完成；正式 Team 签名/App Group 沙盒、App Store 与真实 systemd 成功查询尚未完成。** 真实 CloudKit 的 Phase 4 遗留验收继续独立保留。不自动进入 Phase 6。

## 完成内容

- 官方 Rust rmcp 3.8.0 stdio helper，以独立签名 wrapper 嵌入 macOS App，仅 arm64；iOS/iPadOS 不嵌入 helper。
- 六个 MCP Tools：list_hosts、get_host_info、get_server_metrics、get_service_status、sftp_list、ssh_exec。仅接受稳定 Host UUID，不允许替代地址或传入认证材料。
- 主 App 强制默认关闭、主机/工具白名单、目录/服务范围、命令单次精确审批、立即撤销、并发/期限/输出限制及本机脱敏审计。
- Unix socket 私有目录/权限、内核 audit token、真实进程路径、双向代码签名与 designated requirement 校验；不信任客户端自述名称，无 HTTP。
- 主 App 使用既有 Keychain、主机信任和独立 SSH 会话。未知/变化指纹拒绝；自动化凭据查询禁止认证弹框。终端会话不被注入命令。
- 中英 String Catalog、原生浅深色设置、安装命令复制、本地真实 helper 自检、审批和调用历史。

## 实际命令与结果

| 命令/检查 | 结果 |
|---|---|
| `MAC_BUILD_DIR=/tmp/SSHClient-Phase5-DerivedData IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' scripts/verify.sh` | exit 0，完整通过；日志 `build/phase5-verify-final.log` |
| Rust workspace fmt / clippy `-D warnings` / test | 50 项通过、14 项 opt-in SSH 测试忽略、0 失败；忽略项不算通过 |
| `apple-ffi/tests/check-swift-bindings.sh` | 真实生成 Swift，三个 Phase 5 API/结果字段 Swift 6 typecheck 通过；已纳入 verify |
| macOS Local build + 单元测试 | 构建通过；63 项中 59 通过、4 跳过、0 失败；`build/macos-unit.log` |
| iOS Simulator Local build + 单元测试 | 构建通过；53 项中 50 通过、3 跳过、0 失败；`build/ios-unit.log` |
| `scripts/test-linux-services.sh --quick` | 最终 7/7 真实 Linux/OpenSSH 专项通过；2 GiB 案例按 quick 过滤，未重复大文件验收；`build/phase5-linux-final-r3.log` |
| `MAC_BUILD_DIR=/tmp/SSHClient-Phase5-DerivedData scripts/test-mcp.sh --codex` | exit 0；真实 Codex CLI + Local helper + Mac App + Linux SSH 链路通过；`build/phase5-codex-integration.log` |
| Codex CLI 0.164.0 实际 tools/call | `list_hosts` 和 `get_server_metrics` 均 completed，无错误，真实 `memory_total=8217600000`；`build/phase5-codex.log` |
| MCP 真实远程专项 | 授权主机可见、未知 UUID 拒绝、真实指标、目录、准确批准的 stdout/stderr/exit_code=7、拒绝 touch 后目标文件不存在、禁用后拒绝；最终结果 `build/phase5-mac-ssh-20261027-182400.xcresult` |
| Mac MCP 设置 UI 专项 | 1/1 通过：默认关闭、启用说明、本地签名 helper 自检、中英/浅深色、关闭后重启保持；`build/phase5-mcp-ui-20261027-183055.xcresult` |
| `xcrun swift scripts/check-cloudkit.swift` | 六个平台/配置组合通过；`build/phase5-config-green.log` |
| String Catalog | 370 个 key，每项 zh-Hans/en 完整，源码引用有效 |
| Mach-O / XCFramework | 两 App、helper、三个 XCFramework slices 均仅 arm64；verify 与 embed 脚本实际检查 |
| `codesign --verify --deep --strict` Local App | exit 0；helper 为 ad-hoc，不能据此认定正式签名/沙盒通过 |
| 正式 Debug build（默认签名、不允许自动创建远端配置） | 实际失败：Xcode 找不到 `com.ruohai.termall` 的 Mac App Development provisioning profile；`build/phase5-formal-build.log` |

macOS 单元测试的 4 个跳过项为需专用真实服务器配置的 SSH 集成；MCP 专项已通过单独安装的一次性隔离配置真实运行。iOS 不运行 Mac MCP 专项。完整证据不能由上述跳过计数代替。

Codex 使用临时 `-c` 参数、`--ignore-user-config` 与 `--ephemeral`，没有执行 `codex mcp add` 或修改全局配置。测试只授权隔离 Linux fixture；秘密配置由既有脚本一次性安装和消费，退出清理 fixture 私钥和容器。

## 失败定位与修复

- 新策略/服务测试在缺失类型和 API 时先失败（`phase5-policy-red.log`），实现后通过。最终统一测试包含 4 个 MCPPolicy 和 6 个 MCPService 用例，覆盖拒绝、准确一次性批准、陈旧批准、主机改动、撤销、锁定、取消和并发上限。
- `RemoteFiles.list_authorized_directory` 最初放在普通 Rust impl 中导致 Swift 方法缺失；移到 UniFFI 导出 impl 后，独立真实绑定检查红→绿，再按脚本重建所有平台二进制和绑定。
- 自动化凭据路径测试先报缺少 `allowsUserInteraction`，随后实现禁止弹框的读取。具体 actor 方法明确 async，避免直接调用时选择默认 fail-closed 协议重载。最终 macOS/iOS Keychain 真实 round trip 及专用路由测试均通过。
- 独立审阅发现允许根 symlink 更换会扩大范围；已要求根为 literal canonical path。Docker bind mount 的宿主修改存在发布延迟，最终真实测试先通过独立 SFTP 观察到 symlink，再要求受限调用拒绝，7 项最终通过。
- 测试客户端最初使用 Foundation `read(upToCount:)` 等满缓冲导致 stdio 卡住；采样定位后改为有期限的 POSIX poll/read，并关闭父进程不用的 pipe 端。失败结果保留，不计成功。
- UI 测试首次把原生 Switch 当 CheckBox、把数字 AX value 当 String，以及把 Touch Bar 与 Sheet 同名按钮混为一项；按实际 AX 附件修正查询后 1/1 完整通过。没有为通过 UI 测试修改产品授权逻辑。
- 原 CloudKit 源配置检查拒绝 macOS network.server；按 Phase 5 UDS 范围更新，同时继续拒绝 iOS MCP group/listener。六组配置最终通过。

## 真实截图

两张来自成功 UI 结果包原始附件，保存在忽略的 `build/phase5-screenshots/`：

- `57FEFAAE-C8A2-4D6E-A770-258594A3F985.png`：中文浅色，真实 helper 自检成功。
- `76E202DE-C82B-4F65-A9AA-405D5A87783A.png`：英文深色，自检状态保持。

未重绘、改色或拼接；已实际打开检查。截图为 Local 空主机状态，不表示正式 Team 沙盒或云端验收。

## 签名/沙盒依据与尚未验证项

1. 一次性实际 probe 证明：外部非沙盒客户端不能使用 inherit helper 方案；独立 sandbox helper 的 network.client 不能直接访问主 App 容器 UDS。正式实现采用只存 IPC 的 macOS 专用 Team App Group 和 helper wrapper；Local 诊断 helper 无自身 sandbox entitlement，主 App 仍沙盒化。证据 `build/phase5-sandbox-probe/RESULTS.md`。
2. 本机开发证书确属于 Team `86HC8YA388`。探针私钥取用未完成；实际正式 App 构建进一步明确缺少 `com.ruohai.termall` 描述文件。需要在 Xcode 完成签名/对应 App Group 能力和 profile，随后验证 Debug/Release、Archive/Export、真实 group IPC、helper 沙盒与 MAS 分发。没有改 TCC、Keychain ACL 或自动创建远端开发配置。
3. systemd 服务状态成功数据有解析单元测试，真实 Linux fixture 验证的是不运行 systemd 时返回 `UNSUPPORTED`；真实 systemd 成功查询未验证。
4. 锁定状态的策略和撤销有自动测试；本轮没有锁定用户 Mac，快速用户切换、屏幕共享、最低 macOS 和物理设备尚未专项验收。
5. 关闭 SSH channel 不保证远端命令被杀；SFTPv3 不提供原子 openat/no-follow，不能承诺抵御恶意服务器或极端并发路径置换。命令/路径/输出都不写审计，命令只保存 SHA-256。
6. MCP 独立连接沿用既有 PTY/shell 建立过程；禁止 PTY/仅 SFTP 的受限账号尚不支持。没有为本阶段重构稳定会话生命周期。
7. 完整独立最终审阅受工具账户额度限制中断；已返回的重要问题由主实现者复现、修复并回归，过程见 `PHASE5-REVIEW.md`。不声称独立安全认证。

## 文件范围与交付

新增 `apple/Features/AIIntegration/` 策略、IPC、执行器、审批和设置；`rust-core/crates/mcp-server/`、`ssh-core/src/exec.rs`；MCP 测试、FFI 出口检查、helper 嵌入/签名及两类 MCP 验证脚本；本阶段计划、配置、复核与本记录。

修改会话远程 API/FFI、SFTP 授权边界、Mac 专属工程配置和 entitlements、WorkspaceState/Root/Settings 接线、Keychain 非交互读取、String Catalog、统一验证/隔离测试脚本及 README/架构/AGENTS 状态。iOS 无 helper、MCP 页面或 App Group；已有 iCloud、凭据同步与后续功能范围未扩大。

仓库仍无首次 Git 提交，既有文件保持未跟踪；本次未提交、未推送。下一步是补正式签名和沙盒验收，不自动开发 Phase 6。
