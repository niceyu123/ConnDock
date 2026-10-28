# Phase 6 — 安全、稳定性与发布准备

依据唯一任务书 `requirements.md` 第 10/11/12 节，用户已明确授权继续 Phase 6。本阶段不新增 P1/P2 产品功能，不发布或上传 TestFlight；保持已有用户图标和 SSHClient 开发名称。

## 设计及范围

- 沿用 SwiftUI / SwiftTerm / Rust / UniFFI 及已有存储、安全、同步和 MCP 边界；不替换框架、不增加运行时依赖。macOS 和 Apple 库只支持 arm64。
- iOS/iPadOS 真正进入后台后暂停终端输入和不必要的采集；恢复前台以受限、无命令的 SSH channel 探测确认连接，再恢复输入。失败关闭连接并提供既有手动重连入口，不保存或自动重放输入，不自动恢复凭据认证。macOS 仅失焦不应断开会话。
- 比较后台后立即断开与前台检查后保留连接：选择后者，保留短暂切后台的可用会话，检查仅打开并关闭独立已认证 channel，不运行远程命令。
- 所有后台验证、关闭、断线、tab 释放和过时事件均使用可取消 operation/代次保护；测试弱引用释放、并发标签及远程断开后的恢复。真实长连接/循环 channel 测试限定已有隔离 OpenSSH/Linux fixture，记录持续时间与峰值内存，不把短时间通过称为长期无泄漏证明。
- 设置补充本地数据/凭据、可选 CloudKit、MCP 外部客户端、日志和后台策略的中英隐私文案；关于页使用真实版本与 build，不将 Local 形态称为正式发行。
- 按 Apple 当前官方资料增加主 App/helper 隐私清单及用途说明；不擅自认定内嵌 SSH 加密出口豁免、不填写虚构隐私政策 URL。
- 准备可重复、仅本地的 Release archive / export 配置和检查：Bundle/Team、签名/profile、helper/group/沙盒、arm64、图标、隐私资源、版本与发布材料。未签名编译可以独立验证，但发行检查必须拒绝 Local、ad-hoc、缺 profile 或未完成加密声明。

## 执行任务

- [x] 先增加后台恢复、关闭与陈旧事件失败测试；实现 Rust 无命令连通性探测及 UniFFI 出口、Swift 终端恢复状态与平台生命周期接线。
- [x] 增加真实多标签/长连接/channel 循环/取消释放专项与固定运行脚本，记录资源边界；补 Keychain 权限/身份校验回归。
- [x] 隐私说明、App/helper PrivacyInfo、真实版本信息及两种语言/外观；已有用户图标只验证，不另造品牌。
- [x] 发布预检、归档与本地导出脚本及自动测试，TestFlight 准备说明、人工验收矩阵和未验证项。
- [x] 统一 verify、真实隔离集成、三端 UI、Release 设备构建/归档能运行的部分；核实正式签名的当前限制，形成 PHASE6-VALIDATION。

完成标记表示本机实现、检查及未验证项记录齐备，不表示 App Store、真实 CloudKit、正式 helper 沙盒或真机验收完成。具体命令与结果见 [PHASE6-VALIDATION.md](PHASE6-VALIDATION.md)。

## 测试重点

1. 已关闭标签不能被迟到 connected/output 事件重新激活或保留 native view。
2. 应用后台恢复期间不接受/重放输入；验证失败显示可重连状态，取消后迟到成功无效。
3. macOS 失焦与 iOS 真正后台区分；多个 tab 都恢复，失效 tab 不影响其他有效连接。
4. 新归档不得把 Local/ad-hoc helper、测试配置或缺失隐私清单伪装为可发布。
5. 当前环境的 profile、CloudKit、多设备、systemd、最低系统与物理设备限制如实保留；人工清单不预勾未执行项。

## 工作区与交付约定

当前仓库尚无首次提交，前序阶段均为未跟踪文件。继续在现有目录增量实现，保留无关工作，不为创建 worktree 而提交全仓。不自动提交、推送、修改 Apple 门户或上传构建。设计和计划是进度记录，按用户自主执行约定不设置额外审批检查点。
