# Phase 2 macOS 补充验收

> 历史范围说明（2026-10-27 更新）：macOS 已正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）。文内原有 Intel/四架构构建结果仅为历史记录，当前构建和发布范围以 `requirements.md` 与现行脚本为准。

日期：2026-10-27（Asia/Shanghai）。本次只补齐 macOS 界面验收与浅色运行截图；不开发 Phase 3 的 SFTP 或 Linux 监控。

## 修正内容与原因

1. **连接表单缺少连接按钮。** 失败测试的辅助功能树实际包含“保存”，却没有“连接”；空表单与填写后的表单均可复现。macOS 的 `.confirmationAction` 工具栏分组没有同时呈现这两个操作。改用原生底部操作行，明确提供取消、保存、连接和相应快捷键；iOS/iPadOS 继续使用原生工具栏。原测试不降低断言，修正后能够找到两按钮，并完成保存、退出、重启检查。
2. **活动终端未暴露辅助功能输入区域。** SwiftTerm AppKit 视图默认不是 AX 元素，角色为 unknown。新增 textArea 角色和标识，并在连接成功时标记为可用；不通过 AX value 发布原始终端内容。SwiftUI 会将该原生视图合并到外层画布，因此 UI 测试使用最终的 `terminalCanvas.light/dark` 标识。原先沿用占位页的“当前未连接”辅助功能文案改为中性的中英“SwiftTerm 终端”。
3. **浅色截图改从实际运行窗口获取。** 原来 AppKit 离屏缓存未正确包含 SwiftTerm 的透明图层。本次通过真实 UI 流程连接 OpenSSH，再使用 XCUITest 对实际窗口截图，不反色、不重绘、不合成终端输出。常规截图明确选择 `workspace` 窗口。副显示器上曾出现系统图像创建失败，验收启动时会使用原生鼠标拖动把测试窗口放入主屏可见区域；不修改产品日常的窗口布局逻辑。
4. **明确控制测试媒体与配置。** 两个 Scheme 关闭自动截图/录屏，只保留测试显式选择的截图，避免私钥文件选择器预览被录制。UI 专项配置仅含本机测试端点、指纹和文件路径，没有私钥正文；Xcode 的沙盒 UI Runner 对外部输入只有读取权限，因此配置由拥有它的脚本按运行 UUID 清理，不扩展 Runner 权限。

## 实际通过的验证

| 检查 | 结果 | 证据 |
|---|---|---|
| 修正前连接表单复现 | 2 项失败；空表单无法取得连接按钮，保存流程在同一按钮查询失败 | `build/phase2-macos-acceptance-diagnostic-r1.xcresult`；`build/phase2-macos-ax-diagnostic/` |
| 修正后表单专项 | 2 通过：空表单导航、保存/退出/重启/语言与外观 | `build/phase2-macos-acceptance-buttons-r1.xcresult` |
| 最终常规 macOS UI 全套 | 6 通过，0 失败；包含终端 AX 与主屏测试窗口调整后的最终代码 | `build/phase2-macos-ui-acceptance-final.xcresult`；`build/phase2-macos-ui-acceptance-final.log` |
| 终端 AX 回归，修正前 | 1 项失败，实际发现 element=false、role=unknown、identifier 为空 | `build/phase2-macos-terminal-ax-red.xcresult` |
| 终端 AX 回归，修正后 | 1 通过，且 AX value 仍为 nil | `build/phase2-macos-terminal-ax-green.xcresult` |
| 真实 SSH 完整 UI 流程 | 1 通过，0 跳过 | `build/phase2-mac-ui-ssh-20261027-105734.xcresult` |
| 最终基础构建与测试 | `scripts/verify.sh` exit 0 | `build/phase2-macos-acceptance-verify.log` |
| macOS 基础测试 | 22 通过，2 个需独立配置的原生 SSH 专项按设计跳过 | `build/macOS-unit-20261027-110000.xcresult` |
| iPhone 基础测试 | 22 通过，2 个按设计跳过；iOS Target 构建通过 | `build/iOS-unit-20261027-110000.xcresult` |

常规 6 项包括：独立终端主题保持、中英与三态外观及重启保持、面板拖动/显隐/布局保持、空表单导航、主机/分组保存与重启、跟随系统外观变化。连接表单两按钮在中文浅色与英文深色均有真实截图。

