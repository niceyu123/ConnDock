# Phase 3 实现与验收记录

> 历史范围说明（2026-10-27 更新）：macOS 已正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）。文内原有 Intel/四架构构建结果仅为历史记录，当前构建和发布范围以 `requirements.md` 与现行脚本为准。

日期：2026-10-27（Asia/Shanghai）。唯一需求为 `requirements.md`。本阶段实现 SFTP 与 Linux 监控，不包含 iCloud、MCP、远程编辑、断点续传或端口转发。

> Phase 3 实现与本机验收已完成。最后一轮三端专项和 `scripts/verify.sh` 均 exit 0；macOS 完整界面验收通过。真实服务测试与默认跳过用例分别计数，物理设备等限制见文末。当前停止在 Phase 3。

## 完成内容

- 在已认证、已验证主机身份的 SSH Handle 上打开独立 SFTP/监控 Channel，不重复保存凭据、不往用户交互 PTY 注入监控命令。
- 列目录、主目录/上级目录、中文与特殊文件名、创建目录、重命名、删除文件/空目录、上传、下载、进度、取消和失败重试。目录变化时拒绝陈旧操作，删除/替换有原生确认，不递归删除。
- 每块最多 64 KiB、最多 2 项并发、队列最多 50 项。Swift actor 读写本机授权文件，Rust 不接受本机路径。下载完成后由系统保存/导出窗口选择目的地。
- 上传写独占临时文件，确认完整字节数后提交。替换已有普通文件保留普通权限和 UID/GID，不恢复特殊权限位，不能保留时失败。提交期间显示“正在完成”，网络中断时明确提示结果不确定。
- Linux `/proc/stat`、`meminfo`、`net/dev`、`uptime` 和根文件系统 `df` 采集；CPU/网络需要两次采样，处理 guest 重复计数、接口变化与计数器重置。Swift Charts 展示真实历史，最多 120 点，默认 5 秒刷新，可暂停。
- 隐藏监控/离开前台停止采样，断开停止全部会话资源；隐藏 SFTP 停止浏览，用户已发起的传输继续。打开过程有显式 Rust 取消信号，目录句柄和迟到的 Channel 确认均有关闭保护。
- 新增 UI、错误与确认均具备简中/英文，String Catalog 共 254 项。移动工具 Sheet 单独绑定外观，打开期间切换语言和颜色立即更新。

## 实际结果

| 检查 | 结果 | 证据 |
|---|---|---|
| 统一验证脚本 | exit 0；Swift 格式、254 项双语、Rust fmt/Clippy/test、生成库、App 构建与基础测试 | `build/phase3-verify-final.log` |
| 四架构 XCFramework | macOS arm64/x86_64、iOS arm64、iOS Simulator arm64 均编译成功 | 同上；生成目录 `apple/Packages/SSHCoreBridge/Artifacts/SSHClientFFI.xcframework` |
| macOS / iOS 模拟器 App 构建 | 两项 `BUILD SUCCEEDED` | `build/macos-build.log`、`build/ios-build.log` |
| macOS 基础测试 | 27 通过，3 跳过，0 失败（共 30） | `build/macOS-unit-20261027-132643.xcresult` |
| iPhone 基础测试 | 27 通过，3 跳过，0 失败（共 30） | `build/iOS-unit-20261027-132643.xcresult` |
| Rust 常规全套 | 17 通过，10 个需真实服务的用例按设计忽略 | `build/phase3-rust-final.log` |
| Clippy | exit 0，`-D warnings` | `build/phase3-clippy-verified.log` |
| 本机 macOS 真实 SFTP/非 Linux/断网恢复 | 3 通过，2 GiB 用例另行执行 | `build/phase3-overwrite-permissions-green.log` |
| Linux 真实专项 | 4 通过，0 跳过 | `build/phase3-linux-full-final.log` |
| 2 GiB 上传 + 2 GiB 下载 | 全部字节及流式累计校验一致；大文件部分 425.90 秒 | 同上 |
| 大文件专项计时命令内存 | `time -l` 报告最大常驻 29,327,360 bytes（约 28.0 MiB） | 同上；这是 Rust 专项命令，不是三端 UI 内存数据 |
| CPU/网络独立基准 | 同窗口计数比较通过；另核对内存总量、磁盘和 uptime | 同上；方法与容差见 `PHASE3-TESTING.md` |
| 已有 OpenSSH/PTY 回归 | 5 组通过，含双向流控、top、信任、认证失败和取消 | `build/phase3-ssh-regression-r1.log` |
| macOS 原生 Phase 3 | 1 通过，0 跳过 | `build/phase3-mac-ssh-20261027-131816.xcresult` |
| iPhone 原生 Phase 3 | 1 通过，0 跳过，含已呈现 Sheet 外观断言 | `build/phase3-iphone-ssh-20261027-131816.xcresult` |
| iPad 原生 Phase 3 | 1 通过，0 跳过，含已呈现 Sheet 外观断言 | `build/phase3-ipad-ssh-20261027-131816.xcresult` |
| macOS 完整真实 UI | 1 通过，0 跳过；169.09 秒 | `build/phase3-mac-ui-ssh-20261027-131443.xcresult`、`build/phase3-macos-ui-r7.log` |

