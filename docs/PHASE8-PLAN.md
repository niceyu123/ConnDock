# Phase 8：连接与认证增强

依据用户继续开发授权，保持既有架构、逐目标信任、凭据本机 Keychain、默认关闭 MCP 和 arm64 范围。实现后运行验证并提交、合并到本地 main，不自动推送或分发。

## 实现顺序

1. Rust 将 transport-only 与交互 PTY 模式分开；通过认证但不请求 shell 的 transport 支持 SFTP、exec、监控及 direct-tcpip。MCP 使用 transport-only。
2. 单跳跳板机选择已保存的直连主机。跳板机与最终目标分别认证和校验指纹，缺凭据/信任不降级直连；关闭最终连接释放其独占跳板连接。
3. keyboard-interactive 提示有界、带请求 ID 和原始目标，逐轮交互；支持密码/密钥成功后的 MFA，取消/后台/关闭拒绝迟到结果，答案仅在内存使用。
4. macOS Agent 通过用户明确选择的本机 socket 及公钥 SHA256 指纹签名，不转发 agent，不读取私钥；iOS 不提供该方式。保留沙盒，提供容器内专用 socket 和手动启动说明；容器外 socket 被系统拒绝时明确报错。Local 沙盒已验证的路径与正式签名验收分别报告。
5. SwiftData 新增非机密连接选项实体及 V4 迁移，不改旧 schema 的 StoredHost 结构。加密同步文档扩展为 schema 2 承载新连接语义，旧客户端明确拒绝未知版本；缺失跳板配置不可自动直连。
6. 表单、中英文提示、MFA sheet、文件模式空状态和生命周期适配。固定依赖，不改手写 FFI 生成物。

## 验证

- 先补 Rust 模式/交互响应测试和真实 SSH 集成，覆盖无 PTY、跳转、目标指纹拒绝、MFA 多轮/错误/取消与 Agent。
- Swift 覆盖 V3→V4、同步选项、缺跳板/环路/迟到凭据、MFA sheet 目标和会话约束。
- scripts/verify.sh，适当真实 Linux/SSH、两平台 arm64 与三端 UI。
- 标明跳过、环境限制、正式沙盒/物理设备/云端未验收，不将其算作通过。
