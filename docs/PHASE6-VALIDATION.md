# Phase 6 — 安全、稳定性与发布准备验证

日期：2026-10-27。开发名：SSHClient，显示名：TermAll。阶段验证基线版本：0.1.0 (1)；TestFlight 内部测试版本：iOS 0.1.0 (2)、macOS 0.1.0 (3)。工作目录：`/Users/yj/Documents/Code/App/ShellDock`。

**本阶段实现与本机验收已完成，完整发行验收尚未完成。** 按用户后续授权，已通过 Xcode Organizer 的 TestFlight Internal Only 上传 iOS `0.1.0 (2)` 与原生 macOS `0.1.0 (3)`；两平台构建均显示“正在测试”，均关联现有内部组 `TermAll 内测`，测试员仍只有用户自己的 Admin 账号 1 名。已登记当前 Mac，取得匹配的 macOS 开发及 Store profile，并从 TestFlight 安装、打开原生 macOS 构建，实际包为 `MacOSX / arm64`，严格签名检查通过。用户确认的标准加密算法类别及不在法国分发答案已用于两平台问卷；macOS 问卷实际点击保存后构建进入可测试状态，不据此推断法律豁免。真实 CloudKit、正式 MCP helper 沙盒/IPC、物理 iPhone/iPad 与完整发行准备继续保留待办。未提交/推送 Git，保留全部既有未跟踪工作。

## 完成内容与关键文件

- `apple/Features/Terminal/TerminalSession.swift`：后台暂停、前台有界连通性检查、可取消恢复 operation、生命周期代次、关闭后迟到事件保护；失败走手动重连。
- `apple/Shared/Models/WorkspaceState.swift`、`apple/Apps/iOS/SSHClientApp.swift`：iOS 真正后台时处理所有 tab；凭据读取跨 await 校验应用代次及发起 tab，关闭/切换后不借用新选择建立连接。macOS 普通失焦不触发移动端暂停策略。
- `rust-core/crates/ssh-core/src/{session,remote}.rs`、`rust-core/crates/apple-ffi/src/ssh.rs`：已认证 transport 的无命令 channel 探测、输入代次 gate、取消等待中的写入；UniFFI 生成物均由脚本重建。
- `apple/Tests/{TerminalLifecycleTests,WorkspaceLifecycleTests,SessionStabilityIntegrationTests}.swift`、Rust `remote_services.rs` / `openssh.rs`、`apple/UITests/PhaseZeroUITests.swift`：补充关闭/后台/陈旧凭据、真实多标签、恢复中关闭、弱引用、流控、长期限循环及隐私 UI 验证。
- `apple/Features/Settings/SettingsScreen.swift`、`apple/Resources/Localizable.xcstrings`：真实 App 版本/build、构建类型、本地数据/凭据/iCloud/MCP/传输缓存/后台策略说明，中英与浅深色；保留用户提供的原有图标。
- `apple/Privacy/`、`apple/project.yml`、`apple/Package.swift`、`scripts/{generate-permission-localizations.py,embed-mcp-helper.sh,build-xcframework.sh}`：主 App/helper 隐私清单与版本、由唯一 String Catalog 生成的原生网络用途说明。生成资源保持忽略，不手改绑定。
- `scripts/{check-release.py,archive-release.sh,test-stability.sh,test-phase6-ui.sh,verify.sh}`、`scripts/tests/test_release_check.py`、`apple/Release/ExportOptions.plist`：仅本地的检查/归档/导出入口及 10 项发行检查回归；旧 fixture 脚本增加 Phase 6/终端专项入口。
- [隐私材料](PHASE6-PRIVACY.md)、[发布说明](PHASE6-RELEASE.md)、[人工矩阵](PHASE6-ACCEPTANCE.md)、[架构](ARCHITECTURE.md)、README/AGENTS 同步更新。

## 当前环境与自动化结果

Xcode 27.1 (27A9275)、Apple Swift 6.4、Rust/Cargo 1.99.1；SwiftTerm 1.19.0，UniFFI 0.32.2 等依赖版本保持锁定。最低部署目标仍为 macOS 14 / iOS 17；当前工具/模拟器通过不等于最低系统实测。