基础测试中跳过的 3 项为需要一次性配置的真实 SSH 集成用例，不计入通过数。Phase 3 的真实三端用例已由专用脚本单独执行；Phase 1/2 的 Apple 专项仍分别引用既有阶段验收。此次另执行了 Rust 已有 OpenSSH/PTY 的 5 组回归。

最终执行命令（依次运行，不并发占用 Apple 构建/测试）：

```bash
scripts/test-linux-services.sh
scripts/test-local-ssh.sh
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
scripts/test-linux-services.sh --apple-only
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
SSHCLIENT_TEST_PLATFORM=macos \
SSHCLIENT_TEST_METHOD=testRealSSHConnectionFormAndScreenshots \
scripts/test-linux-services.sh --apple-only
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' \
scripts/verify.sh
```

上述命令展示复现顺序，实际各次运行的时间、顺序和失败后的重试以日志及 `.xcresult` 为准。最终三端专项与统一验证的串行组合返回 `native=0 verify=0`。

三端原生专项使用约 1 MiB 文件，实际通过产品模型、UniFFI 与真实 Linux OpenSSH 上传/下载、比较本机落盘字节、目录操作、缺失本机文件的失败与修复后重试、立即取消上传、监控暂停/恢复/隐藏、语言与外观即时切换，最后继续使用原 PTY 并主动断开。脚本干净退出，完整记录为 `build/phase3-native-final-r2.log`。大文件内存结果没有推广为 SwiftUI/UniFFI 三端峰值验收。

macOS 完整 UI 通过真实连接表单、系统私钥选择器、指纹确认和 SwiftTerm 键盘进入工作区；实际完成新建目录、系统上传选择器、下载、系统保存窗口导出、本机导出字节比较、删除确认和中英浅深切换。系统窗口交互已经单独通过，未以模型调用代替。

## 运行截图与临时资源

`build/phase3-screenshots/README.md` 为完整索引，共 15 张原始运行 PNG：macOS 7 张、iPhone 4 张、iPad 4 张。主要工作区为 `macos-phase3-zh-light-ssh-ui.png` 和 `macos-phase3-en-dark-ssh-ui.png`；移动端分别包含中英文、浅深色的文件和监控 Sheet。

通过 `scripts/export-screenshots.swift` 从上述成功 `.xcresult` 导出后，逐张比较源附件与交付文件的 SHA-256，15 张全部一致。摘要清单为 `build/phase3-screenshots/SHA256SUMS.txt`，检查记录为 `build/phase3-artifacts-check.log`。图片未合成、改色、反转或重绘，也不纳入 Git。

本轮隔离容器已删除；已检查本项目 fixture 的登录/主机私钥、macOS 及两台模拟器的一次性配置均无残留。只清理脚本创建的资源，不修改系统远程登录、用户 SSH 目录或其他容器。

## 排查与回归

