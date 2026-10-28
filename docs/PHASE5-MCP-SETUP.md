# Phase 5 — MCP 配置和安全边界

唯一需求见 `requirements.md` 第 10/14 节。本阶段只面向 Apple Silicon macOS；iPhone/iPad 不运行 helper、不增加 App Group，也不修改其发布身份。

## 使用

1. 打开 SSHClient，先使用普通 SSH 连接核验目标指纹，并按需保存凭据到本机 Keychain。MCP 不会自动接受未知指纹，不导出密码或私钥；自动化读取 Keychain 明确禁止弹出认证框，不可读取时直接报错。
2. 设置 → AI 工具接入，阅读范围说明后启用 MCP。默认关闭；初始没有任何主机或工具权限。
3. 展开需要访问的主机，逐个选择工具。目录与服务默认空，分别输入允许的真实规范绝对目录（授权根及其父级不能是符号链接）和 systemd 服务（每行一个），点保存。修改主机身份会使旧授权失效。
4. 点“测试本地连接”，将通过真实签名 helper 的 `--check` 模式连接主 App；不是假模拟或远程连接测试。
5. 使用页面生成的命令在可信任的 Codex CLI 运行；该命令使用当前 App 的实际路径和 socket。移动或重建 App 后可能需要更新配置。应用不会自动修改外部客户端配置。
6. Claude Code / Cursor 等客户端使用 stdio，程序指向 `SSHClient.app/Contents/Helpers/SSHClientMCP.app/Contents/MacOS/sshclient-mcp`，参数为 `--socket` 和页面生成的绝对路径。不要配置 HTTP URL。

`ssh_exec` 每次显示目标、端口、用户名、完整命令、执行超时和输出上限；核对后勾选并单次批准。拒绝或 60 秒未批准不执行。helper 的签名可验证，发起它的 AI 客户端名称并不因此获得认证。只配置自己信任的客户端。

## 工具

| 工具 | 权限和返回范围 |
|---|---|
| list_hosts | 只显示至少获一项工具权限且身份匹配的主机 UUID、别名、分组 |
| get_host_info | 需明确授权；非秘密连接元数据和可用工具，不返回 Keychain 引用/认证材料/备注 |
| get_server_metrics | 固定 Linux 采集器，两次采样产生 CPU/网络速率；独立 SSH 会话 |
| get_service_status | 仅精确允许的 systemd 服务，固定属性读取，不拼接自由 shell 片段 |
| sftp_list | 仅允许的绝对目录，规范化与 REALPATH 复核；敏感目录和稳定 symlink 逃逸拒绝 |
| ssh_exec | 每条任意命令必须在 Mac App 单次确认；精确参数绑定，不复用交互终端 |

所有远程文本都是不可信数据，helper 不解释文本中的指令，也不自行追加工具调用。输出中可能有敏感内容，批准前应考虑会返回给请求方。SFTPv3 不提供原子 openat/no-follow；不能承诺抵御恶意远端伪造协议或极端并发路径置换。

## 限制与撤销

最多 4 个请求；命令最多 8192 UTF-8 字节；执行期限 1–60 秒（默认 20）；stdout/stderr 合计 64 KiB，超限后明确裁剪、关闭通道并不伪造退出码。IPC 有长度、时限与连接数量限制；无 HTTP 监听或产品云端依赖。

关闭 MCP、撤销主机/工具、锁定、退出或客户端取消会取消等待审批、调用和独立 SSH 连接。已发送的远程命令可能继续运行，关闭通道不等于保证杀死远端进程。日志最多 200 条，仅工具、主机 UUID、时间、耗时、结果码、命令 SHA-256，不保存命令明文、路径、输出或凭据。

## 签名、沙盒与发行

helper 是单独 `.app` wrapper 中的 Rust stdio 可执行文件，由 macOS 构建脚本嵌入并在主 App 签名前签名。使用 wrapper 是因为本机探针的裸沙盒 CLI 在 main 前失败；不使用 `com.apple.security.inherit`，外部 Codex/Terminal 并非已沙盒 App 的子环境。

- Debug/Release：主 App 和 helper 使用 Team `86HC8YA388`；macOS 专用 `86HC8YA388.com.ruohai.termall.mcp` App Group 只放私有 IPC socket，不放 SwiftData、凭据或终端数据。helper 自身启用 App Sandbox、network.client、该 group，不启用 Keychain Sharing、云服务、inherit 或宽松库加载。
- Local：保留 `local.SSHClient.macOS`，主 App 仍沙盒化；helper 使用 ad-hoc 签名、无自身沙盒 entitlement，以验证本机功能。它连接主 App 私有容器的 0700 目录/0600 socket；仍执行双向签名和内核 audit token 身份验证。这不是正式 helper 沙盒验收。
- 主 App 为 Unix socket 增加 network.server entitlement，功能默认关闭且未启用时不监听；不启动 HTTP。每个连接核验 UID、audit token、预期主程序路径、代码签名及封装包，不因客户端自报名称获信任。
- Xcode 的 macOS shell build phase 需运行 Cargo，单独关闭该 target 的 User Script Sandboxing；这不关闭 App Sandbox，也不改变 iOS target。

本机已检测到属于正确 Team 的 Apple Development 证书；私钥访问和描述文件、App Group 授权、Archive/Export、App Store 可行性仍需真实验收。正式配置失败时不得用 Local 结果声称发行已通过。Phase 4 真实 CloudKit 验收继续按 `PHASE4-CLOUDKIT-SETUP.md` 独立完成。

## 上游依据

- [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [官方 Rust rmcp 3.8.0](https://docs.rs/rmcp/3.8.0/rmcp/)
- [Apple 嵌入辅助程序](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- [Apple DTS：Nothing to Inherit](https://developer.apple.com/forums/thread/706390)
- [Apple DTS：App Groups on macOS](https://developer.apple.com/forums/thread/721701)

当前自动化连接仍沿用已验证的 SSH 登录/PTY 建立流程；仅允许 SFTP、禁止 PTY 或禁止 shell 的受限账号不在本轮成功验收范围，后续可独立增加无终端连接模式。
