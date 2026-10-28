# ConnDock MCP Helper

macOS Apple Silicon 专用 MCP stdio 辅助程序。使用官方 `rmcp = 3.8.0` 的 `ServerHandler`、`ServiceExt`、`AsyncRwTransport`，只启用 `server` 与 `transport-io`；不启用 HTTP、认证服务器或云端传输。Helper 不依赖 SSH Core、SwiftData、CloudKit 或 Keychain；所有实际授权和远端操作由正在运行的 ConnDock App 执行。

发布时嵌入 `ConnDock.app/Contents/Helpers/ConnDockMCP.app/Contents/MacOS/conndock-mcp`。配置由 App 生成：

```text
conndock-mcp --socket ABSOLUTE_SOCKET_PATH --app ABSOLUTE_OUTER_APP_PATH
```

`--app` 可省略，省略时根据自己的嵌入位置推导；显式传入时，规范化路径必须仍指向同一个外层 App。不能用该参数信任其他 App。`--check` 可置于任意参数位置，使用同一签名验证与 IPC 机制调用 `list_hosts`，5 秒内返回固定 JSON（成功 `{"ok":true}`，失败只含错误码）和对应退出码，不打印主机数据。普通模式 stdout 只用于 MCP；stderr 只有固定诊断，不输出底层错误、路径、参数或数据。

## 输入与权限

仅暴露 `list_hosts`、`get_host_info`、`get_server_metrics`、`get_service_status`、`sftp_list`、`ssh_exec`。所有 schema 都有 `additionalProperties:false`，Rust 参数结构同时使用 `deny_unknown_fields`。只接受稳定 Host UUID。命令保持原始内容，最多 8192 UTF-8 字节，只允许 LF/TAB 控制字符并拒绝 bidi 控制字符；`timeout` 必须为 1–60 的整数，省略时明确补为 20。服务名只接受有界 systemd 单元名字符，路径必须为有界绝对路径并拒绝点路径和控制字符。精确服务白名单、目录 realpath/敏感目录、凭据、已验证主机身份与命令逐次审批继续由 App 独立检查。

返回 `structuredContent={"untrusted_data":true,"data":...}`，初始化 instructions 明确将主机名、目录、服务与命令输出当作不可信数据。Helper 只返回 App 的数据，不解释其中的指令，也不会根据返回内容自行发起其他调用。工具失败返回 `isError:true` 和结构化 `error.code`；App 自由文本错误 message 被丢弃。

## IPC 与身份

每个工具调用使用单独 Unix domain socket：4 字节无符号大端长度，随后 UTF-8 JSON。请求为 `{"version":1,"id":"UUID","tool":"name","arguments":{...}}`；响应为 `{"ok":true,"data":...}` 或 `{"ok":false,"error":{"code":"UPPER_CASE_CODE","message":"optional"}}`。错误码最多 64 个 ASCII 大写字母、数字或下划线。请求最多 65536 字节，响应最多 1048576 字节，在分配响应正文前检查长度。每个 Helper 最多 4 个在途工具调用，连接 5 秒、写入 10 秒、单次调用总计 180 秒。MCP 取消或 stdio EOF 会关闭该调用唯一的 socket；App 需要观察 EOF，取消审批与独立 SSH 任务。

socket 必须为当前 eUID 所有的 0600 Unix socket，其直接父目录必须是当前 eUID 所有的 0700 真实目录；不限定为主 App 容器，允许显式配置的专用 App Group 目录。身份核验使用系统 `getpeereid`、`LOCAL_PEERPID`、`LOCAL_PEERTOKEN`。PID 和 audit token 的 UID/PID 必须一致，`proc_pidpath` 必须精确匹配外层 App 的 `Contents/MacOS/ConnDock`。通过 Security.framework 严格验证外层 App 的资源与嵌套代码，从它取得 designated requirement，再用 kernel audit token 定位运行进程并执行 `SecCodeCheckValidity`。audit token 携带进程 incarnation，防止 PID 复用。Helper 自身的运行签名和父 App 必须同 Team；仅双方均 ad-hoc 时接受 Local 诊断。不会为了通过验签降级为仅检查同 UID。

Apple FFI 集中在 `src/identity/macos.rs`，每个 CF Create/Copy 对象均有 RAII 释放。无第三方签名包装库，不启动 `codesign` 子进程验证生产请求。测试中的 `codesign -s -` 仅为临时合成 App 创建本机 ad-hoc 签名。

## 验证范围

```sh
cargo fmt --package conndock-mcp --check
cargo clippy --package conndock-mcp --all-targets -- -D warnings
cargo test --package conndock-mcp
```

测试包含严格参数、帧大小、半包期限、取消、4 请求上限、真实 rmcp JSON-RPC 生命周期、恶意远端文本仅作为数据、真实签名 App 子进程身份与同 UID 假冒者拒绝；`tests/stdio.rs` 实际启动嵌入式 Helper 并通过进程 stdin/stdout 完成 MCP 初始化、列工具和合成 App 请求。可信连接器替身仅存在于测试模块，没有生产 bypass 参数。

这些测试使用合成 App 和数据，不能代替真实 SSH、用户审批、正式 Team 签名、App Group 沙盒或 Codex 客户端端到端验收。构建脚本和主 App 的身份验证、撤销、审批及实际 SSH 验收由外层项目负责；Local ad-hoc 诊断不代表正式 App Store 分发已获验证。

## 上游资料

- [rmcp 3.8.0](https://docs.rs/rmcp/3.8.0/rmcp/)，实现同时核对该固定版本 Cargo registry 中的实际源码。
- [官方 Rust MCP SDK](https://github.com/modelcontextprotocol/rust-sdk)
- [MCP stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [SecCodeCopyGuestWithAttributes](https://developer.apple.com/documentation/security/seccodecopyguestwithattributes(_:_:_:_:))
- [SecCodeCheckValidity](https://developer.apple.com/documentation/security/seccodecheckvalidity(_:_:_:))
- [SecStaticCodeCheckValidity](https://developer.apple.com/documentation/security/secstaticcodecheckvalidity(_:_:_:))
- [Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

常量及 ABI 还核对本机 macOS SDK 的 `sys/un.h`、`bsm/libbsm.h`、`Security/SecCode.h`、`Security/SecStaticCode.h` 与 CoreFoundation 头文件。
