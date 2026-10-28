# Phase 4 实现与验收记录

日期：2026-10-27（Asia/Shanghai）。需求以 `requirements.md` 及用户补充的真实签名标识、标签和 Apple Silicon 范围为准。Phase 4 实现、配置与本机验证已完成：统一脚本、三端 UI、既有真实 SSH/SFTP 回归、iPad 呈现颜色回归和 macOS 未签名 Release 构建均通过。真实 CloudKit 端到端仍未验收，不能把本记录当作云端全部通过；不进入 Phase 5。

## 实现

- SwiftData 本地优先，自动 CloudKit 镜像保持关闭。V2 增加持久 journal/state，V3 用扩展表保存标签；不修改 V1 主机表结构，迁移保留 UUID 与本机凭据引用。
- 实际 CKSyncEngine transport、Private Database、单一 `SSHClientPrivateV1` Zone；`SSHClientConfigV1.payloadV1` 是 encryptedValues 的 Bytes 字段。recordName 仅含类型与 UUID，所有主机地址、用户名、备注、分组和标签在加密文档内。
- 本机编辑/outbox 同一提交；逻辑版本与设备 ID 决定完整记录冲突结果，删除优先。旧发送确认不能清掉新编辑；组删除、乱序交付、重开和失败回滚有测试。
- 密码、私钥、Keychain 引用、信任决定、终端内容、最近连接、语言/外观不编码上传。远端目标身份变化撤销旧本机凭据；同步下来的新主机仍要求输入凭据与校验身份。
- 默认关闭，原生范围确认，手动同步、状态、待处理数、最近成功时间、失败退避；离线可正常修改。前台周期同步、后台取消，运行代号阻止迟到回调。关闭保留本地，账号/Zone 变化暂停，云端副本删除有独立确认。
- 三端设置页支持中英与浅深色；新文案在 String Catalog，当前 294 项完整双语。
- 按用户补充，macOS 仅支持 M 系列，Xcode/工具链移除 Intel 目标，XCFramework 取消 Universal 合并；统一脚本检查实际三个 arm64 slice 及 App Mach-O。

## 配置与环境

| 配置 | macOS | iOS/iPadOS |
|---|---|---|
| Debug/Release Bundle | `com.ruohai.termall` | `com.ruohai.termall` |
| Team | `86HC8YA388` | `86HC8YA388` |
| Container | `iCloud.com.ruohai.termall` | `iCloud.com.ruohai.termall` |
| Signing | Automatic | Automatic |
| Local Bundle | `local.SSHClient.macOS` | `local.SSHClient.iOS` |

Debug 为 Development、Release 为 Production；Local 为无云端权限的 ad-hoc 构建。macOS 两种身份均保持 Sandbox、Outgoing Connections 与用户选定文件读写，无 Incoming Connections。

`scripts/check-cloudkit.swift` 对两个 App 的 Debug/Release/Local 共 6 组生成构建设置、Info、arm64 与 Entitlements 检查通过（`build/phase4-configuration-check-final.log`）。这不是实际签名成功。

实际运行两端 Debug 签名构建分别 exit 65。日志明确为缺少 `com.ruohai.termall` 的 Mac App Development / iOS App Development 描述文件；未允许命令行自动创建或更新描述文件。本机 `security find-identity -v -p codesigning` 为 0 valid identities。原始日志：`build/phase4-signing-macos.log`、`build/phase4-signing-ios.log`。没有创建新 Container 或更改 Apple Developer 后台。

## 已确认结果