| 实际命令/检查 | 结果及证据 |
| --- | --- |
| `scripts/verify.sh`（最终统一检查，指定已有派生目录及 iPhone UDID） | exit 0；`build/phase6-verify-final.log`；格式、Swift strict lint、Clippy `-D warnings`、翻译检查、绑定 typecheck、XCFramework 生成、两平台 Local 构建/包检查和单元测试通过 |
| Rust workspace 单元/普通集成 | 52 passed，0 failed，16 opt-in ignored；终端专项时序调整后又运行 fmt/clippy/workspace tests，通过，`build/phase6-rust-final.log` |
| Python 发行预检回归 | 10 tests，全部通过；`build/phase6-release-green.log`，最终统一检查亦运行这些测试 |
| String Catalog | 390 keys，zh-Hans/en 完整；没有新增外部运行时依赖 |
| macOS 单元 | 最终关于页修复后重跑，72 项中 67 passed、5 opt-in skipped、0 failed；`build/phase6-settings-macos-unit-20261027-202355.xcresult`；统一检查原结果 `build/macOS-unit-20261027-193328.xcresult` 同样通过 |
| iOS 模拟器单元 | 最终关于页修复后重跑，62 项中 58 passed、4 opt-in skipped、0 failed；`build/phase6-settings-ios-unit-20261027-202355.xcresult`；统一检查原结果 `build/iOS-unit-20261027-193328.xcresult` 同样通过 |
| `scripts/test-linux-services.sh --quick` | 真实 Linux/OpenSSH 8 passed，包含探测/取消、SFTP/断网及 MCP 固定操作；`build/phase6-linux-quick-final.log` |
| `scripts/test-linux-services.sh --terminal` | 真实终端 5 passed，4 MiB 双向窗口流控、PTY、top/中断、拒绝密码/未授权 key、断网和满输出取消；`build/phase6-terminal-linux-final.log`。fixture 禁用密码登录，成功密码路径未执行 |
| `scripts/test-stability.sh --rust-only` | 4 个真实 transport 持续 90 秒，320 轮，每轮对四个会话各做 probe/命令/resize；末尾 SFTP 仍可用，全部 worker 在断开后退出。进程最大 RSS 19,251,200 bytes，约 18.4 MiB；`build/phase6-stability-rust.log` |
| 三端真实生命周期专项 | 各 1 项通过：3 个并行 tab、后台拒绝输入、远端退出不影响其他 tab、前台检查后继续命令、12 次 tab 连接/关闭（其中 4 次在恢复检查开始后立即关闭）、native surface 仍保留时 session 弱引用释放 |
| 三端真实 Keychain/持久化专项 | 各 1 项通过；真实系统 Keychain 保存/读取/删除、磁盘重开、多标签隔离与凭据清理；`build/phase6-keychain-driver.log`。只使用独立临时 service/store，不操作用户主机凭据 |
| `scripts/test-phase6-ui.sh --mac-full`，再以 `scripts/test-phase6-ui.sh` 验证最终关于页修复 | 两次均 exit 0；macOS 全量 10 项中 9 passed、1 真实 SSH 表单 opt-in skipped；最终三端各 1 项隐私/App与Rust真实版本/中英/外观/重启/Home 专项 passed。此前两移动端全量各 7 项均 passed |
| `swift scripts/check-cloudkit.swift` | 两平台 Debug/Release/Local 源配置与生成结果一致；`build/phase6-cloudkit-config.log`。不代表真实 iCloud 已通过 |
| App / XCFramework 架构 | macOS App、iOS 模拟器 App、iOS device Release App 及三个 XCFramework slice 均实际检查为 arm64；没有 Intel/Universal 产物 |
| 隐私/用途/图标资源 | Local 严格代码签名检查、两平台 App/helper 隐私清单、编译后中英 `InfoPlist.strings`、源图标和归档资源一致性通过；`build/phase6-unsigned-resource-check.json` 只代表资源/身份检查，明确不可分发 |
| 源文件空白检查 | `git diff --check` 及 41 个本阶段文件的 `git diff --no-index --check /dev/null` 检查无错误；`build/phase6-whitespace-check.log`。无首次提交时普通 diff 无法覆盖未跟踪文件，故另外检查这些文件 |

