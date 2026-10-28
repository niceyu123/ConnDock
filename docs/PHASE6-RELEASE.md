# Phase 6 本地归档与 TestFlight 准备

> 2026-10-28 更新：已新建独立 ConnDock 商店记录 `6827804281`，Bundle ID 为 `com.ruohai.conndock`，并注册及关联独立 CloudKit 容器 `iCloud.com.ruohai.conndock`。新身份的两平台 Development 签名构建和实际 entitlement 已核验；下面的 TermAll 归档与 TestFlight 结果均为旧身份的历史记录，不代表新身份已完成发行签名、上传或真实云端验收。

只支持 macOS Apple Silicon arm64、iOS arm64 和 arm64 模拟器。产品显示名称为 **ConnDock**；Xcode 工程为 `ConnDock.xcodeproj`，Target、Swift 模块和可执行文件使用内部开发名 SSHClient。新 Bundle ID、CloudKit Container 和 App Group 均与旧 TermAll 隔离。版本来自 `apple/project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`，关于页读取实际 Bundle 值。

**TestFlight 当前状态（2026-10-27）：** Xcode Organizer 已通过云端签名上传 iOS `0.1.0 (2)` 与原生 macOS `0.1.0 (3)`，均为 TestFlight Internal Only，状态“正在测试”，已关联内部群组 `TermAll 内测`；测试员只有用户自己的 Admin 账号 1 名，自动分发关闭。Mac 已从 TestFlight 安装并打开原生版本，实际包为 `MacOSX / arm64`、版本 `0.1.0 (3)`、TestFlight Beta Distribution 签名，严格签名检查通过。旧 iOS 兼容版已备份并移入废纸篓；物理 iPhone/iPad 安装仍待验证。macOS 上传有 helper 缺失 dSYM 的非阻塞警告，尚需补齐崩溃符号。

## 可重复入口

```bash
scripts/verify.sh --ui
scripts/test-phase6-ui.sh                 # 只验证三端隐私/版本/重启/后台界面
scripts/test-linux-services.sh --quick
scripts/test-linux-services.sh --terminal  # 含 4 MiB 双向 SSH 流控；fixture 不支持密码成功登录
scripts/test-stability.sh                  # 4 会话 90 秒 + 三端实际生命周期/12 次 tab 释放
SSHCLIENT_TEST_SOAK_SECONDS=600 scripts/test-stability.sh --rust-only
python3 scripts/check-release.py --source-only
python3 scripts/check-release.py --mode local --app /absolute/path/SSHClient.app
scripts/archive-release.sh macos --unsigned
scripts/archive-release.sh ios --unsigned
```

`SSHCLIENT_TEST_SOAK_SECONDS` 限定 30–600 秒，默认 90 秒。真实 SSH fixture 为临时 loopback OpenSSH/Linux，不连接保存主机，不记录终端内容；测试结束删除临时私钥及 fixture。`/usr/bin/time -l` 记录整个测试进程的资源，并不等于 App 的长期内存表现。Apple 检查使用同一串行锁，避免 Xcode/模拟器争用。

`--unsigned` 仅验证 Release 编译/归档和 arm64，产物内写入明确的不可发行标记，不允许同时 `--export`。正式签名入口：

```bash
scripts/archive-release.sh macos
scripts/archive-release.sh ios
# 签名、profile、加密申报等前提全部满足后，仅导出到本地：
SSHCLIENT_BUILD_NUMBER=2 scripts/archive-release.sh ios --export
```

若自动签名选中了开发证书，可通过 `SSHCLIENT_SIGN_IDENTITY` 指定本机已有的真实发行身份，必要时以 `SSHCLIENT_PROVISIONING_PROFILE_SPECIFIER` 选择已有匹配 profile；脚本不会创建这些材料。发行预检拒绝开发证书、包含设备列表的开发/ad-hoc profile、非 Production CloudKit 环境。