| 检查 | 结果 | 证据 |
|---|---|---|
| 统一验证 | exit 0，格式/翻译/Clippy/构建/测试/实际架构检查通过 | `build/phase4-verify-complete.log` |
| Rust 常规 | 17 通过，10 项真实服务用例默认忽略 | 同上；此次未改 Rust 网络算法 |
| 存储/加密/迁移/冲突 | 12 通过，包含于下方两端基础测试 | 最终 macOS/iPhone 单元结果 |
| Mock 服务逻辑 | 9 通过，非真实 iCloud，包含于基础测试 | 同上 |
| macOS 全部基础测试 | 48 通过、3 跳过，0 失败（共 51） | `build/macOS-unit-20261027-155630.xcresult` |
| iPhone 全部基础测试 | 49 通过、3 跳过，0 失败（共 52） | `build/iOS-unit-20261027-155630.xcresult` |
| Apple Silicon 架构 | 3 个 XCFramework slice + macOS/iOS App 主 Mach-O 均仅 arm64 | `build/phase4-verify-complete.log` |
| macOS 同步设置 UI | 1 通过，0 跳过 | `build/phase4-macos-ui-20261027-155658.xcresult` |
| iPhone 同步设置 UI | 1 通过，0 跳过 | `build/phase4-iphone-ui-20261027-155658.xcresult` |
| iPad 同步设置 UI | 1 通过，0 跳过 | `build/phase4-ipad-ui-20261027-155658.xcresult` |
| iPad 已呈现设置颜色 | 1 通过，真实 trait 验证 light → dark → light | `build/phase4-settings-theme-ipad-green.xcresult` |
| 已有 SSH/SFTP/监控三端真实回归 | 各 1 通过，0 跳过 | `build/phase3-{mac,iphone,ipad}-ssh-20261027-154755.xcresult` |
| macOS Release 未签名构建 | BUILD SUCCEEDED，App 主程序实际仅 arm64 | `build/phase4-release-arm64-build.log`、`build/phase4-release-architecture-check.log` |
| Local 签名完整性 | codesign --verify --strict exit 0，仅 ad-hoc | `build/phase4-local-codesign-check.log` |

最终返回码为 `verify=0 ui=0 ipad_theme=0 unsigned_release=0`（`build/phase4-complete-exit-status.log`）；真实 SSH/SFTP 的前一组返回 `verify=0 ui=0 ssh_sftp=0`（`build/phase4-final-exit-status.log`）。Release 使用 `CODE_SIGNING_ALLOWED=NO` 只验证编译和架构，未签名、未安装、未发布，不能据此称 CloudKit 权限已生效。Xcode 的 Swift Package 派生缓存曾生成中间 x86_64 对象，但最终 Release App 没有嵌入这些对象或框架，仅含 arm64 主程序；中间缓存不是 Intel 发布支持证据。

3 项跳过为需专用配置的真实 SSH 集成测试，不计为通过。Phase 4 Mock 只在测试 Target，使用两个独立 SwiftData 数据库；实际 CKRecord 用于验证 encryptedValues 登记、拒绝明文格式和 ID 不匹配。未把这些测试计为真实云端同步。

## 失败、定位和修复