真实 SSH 生命周期结果：`build/phase6-{mac,iphone,ipad}-ssh-20261027-194245.xcresult`。真实 Keychain 结果：`build/phase2-{mac,iphone,ipad}-ssh-20261027-194158.xcresult`（复用既有 Phase 2 测试方法，本阶段实际重跑）。普通 suite 的 opt-in skipped 不记为成功；已在上述独立 fixture 中运行的项目另行计数。Rust 2 GiB 与密码成功登录 opt-in 本阶段未重跑，2 GiB 历史记录见 Phase 3。

90 秒资源数值是独立 Rust 测试进程的有界观测，不是 GUI App 长时间无泄漏证明；没有运行 Instruments Leaks/Allocations，仍列在人工矩阵。

## UI 与原始截图

最终三端结果：`build/phase6-{macos,iphone,ipad}-ui-20261027-201802.xcresult`，包含桥接版本真实返回后的断言；前一次 macOS 全量结果保留在 `build/phase6-macos-ui-20261027-193505.xcresult`。分别包含中文浅色隐私、英文深色隐私、英文深色关于，9 张最终原始 PNG 导出至忽略的 `build/phase6-screenshots/`，已比对复制前后 SHA-256，未编辑或拼接，索引在该目录 `README.md`。

已实际查看代表性的 macOS 英文深色、iPad 中文浅色、iPhone 英文隐私及最终英文关于运行截图；长说明按原生 Form 滚动。UI 校验不代替 VoiceOver 全流程、不同动态字号/最低系统和物理设备权限验收。

初轮 `verify.sh --ui` 因新 macOS 测试用 `isSelected` 读取 AppKit radio 状态失败；既有持久化回归通过，修正为读取实际 AX `value` 后，上述 macOS 全量重跑通过。失败原始结果 `build/macOS-ui-20261027-191233.xcresult` 保留；两移动端同轮全量各 7 项通过。随后将原录制/遥测重复标签调整为独立录制与应用遥测，再完成最终三端专项截图。

最终截图复查发现 iPhone 重启后关于页的 bridge 版本停留在加载状态。新增等待实际 `0.1.0` 返回的断言后，`build/phase6-bridge-about-iphone-check.xcresult` 确认失败；将读取任务从整个设置页移到随关于页出现执行的 `.task(id: category)` 后，最终三端专项、两平台单元重跑通过，iPhone 最终截图同时显示实际 App 0.1.0 (1) 与 Rust 0.1.0。对应 Release 归档亦重新构建。

## Release 归档与签名实际结果

下表保留阶段验收时的历史脚本归档结果；这些命令均未给 `-allowProvisioningUpdates`，不修改门户或 Keychain ACL，`ExportOptions` 仅 `destination=export`。用户后续授权的门户配置及内部 TestFlight 上传单独记录在下文，不将早期失败改写为成功。

