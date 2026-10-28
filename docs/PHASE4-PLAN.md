# Phase 4：iCloud 同步执行计划

> 按 `requirements.md` 和用户授权在当前工作区实施，保留既有未提交成果。使用 executing-plans 流程顺序实现与验证；本阶段不提交 Git、不进入 Phase 5。

目标：本机 SwiftData 保持权威，CKSyncEngine 复制非机密主机和分组到 CloudKit 私有库。默认关闭、可手动启停、离线恢复、冲突收敛和删除同步；关闭不删除本机配置。

## 环境与选择

- Xcode 27.1 / Swift 6；初查代码签名有效身份为 0。用户随后提供真实 Team `86HC8YA388`、Bundle `com.ruohai.termall`、Container `iCloud.com.ruohai.termall`，授权完成配置。两 App Target 的 Debug/Release 使用该 Bundle、自动签名与同一私有库，不创建第二个 Container；Local 配置保留旧 `local.SSHClient.macOS/iOS` 和沙盒，仅用于无云端权限的本机验收。身份/CloudKit Schema/真实签名仍须实际配置后验证。
- 采用任务书指定的 CKSyncEngine；不启用 SwiftData 自动 CloudKit 镜像，不新建后端或使用键值云同步代替。
- 新的加密 bytes 字段保存白名单化的 Codable 文档，主机地址、用户名、备注和分组名均在 `encryptedValues` 内。recordName 只含类型与 UUID，不放连接目标。禁止同步密码、私钥、Keychain 引用、主机信任、终端内容、会话、最近连接或设备外观。
- 同步不扩展终端设置范围：当前终端设置按任务书已作为独立设备偏好保存，首轮只同步主机/分组/标签。标签按用户最新补充加入独立本地扩展表和加密白名单，不修改已存在 V1 主机表定义；V1 → V2 队列 → V3 标签均为轻量迁移。
- 为保持账号与禁用边界，CKSyncEngine 采用手动调度，产品服务在前台启动、局部变更后及周期检查时执行 fetch → send，失败按退避重试；进入后台取消本轮。无需承诺后台即时复制。
- 冲突为整条配置的逻辑版本比较（持久递增计数 + 设备 UUID），删除标记优先，避免离线旧编辑复活已删配置。不按设备墙钟判胜负；同一记录不进行字段级合并。
- 账号变化或云端 Zone 删除时关闭同步、保留本地，重新启用前展示上传范围确认。不会把旧账号状态/系统字段带到新账号。

## 文件与接口

- `Shared/Models/CloudSyncModels.swift`：V2 轻量迁移，持久状态、每记录 outbox/系统字段，保持 V1 主机结构。
- `Shared/Storage/HostLibrary+Sync.swift`：本地原子入队、远端合并/确认；原 HostLibrary 只增加变更入口。
- `Features/CloudSync/SyncDocument.swift`：严格白名单、稳定 UUID、删除标记和有界验证。
- `CloudSyncTransport.swift`：传输协议/事件；`CloudKitRecordCodec.swift`：加密记录和系统字段。
- `CloudKitSyncTransport.swift`：实际 CKSyncEngine delegate、状态序列化、冲突和 CloudKit 错误映射。
- `CloudSyncService.swift`：默认关闭、账号绑定、调度、取消/重试和对 UI 的稳定状态；`CloudSyncSettings.swift`：双语原生开关、范围确认、状态、手动同步及独立的删除云端副本确认。
- `Tests/CloudSyncTests.swift` 与仅在测试 Target 的 `MockSyncTransport`：两个独立真实 SwiftData 存储验证协议与产品逻辑，不充当云端验收。
- `apple/project.yml` / 两端 Entitlements：直接配置用户已提供的正式标识；Local ad-hoc 配置隔离，默认 Debug/Release 保持真实自动签名。检查脚本核对 Target/Info/Entitlements，不能以源码一致代替实际签名。

## 步骤与验收

- [x] 先写并运行失败用例：加密字段/白名单、原子队列重开、过期 ACK 不清除新编辑、跨存储创建/修改/删除、并发编辑/删除收敛、账号切换与关闭保留、身份变更使本机凭据失效。
- [x] 实现文档、V2/V3 迁移与本地 journal/merge，重跑针对性测试。
- [x] 实现实际 CloudKit codec/engine 与服务；Mock 验证断网恢复、取消后迟到事件、失败不推进持久状态、云端删除需重新启用。另测 V1 磁盘迁移和凭据不出库。
- [x] 接入三端设置、生命周期、中英/浅深色及状态文案，运行 UI 与截图检查。
- [x] 实际运行统一验证，必要的 Phase 2/3 回归，执行只读复核，记录精确通过/跳过/环境限制。停止于 Phase 4。

## 执行记录

- `phase4-sync-red.log` 因新接口缺失失败；实现后 7 项持久/加密/合并用例通过（`phase4-sync-green-r2.xcresult`）。SDK 的 `allKeys` 包含加密字段名，测试改为核对所有应用字段均在 encryptedValues 中；认证方式的 password 枚举值不是密码字段，测试只检查编码 key。
- `phase4-service-red.log` 缺少服务/传输接口；实现后 5 项 Mock 服务与 7 项存储测试通过（`phase4-service-green-r1.xcresult`）。Mock 仅在测试 Target，不伪称真实 iCloud。
- 用户补充标签后先记录接口缺失失败（`phase4-tags-red.log`），再实现标签与 V1 磁盘迁移测试。
- Local 首次测试发现 SwiftPM 对自定义配置产物未启用 testability；错误为 module built without -enable-testing。验证命令显式传 `ENABLE_TESTABILITY=YES`，不改产品接口、不关闭隔离或跳过测试。
- 最终复核补充 sign-out 持久停用、Local 不恢复旧开启状态和旧分组名兼容性，先复现后修复；删除云端 Zone 后另一个设备不得静默重建的 Mock 回归也先失败再修复。真实 transport 在创建 Zone 前显式检查已确认的副本是否消失，不依赖尚未过期的删除 token。
- 用户明确放弃 Intel macOS 后，已更新唯一需求/AGENTS、Rust 目标、Xcode 架构与 XCFramework 构建。新增实际 Mach-O/slice 检查，旧 Universal slice 已被检查器拒绝；当前重建为三个 arm64 slice。历史阶段文档增加范围注记，不改写旧测试事实。

## 重点失败条件

1. SwiftData 提交失败不能留下“已同步”或被提前推进的云端 token。
2. 发送中再次编辑不能被旧 ACK 清队列；收到旧远端记录不能覆盖新本地值。
3. 关闭、换账号或退后台后的迟到事件必须被运行代号拦截。
4. 删除优先与分组引用乱序必须收敛；云端删除不得静默重新上传。
5. 新设备拿到配置后仍需本机凭据与主机验证；目标改变不能复用旧凭据。

参考已查询的 [Apple CKSyncEngine 示例](https://github.com/apple/sample-cloudkit-sync-engine)、[CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)、[加密字段](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)。API 另以本机 SDK Swift interface 复核。真实 CloudKit schema、签名、同账号两设备新增/修改/删除、真实断网与账号切换列入后续配置验收，不以本机 Mock 的绿色结果替代。
