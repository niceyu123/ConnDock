# 应用图标接入验证

> 历史记录：当前蓝色系统图标与应用内单色标志的验证见 [BRAND-ICON-VALIDATION.md](BRAND-ICON-VALIDATION.md)。下文的黑白终端/服务器图案已被 2026-10-28 的用户新附件替换。

日期：2026-10-27。范围仅为用户提供图案的三端应用图标接入，不扩展 Phase 0 功能。

本文保留当时执行命令中的工程路径；工程现已更名为 `apple/ConnDock.xcodeproj`。

## 改动

- `apple/Artwork/`：保存用户原图及经内置 imagegen 适配的平台母版；提示词和源图说明见该目录 README。
- `apple/Apps/{macOS,iOS}/Assets.xcassets/`：28 个图标规格，复用 20 个 PNG 文件，最大尺寸 1024×1024。
- `apple/project.yml` 及生成的 `apple/SSHClient.xcodeproj/project.pbxproj`：两个 App Target 引用 `AppIcon`。
- `apple/Package.swift`：共享库排除 App 目录与图标母版，避免 SwiftPM 将两套 App 资源误认为共享资源而发生同名冲突。
- `scripts/generate-app-icons.sh`：从固定平台母版重建尺寸和资源目录，无新增依赖。
- `README.md`：补充图标重建说明。

## 已执行结果

- `./scripts/generate-app-icons.sh`：成功生成全部尺寸。
- `xcodegen generate --spec apple/project.yml`：成功生成工程。
- `bash -n scripts/generate-app-icons.sh`：通过。
- `xcrun swift-format lint --strict apple/Package.swift`：通过。
- `xcrun swift scripts/check-localizations.swift`：122 个 key，zh-Hans/en 完整。
- `git diff --check`：通过；当前仓库尚无首次提交，既有源码均为未跟踪状态，因此该命令不能代替全部新文件审阅。
- 独立读取资源目录 JSON 与 PNG IHDR：28 个规格的文件引用和像素尺寸正确；iOS 为不透明图片，macOS 保留 alpha。
- `cmp` 原图与用户附件：内容一致。
- 下列两个构建均为 `BUILD SUCCEEDED`；日志分别为 `build/app-icon-macos-build.log` 和 `build/app-icon-ios-build.log`：

```bash
xcodebuild -project apple/SSHClient.xcodeproj \
  -skipPackagePluginValidation -disableAutomaticPackageResolution \
  -scheme SSHClient-macOS -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData build

xcodebuild -project apple/SSHClient.xcodeproj \
  -skipPackagePluginValidation -disableAutomaticPackageResolution \
  -scheme SSHClient-iOS -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/iOS CODE_SIGNING_ALLOWED=NO build
```

- `plutil` 核对产物：macOS 的 `CFBundleIconFile` / `CFBundleIconName` 为 `AppIcon`，iPhone/iPad 均有各自的主图标条目。
- `iconutil` 解包 macOS 产物：实际 ICNS 包含新图案；`codesign --verify --deep --strict` 通过。
- macOS 应用启动成功；系统缓存最初显示旧占位图，刷新应用包时间、重新注册 LaunchServices 并重启后，原生“关于”面板正确显示新图标。没有增加运行时强制设置图标的代码。
- 使用 `xcrun simctl install` 安装到现有 SSHClient iPhone 17、SSHClient iPad Pro 11 模拟器，`simctl launch` 均成功；退出应用后，主屏幕图标经截图目视检查正确。

## 实际运行截图

- [macOS 原生关于面板](screenshots/macos-app-icon-about.png)
- [iPhone 主屏幕](screenshots/iphone-app-icon-home.png)
- [iPad 主屏幕](screenshots/ipad-app-icon-home.png)

## 未完成的整体验证

实际尝试了 `scripts/verify.sh`，但在 Swift 格式检查时停止：`apple/UITests/PhaseZeroUITests.swift:189` 存在原有 `LineLength` 错误。本次未修改该测试文件，未宣称完整脚本、Cargo 检查或单元/UI 自动化测试通过。两端构建和上述图标专项检查为单独执行。

未验证真机、发布签名、App Store 上传以及系统提供的不同主屏幕图标外观。当前图标使用用户指定的黑白设计。
