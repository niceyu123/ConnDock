# Phase 4 复核记录

日期：2026-10-27。按 `requirements.md`、用户补充和 `PHASE4-PLAN.md` 对明确的 Swift/工程/脚本范围执行作者只读复核；不是独立第三方安全审计。仓库尚无首次提交，不虚构 base/head diff，也不读取测试秘密。

## 已确认和处置

1. V1 主机表保留，队列/状态与标签分别为新增版本表；实际 V1 磁盘迁移测试验证 UUID、凭据引用与默认关闭状态。
2. 同步白名单和 CKRecord 使用独立文档，credentials/trust/preferences 没有编码路径；实际 CKRecord 测试拒绝明文 payload 和不匹配 ID。
3. 主机保存与 outbox staging 同一提交；人为制造重复 journal 的失败测试验证整次本地编辑回滚。旧 ACK 和离线删除测试验证新版本保留与不复活。
4. 账号变化发生在 Keychain 等待期时，最初无法持久关闭同步；先复现失败，允许停用动作在等待期提交同步元数据，完整测试通过。
5. 运行 token 隔离晚到回调；Disable 后收到状态 token 的测试必须抛错，保留本地行和持久状态。
6. 自定义 Local 配置使 SwiftPM 未启用 testability 并额外尝试 x86_64 模拟器 Package Product；验证命令显式设置 testability 与 arm64，继续保持现有 XCFramework 的架构边界。
7. XcodeGen 对嵌套 TargetAttributes 的 SystemCapabilities 输出字符串，移除该不正确的展示项，实际能力由两平台 Entitlements 和 Automatic Signing 定义。生成物由 XcodeGen 重建。

## 最终补充处置

- Sign-out 预检查改为与账号切换一样持久关闭；Local 不恢复旧的开启状态。旧 V1 中允许的内部制表符分组名继续可读。3 项回归已在 `phase4-final-policy-red.xcresult` 复现，最终统一验证通过。
- 删除云端 Zone 后长期离线设备可能没有有效删除 token。新增 Mock 回归先失败，再让 transport 在已确认存在的副本缺失时停用，不直接重新创建。测试证据为 `phase4-zone-delete-red.xcresult` 与最终统一验证。
- 同步生命周期提升到 App 聚合的 scenePhase，避免 macOS 打开设置窗口时受主工作窗口状态影响。SDK 的 Scene.onChange 签名已核对并通过两平台编译。
- 实际截图中用于挂载确认框的 `Color.clear` 在 Form 内产生空白灰色行；确认框改挂真实 Toggle/Button，重新运行三端 UI 与原始截图。
- 最终截图还发现 iPad 的设置 Sheet 已呈现时外观未更新。`phase4-settings-theme-red.xcresult` 以真实 UIViewController trait 复现 light 未变 dark；SettingsScreen 自身显式绑定 locale 和 preferredColorScheme。最终统一测试包含此回归，重新拍摄后的图片才作为交付。
- 用户新要求正式放弃 Intel macOS，构建与需求改为 arm64；架构检查先拒绝旧 Universal slice，重建后检查三个 slice 和两 App Mach-O 均为 arm64。

## 验收边界

- 只有 Local/Mock 的结果不能证明正式 CloudKit、两设备或 Production 数据行为。真实签名构建已尝试，缺少证书/描述文件；具体手动步骤与未执行清单保留。
- macOS、iPhone、iPad 图像必须为成功结果中的原始运行附件，注明是 Local 未签云权限状态。
- 正式身份和旧开发身份的沙盒/Keychain 组独立；不导出凭据、不复制活动 SQLite、不自动跨身份合并。独立迁移是明确的后续条件。
- 仅前台自动同步，不宣称后台即时同步；完整记录冲突与删除优先是已公开的取舍。
