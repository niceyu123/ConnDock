# ConnDock 蓝色系统图标与单色应用内标志

日期：2026-10-28。范围为用户提供的新图标替换，以及左上角品牌标志；用户随后要求应用内采用黑灰白风格。

## 实现

- 原始附件原样保存到 `apple/Artwork/AppIcon-original.png`；内置 imagegen 适配 macOS 透明外沿母版、iPhone/iPad 满幅不透明蓝底母版，以及应用内透明单色符号。提示词记录在 `apple/Artwork/README.md`，图像适配不宣称逐像素复制。
- `scripts/generate-app-icons.sh` 使用 sips 生成两个平台的 AppIcon 和共享 BrandAssets 1x/2x/3x 资源。
- 新增 `apple/Shared/Components/BrandIcon.swift`：以 SwiftPM Bundle.module 加载模板图像，使用语义前景色适配深浅色；作为装饰图像不重复朗读。
- macOS 顶部 ConnDock 名称旁与主机侧栏显示图标。侧栏收起时顶部仅保留图标和侧栏开关，压缩间距，为窗口控制按钮留出空间。
- iPhone 在服务器页原生导航栏左上角显示图标；iPad 在主机侧栏显示图标。
- 更新 `docs/requirements.md`、主 README 和 Artwork 说明。不改变网络核心、凭据、同步或正式身份配置。

## 已执行验证

- `scripts/generate-app-icons.sh`、`bash -n scripts/generate-app-icons.sh`、`xcodegen generate --spec apple/project.yml`：通过。
- 本次 Swift 文件严格格式检查：通过；`xcrun swift scripts/check-localizations.swift`：437 个 key，zh-Hans/en 完整。
- 独立读取 PNG IHDR 与资源 JSON：28 个 AppIcon 规格的引用和像素尺寸正确；原图与附件逐字节一致。iOS 母版不透明，macOS 和单色母版有 alpha。
- macOS Local arm64 构建与 iOS Local arm64 模拟器构建：通过，日志 `build/brand-icon-macos-build.log`、`build/brand-icon-ios-build.log`。
- iOS 首次增量构建的共享资源源 bundle 已生成 Assets.car，但 App 内仍复制旧 bundle，模拟运行表现为图标留白。将旧的构建资源包移至 `build/brand-icon-stale-ios-resource-bundle` 后重新构建，确认 App 内 Assets.car 存在；重新安装并重启两个模拟器，图标正常。该轮增量构建未更新顶层资源签名，因此再将旧 App 移至 `build/brand-icon-stale-ios.app`，由 Xcode 重新生成完整 App 包及本地签名；最终构建和 Local 预检均通过。源码资源与生成流程不需要绕过逻辑。最终日志 `build/brand-icon-ios-final-build.log`。
- 实际 macOS 浅色/深色窗口及侧栏收起均已手动检查；图标正确适配，收起后保留标志和展开按钮，验证后恢复浅色及侧栏展开。截图 `build/brand-icon-screenshots/macos-light.png` 和 `macos-dark.png`。iPhone 深色、iPad 浅色模拟器图标均已目视检查，截图 `build/brand-icon-screenshots/iphone-final.png` 和 `ipad-final.png`。
- `scripts/check-apple-architectures.swift`：App 与 XCFramework macOS/iOS/模拟器 slice 均为 arm64。
- `scripts/check-release.py --source-only` 和两个 App 的 `--mode local`：通过；Local 结果明确不代表发行验收。
- `git diff --check`：通过；当前仓库仍为未跟踪源码，不能据此宣称所有源码差异已由 Git 覆盖。

## 全量检查与限制

已运行 `MAC_BUILD_DIR="$PWD/build/macOS" scripts/verify.sh`。Swift 格式、本地化、10 项 Python 测试、源码预检、Cargo fmt/clippy 通过；Cargo workspace 测试在 MCP stdio 的两项测试失败后停止。失败位置是 `rust-core/crates/mcp-server/tests/stdio.rs:75`，复制测试二进制时返回 NotFound；本次没有修改 MCP 测试或实现。完整脚本未通过，未将后续步骤视为已执行。

首次独立 macOS UI 测试因命令漏设 ENABLE_TESTABILITY=YES，测试目标无法使用 @testable 导入 SSHClientKit 而取消。用项目 verify.sh 相同的 ENABLE_TESTABILITY=YES 参数重试后测试目标成功编译，但 `testLanguageAppearancePersistenceAndScreenshots` 在启动阶段的多显示器窗口定位断言失败：`PhaseZeroUITests.swift:61`，窗口 X 坐标 -1457 小于 0；未进入语言/外观断言。结果位于 `build/brand-icon-macos-ui-retry.xcresult`，日志 `build/brand-icon-macos-ui-retry.log`。没有修改测试或宣称自动化 UI 测试通过；随后使用原生界面实际切换深浅色并验证侧栏收起，截图如上。

未上传 TestFlight、更新 App Store Connect、替换系统 Applications 中的正式安装或验证真实移动设备。当前用户界面已打开的是本地构建，发布签名和商店图标更新需要后续分发。
