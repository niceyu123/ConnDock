# ConnDock 内部命名统一（2026-10-28）

用户授权将 SSHClient 内部开发名称统一为 ConnDock。更新 XcodeGen 配置、Target/Scheme、Swift 模块/包/入口文件、可执行文件、Rust crate/库、UniFFI 配置、MCP helper、构建和测试脚本及当前说明文档。桥接生成代码和 XCFramework 通过既有脚本重建。

兼容标识继续保留：Local Bundle ID `local.SSHClient.*`、Application Support 下的 `SSHClient` 目录、Keychain 服务名、CloudKit 记录类型 `SSHClientConfigV1` 和 zone `SSHClientPrivateV1`。正式 Bundle ID `com.ruohai.conndock` 与容器 `iCloud.com.ruohai.conndock` 不变。历史阶段记录和原始导入需求文件保留原文。

已有外部 MCP 客户端配置需按照应用设置页的新 `conndock-mcp` 路径更新。

验证：

- `scripts/verify.sh` 的静态检查、437 key 中英文完整性检查、10 项 Python 测试、源码发布预检、Rust fmt/clippy/单元测试、真实 UniFFI 生成接口类型检查通过。Rust 依赖外部环境的 16 项测试按原设置 ignored。
- 三平台 arm64 Rust 库与 ConnDockFFI XCFramework 重建通过；macOS Local、iOS Simulator Local 构建与本地产物预检、arm64 架构检查通过。
- macOS 单元测试 75 项，5 项跳过，0 失败。
- 首次完整脚本在 iOS 外观测试失败：空工作区已经改为引导页，测试没有挂载终端；深色预期也仍是旧灰度值。修正测试夹具以直接挂载真实 NativeTerminalView，并按现有深色 RGB (24,24,37) 验证。
- 修正后使用相同 Local 配置和 iPhone 17 模拟器完整重跑 `ConnDockTests-iOS`：64 项，4 项跳过，0 失败。最终结果 `build/iOS-rename-final.xcresult`，日志 `build/ios-rename-final.log`。Swift 格式检查通过。
- 未运行 UI 测试、外部 MCP 客户端端到端测试、真实云同步、发行签名和 TestFlight 验收；这些不由 Local 构建结果替代。
