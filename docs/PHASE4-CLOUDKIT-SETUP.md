# Phase 4 CloudKit 配置与真实验收

## 已采用的真实标识

| 项目 | 值 |
|---|---|
| Organization（用户提供） | Ningbo Ruohai Digital Technology Co., Ltd. |
| Team | `86HC8YA388` |
| macOS / iOS / iPadOS Debug、Release Bundle ID | `com.ruohai.conndock` |
| 独立 CloudKit Container | `iCloud.com.ruohai.conndock` |
| 数据库 | 当前系统 Apple ID 的 Private Database |
| 自定义 Zone | `SSHClientPrivateV1` |
| Record Type | `SSHClientConfigV1` |
| 加密字段 | `payloadV1`，加密 Bytes（`Data`） |

2026-10-28 已按用户要求在 Apple Developer 注册新 App ID 和独立 Container、将容器关联至新 App ID，并创建 ConnDock App Store Connect 记录。新身份的 macOS/iOS Development 签名构建及实际 CloudKit entitlement 已核对；发行签名和真实云端验收尚待完成。旧 `com.ruohai.termall` / `iCloud.com.ruohai.termall` 保留，云数据不自动迁移。上述新标识保存在 `apple/project.yml` 与两端 Entitlements。

Debug/Release 使用 Automatic Signing；Debug 为 Development，Release 为 Production CloudKit 环境。macOS 保留 App Sandbox、Outgoing Connections、用户选择文件读写权限；未开启 Incoming Connections。

macOS 仅支持 Apple Silicon（M 系列），Rust/Swift 和打包均为 arm64，不提供 Intel 或 Universal Mac 产物。配置检查和 `scripts/verify.sh` 会分别核对设置与实际架构。

## Local 配置及旧开发数据

`Local` 配置仅用于不具备 CloudKit 权限的本机验证，保留原 Bundle IDs `local.SSHClient.macOS` / `local.SSHClient.iOS`，ad-hoc 签名、macOS 沙盒和原有 Keychain service。所有本地构建/SSH 测试脚本显式选择 Local，避免无描述文件时误启动 CKContainer 或影响已有本机验收。

正式 Bundle 和旧开发 Bundle 的应用容器、UserDefaults 与 iOS Keychain 访问组彼此独立。两者可以保留；本次不会删除、复制活动 SQLite 文件、合并沙盒或导出旧凭据。旧本地数据继续可在 Local 中访问，V1 → V2 → V3 迁移由 SwiftData 完成。切换正式身份后不能声称旧沙盒数据自动迁移；需要保留的主机配置应通过明确的数据迁移方案另行导入，密码/私钥在新身份下重新输入。不要直接覆盖旧 store 文件。

## 仍需在 Xcode / Apple 后台完成

1. 使用有权访问上述团队的 Apple Developer 账号登录 Xcode → Settings → Accounts。获取有效 Apple Development 签名身份和对应描述文件；本机初查有效身份为 0，不能把配置标识当作签名成功。
2. 打开 `apple/ConnDock.xcodeproj`。两个 App Target 均选择真实 Team、Automatic Signing 和同一新 Bundle/Container；核对新 App ID 的能力关联及各平台的匹配描述文件。
3. 在 Signing & Capabilities 核对 iCloud → CloudKit，以及 `iCloud.com.ruohai.conndock`。macOS 核对沙盒出站权限。对 Debug 构建和至少两台已登录同一个测试 Apple ID 的设备运行；Local 构建明确不进行云端操作。
4. 先在现有 Container 的 Development 环境用签名 App 保存专用测试配置，通过 encryptedValues 生成字段，再在 CloudKit Console 核对 `SSHClientConfigV1`。`payloadV1` 必须为加密 Bytes，而非普通 Bytes/String；recordName 仅为 `h-UUID` 或 `g-UUID`。敏感配置没有明文字段、查询索引或 CKReference。不能将已存在的普通字段原地转换为加密字段。
5. 完成下述真实验收后，再把 Schema 部署到 Production，检查 Release 描述文件权限并验收。不要把 Development 数据误认为 Production 已有数据。

## 同步行为

- 默认关闭，首次在设置启用前展示准确上传范围。只同步主机非机密配置、分组、标签和收藏；密码、私钥、Keychain 引用、主机信任、终端内容、传输、语言/外观和最近连接不上传。
- 白名单文档整体放入 `CKRecord.encryptedValues["payloadV1"]`，字段不支持服务端索引/排序；本实现使用 Zone 增量变更，不用敏感值查询。参考 [Apple encryptedValues](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)。
- SwiftData 不开启自动镜像。主机变更与 outbox 同一提交；CKSyncEngine 状态跨启动持久化。参考 [Apple CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)。
- 前台启用时先核对账号并 fetch，再 send；局部修改后自动调度，网络失败使用 5–300 秒退避，空闲前台约 60 秒检查。退后台取消当前轮次，回前台继续，不承诺后台即时复制。
- 冲突选择完整记录的逻辑版本，设备 UUID 破同版本平局；删除优先，不按设备墙钟猜测。删除主机使用不含地址等内容的 tombstone；不自动过期删除标记，避免长期离线设备复活旧数据。
- 账号变化、其他设备删除整个 Zone 后暂停并保留本地，再启用须确认范围。独立的“删除 iCloud 配置副本”删除当前用户本应用 Zone，并关闭本机同步；在其他设备重新启用仍可能重新上传其保留的配置，界面明确说明。

## 真实云端验收清单（未执行不得勾选）

- [ ] 两平台签名、应用实际 entitlements、同一 Container/环境一致，分别用系统 Apple ID 登录。
- [ ] A 开启后创建带中文、备注、分组、标签的主机，B 开启后 UUID/字段一致且无重复。
- [ ] A/B 各修改、并发编辑、修改/删除并发，最终收敛；删除分组不删除所属主机。
- [ ] A 断网编辑并重启，网络恢复后自动同步到 B；关闭同步后 A 本地仍可编辑。
- [ ] 用户未登录、限制账号、配额不足、断网、服务器错误均有明确状态。
- [ ] 更换系统 Apple ID 后不自动把旧账号状态或配置上传到新账号；本地保留，重新确认启用。
- [ ] 只在专用测试数据上确认删除云端副本，其他设备暂停并保留本地；再次启用的影响与文案一致。
- [ ] CloudKit Console Schema 确认字段加密；数据库中没有密码、私钥或 Keychain 引用。B 连接仍要求输入凭据及主机验证。
- [ ] iPhone/iPad 真机前后台、系统签名和 Production Schema 验收。

自动化 Mock 测试只验证产品同步逻辑和两个独立本地数据库，不能勾选以上真实 CloudKit 步骤。