| 命令 | 实际结果 |
| --- | --- |
| `scripts/archive-release.sh macos --unsigned` | exit 0；最终关于页修复后重建 `build/archives/SSHClient-macos-20261027-122420.xcarchive`；Release arm64，包含 helper/隐私/图标/中英用途资源，标记为不可发行。初次归档 `114843` 另行保留 |
| `scripts/archive-release.sh ios --unsigned` | exit 0；`build/archives/SSHClient-ios-20261027-115004.xcarchive`；Release 真机 arm64 编译/资源通过，标记为不可发行 |
| `scripts/archive-release.sh macos` | exit 1；Xcode 明确缺 `com.ruohai.termall` 的 Mac App Development provisioning profile；`build/phase6-archive-macos-20261027-115805.log`。没有自动创建 profile |
| `scripts/archive-release.sh ios` | Xcode `ARCHIVE SUCCEEDED`，最终关于页修复后重建 `build/archives/SSHClient-ios-20261027-122756.xcarchive`；随后发行预检返回 `EXPORT_COMPLIANCE_REVIEW_REQUIRED`，因此 driver exit 1，不导出。初次开发签名归档 `115818` 保留；重建中的 `122514` 执行被中断，未生成归档，已确认无 Xcode 进程后清理空锁并成功重试 |
| iOS 已签名归档独立核查 | `codesign --verify --deep --strict` exit 0，实际 Team `86HC8YA388`、Bundle `com.ruohai.termall`、版本 0.1.0 (1)、Apple Development 身份和含设备列表的开发 profile；`build/phase6-ios-signed-archive-check.json`。它是开发签名，不能视为发行包 |
| 分发负例 | 对 Local App 拒绝 `DISTRIBUTION_IDENTITY`；对未分类的 Release 归档拒绝 `EXPORT_COMPLIANCE_REVIEW_REQUIRED`；`build/phase6-unsigned-distribution-rejected.json` 明确 `distribution_accepted=false` |

阶段验收时的公开证书/profile 快照：Team 开发身份存在，未检测到对应本地发行身份；已有两个 iOS 开发 profile，其中一个匹配主 Bundle，当时没有 macOS profile。原始摘要见 `build/phase6-signing-state.json`。后续已由 Xcode 获得匹配的 iOS Store、Mac Development 和 Mac Store profile，见下文；本机仍未取得发行私钥，Organizer 使用云端签名。

发行检查还要求正式发行证书、非开发/ad-hoc profile、Production CloudKit 权限、签名 leaf 证书属于 profile 以及 helper 正确权限。项目脚本的发行预检正向路径和本地签名导出未通过；Organizer 云端签名/内部上传已完成，原生 macOS 的 TestFlight 安装、签名及启动已实测通过。已安装包的 `--mode local` 检查通过，明确返回 `distribution_checks_passed=false`，不能替代完整发行检查。加密出口法规文件要求和后续商店材料仍需发布负责人复核，见 [发布说明](PHASE6-RELEASE.md)。

## 问题修复与独立复核

1. 先复现关闭/结束后迟到事件可能改回 connected；加入终止标记保护与测试。
2. `build/phase6-workspace-red.log` 复现凭据读取期间进后台再回前台仍新建 tab；加入应用代次校验。`build/phase6-closed-tab-red.log` 再复现关闭发起 tab 后迟到结果借用其他 tab；绑定发起 tab，并保护成功/异常两条路径。最终两项测试均通过。
3. 独立复核发现 SSH 流控等待开始后的旧输入未随 gate 取消；`phase6-window-red.log` 实际断言失败，改为 watch + 优先取消 select，专项和真实 4 MiB 流控均通过。
4. 发行 profile 校验补上实际 CloudKit 权限和实际 leaf DER 交叉验证；拒绝开发证书、带设备列表的 profile 和错误环境。10 项 Python 回归通过。
5. Linux 新终端专项发现旧 top 测试把 Ctrl+C 与后续命令同批发送，后续 marker 超时；改成等待已知 fixture shell prompt，再发下一条命令，5 项全部通过。原失败 `build/phase6-terminal-linux.log` 保留，不修改产品终端字节语义。
6. 关于页 bridge 元数据读取随页面展示触发，补重启后实际值断言并重新运行三端专项、两平台单元与 Release 构建，避免把加载中的截图当作桥接验收。

独立只读 reviewer 在上述三处核心修复（输入等待、过时凭据、profile 绑定）收口后未发现剩余 Critical/Important；reviewer 未替代主流程执行任何构建、签名或网络测试。

## 明确未验证与遗留