- 新接口缺失先失败：`phase4-sync-red.log`、`phase4-service-red.log`。随后最初 7 个存储与 5 个服务用例通过。
- 加密测试修正 SDK 假设：CKRecord.allKeys 包含加密字段名；检查改为所有业务字段均登记为 encryptedValues。认证方式 password 枚举值不是密码字段；白名单按编码 key 检查。
- 标签与迁移先记录缺接口失败：`phase4-tags-red.log`，实现后 V1 磁盘迁移、UUID/引用保留、标签去重/搜索/同步通过。
- 账号切换期间本机库在等待 Keychain 时无法持久关闭同步，`phase4-policy-red-r1.xcresult` 的 1 项用例 3 个断言复现。允许关闭动作在该等待期提交同步元数据后，同一测试与完整 macOS 套件通过。
- Local 自定义配置的 Swift Package 未带 testability，首次构建报模块不兼容；验证命令增加全局 `ENABLE_TESTABILITY=YES` 后 macOS 基础测试通过。
- 首轮 iPhone UI 构建尝试 x86_64 Package Product，而既有 XCFramework 仅支持 arm64 模拟器；命令已显式选择 arm64。失败保留在 `phase4-ui-run-r1.log` / `phase4-iphone-ui.log` 的历史结果中。后续使用固定参数重跑，不修改 Rust ABI。
- XcodeGen 生成的嵌套 SystemCapabilities 属性被写成字符串；移除错误展示项，实际 iCloud/沙盒能力由 Entitlements 和签名配置决定，不手改生成工程。
- Sign-out、Local 旧开启状态、V1 内部空白分组名先失败后修复。迁移测试新增分组后应产生 2 条队列记录，最初仍期望 1 条，已按新增夹具修正，不删除迁移断言。
- `phase4-zone-delete-red.xcresult` 复现旧设备会重建已删除云端 Zone。产品增加已确认副本存在性检查，最终 Mock 回归通过；真实 CloudKit 的此窗口仍待实测。
- `phase4-arm64-policy-red.log` 正确拒绝旧 `macos-arm64_x86_64`，重建后统一架构检查通过。
- `phase4-settings-theme-red.xcresult` 复现 iPad 设置 Sheet 打开期间 light 未切到 dark。SettingsScreen 自身绑定 locale/颜色后，iPhone 基础测试和 iPad 专项均通过；错误颜色的旧图片被最终成功结果的原始附件替换。

## 运行截图与复现

最终 6 张图来自 `phase4-{macos,iphone,ipad}-ui-20261027-155658.xcresult`，保存在忽略的 `build/phase4-screenshots/`。索引为该目录 `README.md`；每张与源附件的 SHA-256 相同，记录在 `SHA256SUMS.txt` 与 `build/phase4-artifacts-check.log`。未改色、反转、拼接或重绘；截图明确为 Local 无云权限状态。

```bash
xcrun swift scripts/check-cloudkit.swift
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' \
scripts/verify.sh
scripts/test-cloud-sync-ui.sh
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" scripts/test-linux-services.sh --apple-only
```

正式签名重试和两设备验收按 `PHASE4-CLOUDKIT-SETUP.md` 执行。最后的检查没有发现项目 fixture 私钥或 macOS/两台模拟器一次性配置残留；测试容器已删除，只清理本任务创建的资源。

## 文件范围

新增：

- `apple/Features/CloudSync/{SyncDocument,CloudSyncTransport,CloudKitRecordCodec,CloudKitSyncTransport,CloudSyncService,CloudSyncSettings}.swift`
- `apple/Shared/Models/CloudSyncModels.swift`、`apple/Shared/Storage/HostLibrary+Sync.swift`
- `apple/Tests/CloudSyncTests.swift`、`CloudSyncServiceTests.swift`
- `apple/Apps/iOS/SSHClient.entitlements` 及两端 `SSHClient-Local.entitlements`
- `scripts/check-cloudkit.swift`、`scripts/check-apple-architectures.swift`、`scripts/test-cloud-sync-ui.sh`
- 本阶段计划、配置说明、验收与复核记录。

修改：`HostModels.swift`、`HostLibrary.swift`、`WorkspaceState.swift`、`WorkspaceRoot.swift`、`MobileWorkspace.swift`、`HostSidebar.swift`、`NewHostSheet.swift`、`SettingsScreen.swift`、String Catalog；两 App 生命周期、macOS Entitlements、XcodeGen 工程与两端 Info；UI 测试、验证/Apple SSH/截图脚本；Rust 工具链目标、Rust Apple 库与 XCFramework 打包脚本；唯一需求、AGENTS/README/架构与旧阶段范围注记。

Rust 核心算法与 UniFFI API 未改变；架构目标与打包按用户要求移除 Intel。既有 Artwork/图标未改。工作区仍无首次 Git 提交，未提交或推送。

## 未完成的真实验收与限制

