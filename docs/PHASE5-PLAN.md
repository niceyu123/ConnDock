# Phase 5 — macOS AI/MCP 接入设计与执行记录

依据唯一任务书 `requirements.md` 第 10/14 节；用户 2026-10-27 明确授权继续 Phase 5。原 Phase 4 真实 CloudKit 验收限制继续保留。本阶段不进入 Phase 6。

## 设计选择

- Rust 官方 rmcp stdio helper，嵌入 `SSHClient.app/Contents/Helpers/SSHClientMCP.app/Contents/MacOS/sshclient-mcp`，由 Xcode 构建脚本使用当前身份签名；仅 arm64。stderr 只输出固定诊断，stdout 只供 MCP。
- 比较 XPC 与 Unix domain socket：外部 MCP 客户端启动 CLI 的方式不具备 App 内部 XPC service 的自然生命周期；选择 0700 私有目录、0600 Unix socket，双向核验当前 UID、内核提供的 PID 和实际代码签名。主 App 校验嵌入 helper 的 designated requirement；helper 校验同一 bundle 的主 App。无配对令牌、无 HTTP、无数据库直读。
- App 是唯一授权方：默认关闭且主机/工具白名单为空；设置、审计属于本机偏好，不进 CloudKit。打开开关前展示首次启用说明，用户逐主机/工具授权。
- 6 个工具：list_hosts/get_host_info/get_server_metrics/get_service_status/sftp_list/ssh_exec。输入只接受 Host UUID，不接受认证材料或替代地址。服务名白名单精确匹配；SFTP 要求绝对目录白名单、规范化与 realpath 后复核，拒绝敏感目录和 symlink 逃逸。
- 每次远程请求建立独立 SSH 会话，使用现有 Keychain 和既有 HostTrustStore；未知/改变的主机指纹不自动接受，需在普通 SSH 界面先验证。不会复用交互终端。
- ssh_exec：完整目标、用户名、原始命令、超时、输出上限、经签名验证的 helper 来源；每个请求独立一次性批准，默认拒绝。命令最多 8192 UTF-8 字节；超时 1–60 秒；stdout/stderr 合计最多 65536 字节并明确裁剪。拒绝、锁屏、超时、退出、撤销均不执行未批准命令。
- 最多 4 个在途请求；IPC 请求最多 65536 字节，响应最多 1048576 字节；有界 framing 和读写期限。helper 取消/断开传到 App，App 取消 UniFFI operation 并关闭独立 SSH。
- 审计最多 200 条，仅工具、目标 UUID、时间、结果码、耗时与命令 SHA-256；不保存参数、命令明文、路径、输出或凭据。远程内容仅作为不可信结果返回，服务端不解释为工具调用。

## 实施任务与接口

- [x] Rust 安全执行：`SshSession::execute_command(command, timeout_seconds, operation) -> CommandOutput`；`service_status(service_name, operation) -> ServiceStatus`；`SftpClient::list_authorized_directory(path, allowed_roots, operation)`；UniFFI 使用对应 snake_case / Swift camelCase。测试拒绝注入、限时/输出、取消、目录逃逸。
- [x] Rust `crates/mcp-server`：rmcp 锁定版本，6 个精确 schema，严格参数校验，Unix socket framed JSON，双向签名/UID/PID，stdio/取消/固定错误；单元与协议测试。
- [x] Swift `Features/AIIntegration`：MCPPolicy、MCPService、MCPRemoteExecutor、MCPIPCServer、MCPSettings、MCPApprovalView；绑定 WorkspaceState，macOS 条件编译；测试默认拒绝、不可见主机、参数绑定、撤销/锁屏/取消、日志保护。
- [x] 构建集成：仅 macOS 嵌入及签名 helper，新增网络 server sandbox entitlement 支持 Unix socket；不改变 iOS 发布逻辑。生成项目、绑定和 XCFramework 走既有脚本。
- [x] Local 本机验收（正式签名/沙盒待补）：cargo fmt/clippy/test、String Catalog、Swift format、scripts/verify.sh；真实本机 OpenSSH/Linux fixture、MCP stdio、Mac UI 审批、签名/沙盒/arm64；Codex CLI 可用时通过隔离配置实测，明确区分协议直连与 Codex。

## 关键复核项

1. 改主机、改工具或目录权限、关闭 MCP、锁屏时，已批准或排队请求也必须失效。
2. SFTP `/allowed-other` 前缀与 `..`、symlink 不能越过授权；禁止将远程服务名当作 Shell 片段。
3. 客户端断开、长输出、超时与慢半包不得留下无限任务/缓冲。
4. 代码签名不得仅凭客户端自述名称或同 UID 通过；Local ad-hoc 与正式签名验收要分开。
5. 不把凭据/命令/输出落日志或配置，不因远程提示注入执行额外操作。

## 执行约定与环境

仓库无首次提交，各阶段全为未跟踪文件；为保护现有工作，在原目录增量实现，不为 worktree 创建全仓初始提交。设计和计划用于进度记录，按用户自主执行约定不形成新的审批检查点。安全行为先有失败测试，再实现和验证。实现与审查允许按独立 Rust / Swift 边界分工。

本机 Xcode 27.1 / Swift 6.4；Rust 位于 `$HOME/.cargo/bin`。发现可用 Apple Development 身份，但需核验它是否属于 Team 86HC8YA388；存在身份不等于正式配置签名成功。真实 CloudKit、Mac App Store 分发、最低系统/物理设备验证均不能推断通过。


## 实施调整及已验证证据

- 实际探针确认独立沙盒无法跨主 App 私有容器访问 UDS，裸 CLI 沙盒也不能直接替代 App-like wrapper；正式配置改为独立 helper wrapper + 专用 macOS Team App Group。Local 保留沙盒主 App与 ad-hoc 诊断 helper，正式沙盒能力不据此推断通过。证据 `build/phase5-sandbox-probe/RESULTS.md`。
- FFI 生成检查实际捕获漏导出的 listAuthorizedDirectory，修复后新增 `apple-ffi/tests/check-swift-bindings.sh` 并纳入 verify；不手改生成物。
- 审阅收紧授权根：REALPATH 必须与用户允许的规范绝对目录一致，禁止授权根被符号链接重新指向其他树；测试先复现后修复。Docker bind mount 的变更需先通过独立 SFTP 查询观察到，再验证权限结果。
- 自动化凭据读取单独使用禁止系统认证 UI 的 Keychain 查询，未知 CredentialStorage 实现默认拒绝，不回退交互读取。
- `scripts/check-cloudkit.swift` 已更新为 macOS MCP UDS/App Group 范围，继续拒绝 iOS 启用这些权限。
- 已通过真实签名 Local helper + Mac App + 隔离 Linux SSH + Codex CLI 的 list_hosts / get_server_metrics；Codex 使用临时参数和 ephemeral 会话，不更改全局配置。完整日志见 `build/phase5-codex.log`。
- 保留限制：当前独立 SSH 会话仍先建立既有 PTY/shell 登录流程，禁止 PTY / 仅 SFTP 的账号不承诺支持。无终端认证模式作为后续独立改进，本阶段不重构既有会话生命周期。
- 原仓库无首次提交；保持原目录与既有工作，未提交或推送。最终验证结果见 `PHASE5-VALIDATION.md`。