真实 SSH UI 专项覆盖：

- 通过连接表单填写本机随机端口与测试账号，使用系统文件选择器导入临时 Ed25519 私钥；实际等待导入完成。
- 指纹与临时 OpenSSH 主机公钥独立计算的 SHA256 值一致后，才点击“信任并连接”。不跳过主机校验。
- 通过原生终端真实键盘输入运行 `printf`、`pwd`、`ls -la`，显示 ANSI 绿色、中文与 Emoji；远程 Shell 在临时目录创建标记文件，验证输入确实走过界面 → SwiftTerm → UniFFI/Rust → SSH/PTY。
- 同一连接中切换简中浅色到英文深色，再次输入并验证另一个远端标记；主动断开并检查界面状态。

以上为真实 OpenSSH 服务，没有用 Mock 连接代替。没有调用用户外部服务器、读取用户密码、使用 root 或修改远程认证配置。

## 可重复运行

```bash
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
SSHCLIENT_TEST_PHASE=phase2 \
SSHCLIENT_TEST_PLATFORM=macos \
SSHCLIENT_TEST_METHOD=testRealSSHConnectionFormAndScreenshots \
scripts/test-local-ssh.sh --apple-only
```

服务仅绑定 `127.0.0.1` 随机端口，临时生成 Ed25519 密钥，不修改系统远程登录、系统账号或 `~/.ssh`。测试结束停止服务、删除私钥与临时配置。该 UI 方法明确拒绝非回环测试目标。`--apple-only` 仅跳过已独立验证的 Rust 专项，不会省略真实服务或身份校验。

基础验证仍使用 `scripts/verify.sh`。UI 专项默认没有配置时显式跳过，需用上面的命令单独运行。固定的 XcodeGen 配置说明参见 [ProjectSpec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)，Apple 的测试媒体选项说明见 [Organizing tests](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)。

## 真实运行截图

PNG 来自本次成功 XCTest 的显式附件，导出时原样复制，没有修改像素。真实终端内容仅位于忽略的 `build/`。

- `build/phase2-screenshots/macos-phase2-zh-light-ssh-ui.png`：中文浅色、真实 SSH、ANSI/中文/Emoji 和远端目录输出。
- `build/phase2-screenshots/macos-phase2-en-dark-ssh-ui.png`：同一连接切换英文深色后继续输入输出。
- `build/phase2-screenshots/macos-phase2-zh-light-key-form.png`：私钥导入完成，明确显示保存与连接按钮。
- `build/phase2-screenshots/macos-phase2-zh-light-host-trust.png`：实际主机指纹确认。
- `build/phase2-screenshots/macos-phase2-{zh-light,en-dark}-{host-form,group-form,saved-hosts}.png`：常规界面验收。

完整索引为 `build/phase2-screenshots/README.md`。资源监控和 SFTP 仍为明确空态，截图未伪造指标或文件。

最终复核：索引中的 27 张 PNG 全部与对应 XCTest 原始附件逐字节一致。本机测试目录、macOS 与两个测试模拟器中均未发现遗留的测试私钥或一次性配置；UI 临时目录已删除，Apple 验证锁已释放。Swift 格式检查、Shell 语法检查和 195 个 String Catalog 条目的中英完整性检查均为 exit 0。

## 本次文件与边界

产品修正：`apple/Features/Hosts/NewHostSheet.swift`、`apple/Features/Terminal/NativeTerminalView.swift`、`apple/Resources/Localizable.xcstrings`。

测试与工程：`apple/Tests/FoundationTests.swift`、`apple/UITests/PhaseZeroUITests.swift`、`scripts/test-apple-ssh.sh`、`apple/project.yml` 与重建工程/Schemes。更新阶段记录、运行方法、截图索引与 README；既有图标和 Artwork 保留。没有添加新依赖、修改 Rust SSH 产品逻辑、提交或推送 Git。

本次补齐的是 Apple Silicon macOS 27.0 / Xcode 27.1 的本机验收。物理 iPhone/iPad、最低系统版本、Intel Mac、正式签名、完整屏幕阅读器阅读终端输出，以及加密私钥口令仍不在本次通过声明中。**当前停在 Phase 2，等待用户新的 Phase 3 指令。**
