# Phase 5 独立复核与处理

本阶段依据 `requirements.md` 第 10/14 节。首次独立设计复核查验了 Apple 官方文档，并用一次性 ad-hoc wrapper 实际探测 sandbox / Unix socket / App Group，记录在忽略的 `build/phase5-sandbox-probe/RESULTS.md`。

独立实现审阅已返回下列具体问题；审阅会话随后受工具账户额度限制中断，未生成完整最终报告。不能将其称为完整独立安全认证。以下修复由主实现者核查实际源码、补测试并验证。

| 问题 | 处理 |
|---|---|
| 允许根的 REALPATH 每次重新解析，根被替换为 symlink 后会扩大范围 | 根必须与规范路径相同；单元和真实 OpenSSH/Linux 回归先失败后修复 |
| 自动化 Keychain 查询允许系统弹框，可能阻塞审批/超时 | 专用非交互查询使用 kSecUseAuthenticationUIFail；协议缺省拒绝；验证不会回退交互读取 |
| 旧 CloudKit 配置检查禁止 macOS network.server | 更新为本阶段 UDS 所需权限，并继续确保 iOS 不请求 MCP group/listener |
| MCP 沿用普通登录的 PTY/shell 前置流程 | 本轮保留已验证会话生命周期，明确限制不支持禁止 PTY / 仅 SFTP 账号；后续可独立设计无终端认证模式 |

此外主实现者在整合中发现并修复 FFI 导出遗漏、测试 stdio Foundation 阻塞读取、Swift actor 非交互方法与默认协议重载选择、UI 测试把原生 Switch 当作 CheckBox 等问题。它们的失败日志保留在 `build/phase5-*`，最终成功记录与未验证项见 `PHASE5-VALIDATION.md`。

上游签名限制仍存在：正式 helper 需要真实 Team 私钥使用授权、App Group 能力、描述文件及 Archive/Export 验收。Local 的完整链路证明功能和身份校验，不代替正式沙盒或 App Store 资格。