- Linux 解析与 SFTP 名称/偏移边界先失败后通过：`phase3-monitor-red.log`、`phase3-sftp-policy-red.log` 与后续 Rust 结果。
- 目录句柄 Drop 先复现未发送 CLOSE，修正后通过：`phase3-directory-drop-{red,green}.log`。
- 覆盖 0755 文件最初变成 0600，真实回归复现后修正；0755、0640 均通过：`phase3-overwrite-permissions-{red,green}.log`。
- 异常断开最初显示取消，已用 `phase3-transfer-state-red.xcresult` 复现，修改为明确失败；最终 macOS/iPhone 基础测试均通过该回归，覆盖正常取消、已完成和提交结果不确定四种状态。
- 移动 Sheet 初版截图发现外观滞后，原生 trait 断言失败证据为 `phase3-iphone-ssh-20261027-124454.xcresult`，修正后上述三端结果通过。旧截图已由正确颜色的原始附件替换。
- macOS 早期 UI 测试有系统窗口打断及事件合成超时；正常辅助功能树另确认容器 identifier 覆盖子控件，已移除外层覆盖。另将删除按钮查询限定在窗口内，排除 Touch Bar 的同名镜像。最终完整 UI 流程及系统保存窗口已通过，早期失败结果保留供追溯。
- Docker Desktop 共享文件系统的跨主机 chmod 缓存曾影响权限预置条件；Linux 回归改为在同一服务器环境设置权限并通过 SFTP 读回，未降低权限保留断言。
- 单次正在运行的脚本被编辑曾产生尾部解析提示；后续验证使用固定保存后的脚本，Shell 语法单独复核。产品测试结果与工具脚本问题分别记录。

## 文件范围

| 范围 | 新增文件 | 修改文件 |
|---|---|---|
| Rust 核心 | `rust-core/crates/ssh-core/src/remote.rs`、`sftp.rs`、`monitor.rs`；`rust-core/crates/ssh-core/tests/remote_services.rs` | `rust-core/Cargo.toml`、`Cargo.lock`；`rust-core/crates/ssh-core/Cargo.toml`、`src/lib.rs`、`src/session.rs` |
| UniFFI | `rust-core/crates/apple-ffi/src/remote.rs` | `rust-core/crates/apple-ffi/src/lib.rs`、`src/ssh.rs`；生成物由脚本重建 |
| Apple 产品模型 | `apple/Features/SFTP/RemoteFilesModel.swift`、`TransferDiskFile.swift`、`SaveDownloadedFile.swift`；`apple/Features/Monitoring/ServerMonitorModel.swift` | `apple/Features/Terminal/TerminalSession.swift` |
| Apple 界面与权限 | — | `apple/Features/SFTP/FilesPanel.swift`、`apple/Features/Monitoring/MonitorPanel.swift`、`apple/Shared/Components/WorkspaceRoot.swift`、`MobileWorkspace.swift`、`apple/Shared/Models/WorkspaceState.swift`、`apple/Apps/macOS/SSHClient.entitlements`、`apple/Resources/Localizable.xcstrings` |
| Apple 验证 | `apple/Tests/RemoteServicesTests.swift` | `apple/Tests/SSHIntegrationTests.swift`、`apple/UITests/PhaseZeroUITests.swift` |
| 验证工具 | `scripts/test-linux-services.sh` | `scripts/test-local-ssh.sh`、`scripts/test-apple-ssh.sh`、`scripts/export-screenshots.swift` |
| 文档 | `docs/PHASE3-PLAN.md`、`PHASE3-TESTING.md`、`PHASE3-REVIEW.md`、`PHASE3-VALIDATION.md` | `AGENTS.md`、`README.md`、`docs/ARCHITECTURE.md` |

所有 UniFFI Swift/C/二进制生成物由脚本重建，未手改。既有 Artwork、用户图标、Phase 1/2 成果保留。仓库仍未首次 Git 提交，没有提交或推送。

## 限制与后续

- 物理 iPhone/iPad、最低系统、Intel Mac 运行与正式签名未验证。iOS/iPadOS 系统文档导出的真实设备权限仍需专门验收。
- 本轮使用隔离的真实 OpenSSH 服务，没有在用户外部服务器执行 Phase 3 写入验收。
- 不递归删除目录，不支持断点续传、远程编辑、高级 ACL/xattr 保留；这些不冒充已实现。
- 取消时网络仍有效会尝试删除远端临时文件；真实断网可能残留 `.sshclient-*.part`。提交结果不确定时先刷新确认，不能承诺跨网络事务回滚。
- 下载临时副本位于 App 私有缓存；正常清除任务释放副本，突然退出后的缓存由系统管理。
- Linux 指标对应内核、非回环网络接口与根文件系统；不是 cgroup 配额或全部磁盘挂载点监控。
- 完成本阶段后停止，Phase 4 的 iCloud 同步需要新指令。