- Phase 4：真实 iCloud 账号、Production Schema、同账号两设备增改删/冲突/离线/账号切换；同步 Mock 不能代替。
- Phase 5：正式 macOS Team/App Group/helper 自身沙盒与外部 Codex 的真实 IPC、最低系统/锁屏/系统睡眠、真实 systemd 成功查询。
- Phase 6：脚本发行预检正向路径、本地发行签名导出、加密出口法规文件判断、隐私政策/商店资料、物理 iPhone/iPad 的 TestFlight 安装；物理设备 LAN 允许/拒绝、长后台/锁屏/网络切换、外接键盘、长期 Instruments、完整无障碍及最低系统。原生 macOS 的 TestFlight 安装与启动已完成，helper dSYM 上传警告仍待处理。

这些项目不预勾，也不将环境限制改成产品成功结论。完整步骤见 [人工验收矩阵](PHASE6-ACCEPTANCE.md)。当前停止于 Phase 6，不自动扩展后续功能。

## iOS TestFlight 首次上传记录（2026-10-27）

本节保留首次 iOS 上传时的门户快照；后续 Mac 安装与平台变更见下一节。首次上传时无安装记录，不表示当前 Mac 安装仍未完成。

- App Store Connect 已创建独立 iOS 应用记录：显示名 `TermAll`、Bundle ID `com.ruohai.termall`、SKU `com.ruohai.termall`、应用记录 ID `6827553339`。没有改动账号中其他应用。
- 已建立内部测试组 `TermAll 内测`，关闭自动分发。已将当前登录的 Admin 用户添加为 1 名内部测试员；现已把构建 `0.1.0 (2)` 加入该群组。App Store Connect 显示群组为 1 名测试员、1 个构建版本；测试员状态“已邀请”，未显示安装或使用记录。未添加其他人员，也没有开启自动分发。
- 新归档 `build/archives/SSHClient-ios-20261027-130240.xcarchive`：Release、arm64、版本 `0.1.0 (2)`、显示名 `TermAll`、Team `86HC8YA388`、正式 Bundle ID；`codesign --verify --deep --strict` 通过。该归档使用 Apple Development 身份和含设备列表的开发描述文件，不是 App Store 分发包。
- `scripts/archive-release.sh` 的分发预检按预期以 `EXPORT_COMPLIANCE_REVIEW_REQUIRED` 拒绝未完成出口分类的正式发行路径。
- 本地尝试 `testFlightInternalTestingOnly=true` 导出时，Xcode 报告该 Xcode 管理的开发描述文件不是 iOS App Store 描述文件；未生成本地导出包。完整错误记录在 `build/phase6-export-ios-internal-20261027-130240.log`。
- 上传前检查发现 Developer Portal 有一张有效 iOS Distribution 证书（2027-09-21 到期），但其私钥不在当前 Mac 中。当时看到的 App Store 描述文件 `rhhl` 绑定其他应用，TermAll 尚无匹配文件。后续 Organizer 已自动生成匹配的 Store profile；没有手动撤销或删除现有证书。
- Xcode Organizer 后续以 TestFlight Internal Only 完成云端签名/上传，并显示 `App upload complete: SSHClient 0.1.0 (2) uploaded`。App Store Connect“构建版本上传”记录显示版本 `0.1.0 (2)`、状态“完成”、创建时间 Oct 27, 2026 9:20 PM。上传后本机没有生成发行私钥。
- 用户确认加密算法问卷第 2 项，并说明当前不计划在法国分发。问卷页面随后关闭，构建详情不再显示“提供出口合规证明信息”；未另行看到需上传的文件。App Store Connect 没有提供页面可读的已保存问卷答案回执，因此不把这一步视为法规审查或豁免结论。
- 得到用户确认后，已把 `TermAll 内测` 加到该构建。首次上传时 TestFlight iOS 列表显示版本 `0.1.0 (2)`、类别“内部”、状态“正在测试”、群组 `TermAll 内测`、邀请数 1；当时未显示安装记录。随后确认 Mac 安装的是该 iOS/iPad 兼容构建，并已用下一节的原生版本替换；物理 iPhone/iPad 安装仍未验证。
- 静态技术事实：`rust-core/Cargo.toml` 固定 `russh 0.65.0` 并启用 `ring` / `rsa`；`Cargo.lock` 包含 AES/AES-GCM、ChaCha20、Curve25519、Ed25519 等加密组件；应用实际实现 SSH/SFTP。Apple 要求开发者自行确定出口合规要求并对错误申报负责，见 [Apple 出口合规说明](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)。本机发行预检与文档准备仍需复核，不把 TestFlight“正在测试”当作商店发行批准。
- `TestFlight Internal Only` 仅限团队内部测试，不能再用于外部 TestFlight 或 App Store；流程遵循 [Apple Xcode 分发说明](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)。

