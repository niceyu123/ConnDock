# ConnDock 新应用身份及验证

日期：2026-10-28。按用户要求新建独立 App Store Connect 记录，后续作为正式 App；CloudKit 与旧 TermAll 隔离。

## 已配置

- Apple Developer Team：`86HC8YA388`；新 App ID：`com.ruohai.conndock`。
- App Store Connect 新记录：ConnDock，Apple ID `6827804281`，SKU `com.ruohai.conndock`，主要语言简体中文，含 iOS、macOS；选择有限用户访问权限。TestFlight 当时显示无构建。
- 新 CloudKit Container `iCloud.com.ruohai.conndock` 已注册，并在明确确认后关联新 App ID。重新打开容器选择页面验证：仅新容器选中，`iCloud.com.ruohai.termall` 未选中。
- Debug/Release 工程及签名检查使用新 Bundle、独立容器和 macOS App Group `86HC8YA388.com.ruohai.conndock.mcp`；主 App 与 helper 保持一致。Local 保留原有身份且不使用 CloudKit。
- 旧 TermAll 记录及容器暂时保留；新旧沙盒、Keychain 和云数据不会自动迁移。新版本的主机凭据如需使用，应在新身份下重新输入。

## 验证

- `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`：10 项通过。
- `python3 scripts/check-release.py --source-only`：通过；两个 Local 包的 `--mode local` 检查通过，不代表发行包通过。
- `xcrun swift-format lint --strict apple/Features/AIIntegration/MCPIPCServer.swift scripts/check-cloudkit.swift`：通过。
- `xcrun swift scripts/check-cloudkit.swift`：两平台 Debug / Release / Local 共 6 项构建配置检查通过，日志 `build/conndock-identity-20261028/cloud-settings.log`。
- 两端 Local 构建通过，App 与 XCFramework 的 arm64 架构检查通过；日志见 `build/conndock-identity-20261028/{macos,ios}-build.log`。
- 初次不允许自动更新描述文件的 Debug 构建失败：macOS 缺少新 Bundle 的开发描述文件；iOS 通配描述文件不含新 iCloud 权限。随后用 `-allowProvisioningUpdates` 取得匹配配置，两端 Debug 构建通过；实际签名包均核对新 Bundle、Development CloudKit entitlement 与匹配 profile，macOS 主 App/helper 的新 App Group 一致，严格签名校验通过。日志 `build/conndock-identity-20261028/{macos,ios}-auto-debug.log`。
- 两端 Release archive 成功、严格签名校验通过，版本均为 `0.1.0 (1)`；归档分别位于 `build/archives/ConnDock-new-{macos,ios}-20261028.xcarchive`，日志为 `build/conndock-identity-20261028/{macos,ios}-archive.log`。两份归档使用 Apple Development 签名与含设备列表的开发 profile；归档 entitlement 为 Production CloudKit，profile 授权 Production / Development。它们不是 App Store 分发签名包。

## 新 ConnDock 内部 TestFlight 上传（2026-10-28）

- 经用户明确授权，通过 Xcode Organizer 的 TestFlight Internal Only 上传新 Bundle `com.ruohai.conndock` 的 iOS 和原生 macOS `0.1.0 (1)`；Organizer 均显示已上传。macOS 为 Apple Silicon 归档。
- App Store Connect 新记录 `6827804281` 的两平台构建均显示“正在测试”，关联 `ConnDock 内测`。该内部群组关闭自动分发，只有当前用户的 1 名内部测试员。两平台构建行目视显示黑白终端/服务器新图标；页面顶部 App 占位图仍未显示新图标。尚未选择可供 App Store 提交的构建到商店版本，因此不能声称商店版本图标已更新。
- 两平台构建处理期间曾显示缺少出口合规证明；页面随后变为“准备测试”，并在关联群组后变为“正在测试”。页面状态不构成法律合规或出口豁免结论；正式分发仍需复核。
- 两平台均为 Internal Only 构建，不能用于外部测试或 App Store 提交。未在物理设备安装或验证新身份的云同步及 macOS helper。

## 尚未完成

CloudKit schema、真实跨设备同步、新 App Group 的正式沙盒与 IPC、发行签名/导出、物理设备及正式发行验收均未验证。旧 TermAll 记录未移除；待新测试路径确认后再处理。没有执行完整 `scripts/verify.sh` 或本轮 UI 测试。