脚本不上传、不自动创建证书/profile/门户配置、不改 Keychain ACL、不关闭安全权限、不自动增加版本。每次使用新的 `build/archives/SSHClient-<platform>-<UTC时间>.xcarchive`；同名路径存在即拒绝覆盖。`SSHCLIENT_BUILD_NUMBER` 只能为正整数。`apple/Release/ExportOptions.plist` 固定 `destination=export`，关闭自动 build number 管理和 symbol 上传；它不是上传授权。

签名失败时在 `build/phase6-archive-*.log` 查看原因。有效归档也要通过只读发行预检：

```bash
python3 scripts/check-release.py --mode distribution --app /absolute/path/SSHClient.app
```

预检检查当前项目约定的正式 Release Bundle、Team、版本、签名、profile 期限/身份/平台、沙盒/helper 权限、arm64、图标源、主 App/helper 隐私清单、实际中英本地网络用途资源及误打包测试配置。Local 检查明确返回 `distribution_checks_passed=false`。内部预检通过也始终返回 `apple_submission_accepted=false`；只有 Apple 的实际处理结果可确认提交情况。该脚本不是通用漏洞或所有秘密扫描器。

主 App 还会核对实际 CloudKit entitlement 得到 profile 授权、实际 leaf 证书属于 profile 的 `DeveloperCertificates`；只在临时目录提取公有证书并清理，不修改被检查包。依据 [Apple TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)。helper 使用 Team ID 前缀的 macOS group，其形式按 [Apple 的 App Group 说明](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) 不强制独立 profile；仍须验证正式签名、沙盒和真实 IPC。

## 后续发行前仍需完成

1. 为新 `com.ruohai.conndock` 取得两平台匹配的签名和 profile；旧 TermAll profile 不适用于新身份。验证 macOS helper `com.ruohai.conndock.mcp` 与 group `86HC8YA388.com.ruohai.conndock.mcp` 的真实沙盒和 IPC，完成 [Phase 4 云端配置](PHASE4-CLOUDKIT-SETUP.md) 和 [Phase 5 正式沙盒待办](PHASE5-VALIDATION.md)。
2. 用户已确认标准加密算法类别第 2 项及当前不在法国分发；macOS 问卷已实际保存，两平台构建均进入“正在测试”。这不能推断已获法律豁免或不需文件。面向后续发行，仍须核对 SSH/Rust 加密分类与 Release Info 的 `ITSAppUsesNonExemptEncryption`；若需文件，补 Apple 要求的文件与 `ITSEncryptionExportComplianceCode`，不可用假值绕过。
3. 核实 Production CloudKit schema 与两设备增删改、冲突、离线、账号切换。Local 形态不实例化 CloudKit，不能代替此步骤。
4. 完成 [人工验收矩阵](PHASE6-ACCEPTANCE.md)，尤其物理设备局域网权限、锁屏/后台/网络切换、最低系统、Keychain 交互和正式 helper。使用 Instruments Allocations/Leaks 进行更长时间交互；短时间 RSS 与弱引用通过不是无泄漏证明。
5. 提供正式品牌/运营主体/支持联系及公开隐私政策 URL；核对 [隐私草稿](PHASE6-PRIVACY.md)、App Store 隐私回答、截图、年龄分级、出口问卷和测试说明。当前不编造这些资料。
6. 审查归档内 App、helper、静态库实际架构与签名，Xcode Organizer 校验，生成隐私报告，选择正确版本/build。若归档使用开发签名，应在 Xcode 分发导出时正确重新签名，再对最终 App 运行发行预检；不把开发归档视为可上传最终包。
7. 原生 macOS 已完成 TestFlight 实际安装、签名/架构核查和启动；仍须在物理 iPhone/iPad 上安装并完成其余人工矩阵。补齐 `SSHClientMCP.app` 的匹配 dSYM 后验证符号上传；当前缺失只记为警告，不将其当作完整崩溃诊断准备。内部与外部测试的审核/邀请条件以 [Apple TestFlight 说明](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview) 为准。

本机结果与明确未验证项统一记录在 [PHASE6-VALIDATION.md](PHASE6-VALIDATION.md)。