## macOS 原生 TestFlight 安装（2026-10-27）

- 根因：原 `/Applications/TermAll.app` 是 iOS-on-Mac 包，含 `WrappedBundle` / `Wrapper/SSHClient.app`，支持平台为 `iPhoneOS`，版本 `0.1.0 (2)`。已有独立 macOS target，无须更换 UI 或网络核心。
- 在同一 App Store Connect 应用记录（ID `6827553339`、Bundle `com.ruohai.termall`）中添加 macOS 平台。用户自行恢复 Developer 登录后，登记当前 Apple Silicon Mac 的 Provisioning UDID；Xcode 自动取得 `Mac Team Provisioning Profile: com.ruohai.termall`，Organizer 分发时再取得对应 Mac Store profile。未手动新建、撤销证书或改 Keychain ACL。
- 前两次归档因没有已登记 Mac/profile 失败，保留 `build/phase6-native-macos-20261027-135554.log`、`build/phase6-native-macos-20261027-135718.log`。登记后成功归档 `build/archives/SSHClient-macos-20261027-140126.xcarchive`，日志 `build/phase6-native-macos-20261027-140126.log`：Release、`0.1.0 (3)`、arm64、正确 Team/Bundle，主 App/helper 严格签名与本地包检查通过；归档自身为开发签名。
- Xcode Organizer 选择 TestFlight Internal Only，云端签名及上传成功。非阻塞警告：归档缺少 `SSHClientMCP.app` 的匹配 dSYM（UUID `B4FD6095-6FE2-3A79-A643-70E2DCD33523`），影响 helper 崩溃符号化，尚未修复。没有将该警告表述为完整符号上传成功。
- 按用户已确认答案选择标准加密算法第 2 项、法国分发选“否”，实际点击保存。macOS 构建 `0.1.0 (3)` 显示“正在测试”，已关联现有 `TermAll 内测`，该组仍只有用户自己的 1 名 Admin 测试员。没有新增其他测试员或提交商店审核。
- Mac TestFlight 选择 macOS 后提示先卸载 iOS App。先正常退出旧兼容版，使用 Finder 备份其 SwiftData 数据库及偏好到忽略目录 `build/termall-native-migration-20261027/`，另存旧 App ZIP 与 SHA-256 清单。备份数据库只读 `integrity_check` 为 `ok`，原主机数/分组数均为 0；未读取或导出 Keychain。原容器受系统隐私保护，未进行源文件与副本的逐文件哈希对比。
- 旧兼容版 App 移入系统废纸篓，没有清空；未主动删除数据容器。TestFlight 随后安装成功，按钮变为“打开”。实际原生包路径 `/Applications/SSHClient.app`，显示名 TermAll，内部可执行文件名仍为 SSHClient。
- 已安装包核查：`CFBundleSupportedPlatforms=[MacOSX]`，无 iOS Wrapper；主 App/helper 为 arm64，Mach-O 平台为 `MACOS`；版本 `0.1.0 (3)`、Team `86HC8YA388`、签名为 `TestFlight Beta Distribution`。`codesign --verify --deep --strict`、`scripts/check-apple-architectures.swift` 和 `check-release.py --mode local` 通过，证据为 `build/phase6-native-macos-installed-state.json`、`build/phase6-native-macos-installed-check.json`。
- 实际打开并查看原生 macOS 侧栏、终端、SFTP 底部面板、服务器信息栏；关于页显示 TermAll `0.1.0 (3)` 和实际 Rust `0.1.0`。未连接用户服务器、启用同步或 MCP；本轮未重跑完整测试套件，已有独立 Local Debug App 未改动。