- 有效签名证书、描述文件与两台登录同一测试 Apple ID 的设备尚未具备；真实 CloudKit 的 Schema、加密字段类型、两设备增改删、实际断网/换账号和 Production 端到端均未验证。
- 当前仅前台自动同步，后台取消并在恢复前台后继续。不是后台即时复制；不包含共享数据库、凭据同步或 MCP。
- 冲突为完整记录选择，删除优先；不做字段级合并，删除标记不自动过期。另一个保留本地副本的设备重新确认启用后可以再次上传，删除云端副本文案已说明。
- 旧开发 Bundle 的沙盒与正式 Bundle 独立，旧数据保留但不自动跨沙盒迁移；未复制活动 SQLite 或导出 Keychain。手动步骤与真实验收清单见 `PHASE4-CLOUDKIT-SETUP.md`。

## Production Schema 与 Mac 首次同步（2026-10-27）

> 以下为旧 TermAll 身份历史；新 ConnDock 的 2026-10-28 修复记录见本文末尾。

- 用户授权后，在唯一容器 `iCloud.com.ruohai.termall` 的 Development 建立 `SSHClientConfigV1`，字段 `payloadV1` 为 `ENCRYPTED BYTES`，无索引。移除该新类型的 `_world`、`_icloud` 和 `_creator` 默认公开数据库授权；未修改 `Users` 既有权限。
- 使用 Team 签名的独立 Development 测试程序与唯一测试 Zone，以合成字符串执行加密字段写入和读回，结果 `DEVELOPMENT_ENCRYPTED_ROUNDTRIP_OK`。测试 Zone `TermAllSchemaProbe-BBD57294-C924-455B-A344-5EB77D28DB58` 保留在 Development，不包含主机配置。
- 用户审阅部署差异并授权后，CloudKit Console 显示 `Changes Deployed`；Production 中实际核对到 `SSHClientConfigV1.payloadV1` 为 `ENCRYPTED BYTES` 且无索引。
- 部署前，Mac TestFlight 应用读取 Zone 曾遇到 HTTP 500；后续进入记录写入，三条待同步记录失败。部署后在原生 Mac TestFlight `0.1.0 (3)` 的设置页点击“立即同步”，实际显示“已同步”、待同步 0、最近同步 10月27日 23:29。未读取或导出主机配置或凭据。
- 上述仅证明该 Mac 当次同步队列完成，不代表同账号两台设备、并发冲突、离线恢复、账号切换及真机前后台验收已完成；继续按 `PHASE4-CLOUDKIT-SETUP.md` 和 `PHASE6-ACCEPTANCE.md` 执行。

## ConnDock Production 同步失败修复（2026-10-28）

- 实测对象为 `/Applications/SSHClient.app` 的 ConnDock TestFlight 安装版；实际签名包含 `com.ruohai.conndock`、`iCloud.com.ruohai.conndock` 和 Production 环境。
- 用户授权开启同步后，首次及多次重试在 `CKFetchRecordZonesOperation` 阶段失败；系统日志确认 HTTP 500、`Server Rejected Request (15/2000)`。
- CloudKit Console 检查发现新容器尚未配置 `SSHClientConfigV1`。在 Development 新建该类型及 `payloadV1`（Encrypted Bytes，无索引），关闭该类型默认 `_world` 读取、`_icloud` 创建和 `_creator` 写入的公共数据库权限，保留既有 Users 权限。
- 部署预览仅包含新建 `SSHClientConfigV1` 类型，Indexes 与 Security Roles 变更均为 0；执行部署后 Console 显示 `Changes Deployed`。随后在 Production 实际核对 `payloadV1 ENCRYPTED BYTES`、索引 None。
- 部署后原安装版自动重试显示“已同步”、待同步 0、最近同步 14:48；再次点击“立即同步”仍成功，时间更新至 14:49（Asia/Shanghai）。本轮仅修改云端 Schema，无应用代码变更，无需重新发布 App。
- 本轮本机主机/分组为空，证明当前阻塞的 Production 同步轮次已恢复，不代表配置记录上传下载、两设备增改删、冲突、离线恢复或账号切换验收完成。同步保持启用；未删除云端副本、未访问密码或私钥。
