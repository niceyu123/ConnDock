# Phase 0 验证记录

> 历史范围说明（2026-10-27 更新）：macOS 已正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）。文内原有 Intel/四架构构建结果仅为历史记录，当前构建和发布范围以 `requirements.md` 与现行脚本为准。

日期：2026-10-26～2026-10-27（Asia/Shanghai）。范围严格依据 [requirements.md](requirements.md)，仅交付工程、基础 UI、国际化、主题与最小 Rust/Swift 桥接。

## 环境检查与处理

| 项目 | 实测结果 |
|---|---|
| 主机 | Apple Silicon / arm64，macOS 27.0（26A428） |
| Xcode | 27.1（27A9275），Swift 6.4，工程使用 Swift 6 严格并发 |
| 最低部署版本 | macOS 14.0、iOS/iPadOS 17.0；不代表已在这些旧系统运行 |
| Rust | 1.99.1，由 rust-toolchain.toml 固定；Cargo 1.99.1 |
| XcodeGen | 2.46.0 |
| Rust 目标 | aarch64-apple-darwin、x86_64-apple-darwin、aarch64-apple-ios、aarch64-apple-ios-sim |
| iOS Runtime | iOS 27.0（24A434） |
| iPhone | 专用 SSHClient iPhone 17 模拟器，E875305E-21B1-4FF2-93B8-C065A1C2A1E5 |
| iPad | 专用 SSHClient iPad Pro 11 模拟器，7D9BBA3B-D7F0-41B9-BF0C-37891C216462 |

初始目录只有原始 V1.2 任务书，没有工程或 Git；已初始化 main 分支并建立 monorepo。原始文件保留，`docs/requirements.md` 与其逐字节一致，只有后者作为后续开发入口。

初始缺少 Rust/Rustup、XcodeGen 和 Metal Toolchain：通过官方 Rustup 安装固定工具链，通过 Homebrew 安装 XcodeGen，通过 `xcodebuild -downloadComponent MetalToolchain` 安装 Xcode 官方 Metal 组件。未修改 shell PATH 配置、全局插件信任或无关工程。SwiftTerm 的固定版本构建插件已检查，脚本仅在本次 xcodebuild 命令中允许运行。

## 实现与边界

- macOS：服务器侧栏、搜索/收藏/最近筛选、可折叠的分组空态；中间多标签与真实空白 SwiftTerm；右侧服务器信息/资源空态；底部文件/传输空态。三个面板可显隐、拖动和恢复默认，尺寸及显隐在本机保存。
- iPhone：服务器、全屏终端、设置三页导航，文件与监控采用独立 Sheet；快捷键工具条显示但在未连接时禁用。
- iPad：原生 NavigationSplitView、多标签、独立工具/设置 Sheet；紧凑窗口采用紧凑导航，不缩放 macOS 四区布局。
- 122 个 String Catalog key 均具有经校对的 zh-Hans/en 文案。默认简体中文；应用内独立切换，实际测试在系统英文启动参数下仍默认中文。
- 外观默认 system，提供 light/dark；终端支持跟随应用和独立浅/深主题。语言、外观和终端配色分别本地保存。
- 按用户补充反馈调整为中性黑白配色：浅色主区域/终端为纯白；深色主区域接近 #090909，终端接近 #050505，灰阶选中项与边框；CPU 等类型小图标保留辨识色。设置改为分类导航，Mac 左侧分类右侧内容，移动端按可用宽度选择双栏或分类列表。
- UniFFI 实际从已链接 Rust 库返回 `CoreInfo { version: "0.1.0", bridgeProtocol: 1, networkEnabled: false }`；状态栏和关于页读取实际桥接值。
- 新建连接仅为静态表单，保存与连接禁用。没有服务器记录、模拟终端字符、模拟文件、虚构指标或远程路径；没有完整 SSH/SFTP、SwiftData 主机存储、Keychain 凭据、iCloud 或 MCP 服务。

## 最终统一验证

基础构建与单元测试命令（最终执行成功，退出码 0）：

```bash
IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' \
./scripts/verify.sh > build/verify-phase0-base-final-r2.log 2>&1
```

三端 UI 命令（执行完三端后退出码 1，两个移动端系统外观检查失败）：

```bash
IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' \
IPAD_DESTINATION='platform=iOS Simulator,id=7D9BBA3B-D7F0-41B9-BF0C-37891C216462' \
./scripts/verify.sh --ui > build/verify-phase0-final.log 2>&1
```

基础验证结果包时间戳为 `20261027-010916`；UI 结果包时间戳为 `20261027-005614`。没有跳过失败断言，不能将本阶段标记为全部验收通过。

| 检查 | 结果 | 证据（项目根目录下） |
|---|---|---|
| Swift 格式 / 双语目录 | 通过；122 key 双语完整 | build/verify-phase0-base-final-r2.log |
| Cargo fmt / clippy | 通过；clippy -D warnings | build/verify-phase0-base-final-r2.log |
| Cargo test | 3 passed，0 failed | build/verify-phase0-base-final-r2.log |
| Rust 四目标 release / XCFramework / 绑定重建 | 通过 | build/verify-phase0-base-final-r2.log |
| macOS App 构建 | BUILD SUCCEEDED | build/macos-build.log |
| iOS Simulator App 构建 | BUILD SUCCEEDED | build/ios-build.log |
| macOS 单元测试 | 8 passed，0 failed | build/macOS-unit-20261027-010916.xcresult |
| iPhone 单元测试 | 9 passed，0 failed | build/iOS-unit-20261027-010916.xcresult |
| iPad 单元测试 | 9 passed，0 failed | build/iPad-unit-final.xcresult |
| macOS UI 测试 | 5 passed，0 failed | build/macOS-ui-20261027-005614.xcresult |
| iPhone UI 测试 | 3 passed，1 failed | build/iPhone-ui-20261027-005614.xcresult |
| iPad UI 测试 | 3 passed，1 failed | build/iPad-ui-20261027-005614.xcresult |

单元测试覆盖默认值、偏好持久化及相互独立、损坏值回退、终端配色、布局重置、标签关闭、实际编译的本地化资源及真实 UniFFI 调用。iOS 额外使用真实 UIWindow / UIHostingController / SwiftTerm，注入 UIKit 浅/深 traits，直接检查原生背景颜色及不透明度，验证从白色切到近黑色且偏好仍为 system / followApp；不是只检查枚举映射或界面标识。

UI 测试使用独立 `SSHClient.UITesting` 偏好域。三端均通过中英即时切换、浅/深切换、重新启动保持、分类设置导航、空态与禁用保存，以及应用浅色 + 终端独立深色、重启保持和恢复 Follow App。macOS 另外通过自有菜单与三个分隔条拖动、尺寸/显隐重启保持、恢复布局及系统外观联动。测试结束恢复设备原外观值。

## 移动端系统外观：仍未通过的验收

iPhone 和 iPad 的 `testSystemAppearanceFollowsDevice` 均失败：测试调用设备外观 Dark 后，等待 `terminalCanvas.dark` 超时。已完成以下交叉检查：

- `XCUIDevice.shared.appearance` 以及 `simctl ui … appearance` 报告 dark，但应用 UIWindowScene 的实际 trait 仍为 light，窗口没有强制指定浅色（override 为 unspecified）。
- 独立启动系统“设置 → 外观”，截图与 AX 状态仍显示浅色选中；通过系统设置的深色按钮操作也未得到深色实际状态。证据位于 `build/iPhone-system-settings-inspection.xcresult`、`build/iPhone-system-native-settings.xcresult`。
- 新建专用 `SSHClient Appearance Check` 模拟器后同样复现，结果为 `build/iPhone-fresh-system.xcresult`。该诊断设备已关机，没有删除已有模拟器。
- `UIKitThemeTests.testSystemTraitsUpdateRealSwiftTermColors` 已通过，证明 UIKit traits 变化能经 SwiftUI 更新实际 SwiftTerm 颜色。

现有证据指向本机 iOS 27.0 模拟器的系统外观控制/运行时路径，但尚未在另一运行时或真机完成 OS 级确认。UIKit traits 集成测试不能替代这项端到端验收，因此明确保留两个失败结果，Phase 0 尚未全部验收通过。

## 已定位并修复的问题

1. SwiftTerm Metal 编译失败：安装 Xcode 官方 Metal Toolchain 后通过。
2. 通用 iOS Simulator 构建尝试链接 x86_64，但本阶段只生成 arm64 Simulator 库：按任务书明确排除 Intel iOS Simulator；Intel macOS 库仍保留。
3. 测试宿主自动推导为 Target 名，而 App 产品名是 SSHClient：在 project.yml 显式指定两个 TEST_HOST/BUNDLE_LOADER，单元测试通过。
4. UniFFI 0.32.2 CLI 参数与旧版不同：使用当前版本的 library mode，自动发现 crate 的 uniffi.toml，生成模块名与 C 头一致。
5. macOS 拖动测试最初使用 `press(forDuration:thenDragTo:)`，属于触摸事件 API，应用没有收到鼠标事件。用 LLDB 与原生 UI 拖动确认 mouseDown/mouseDragged 和尺寸绑定正常后，改为 SDK 中的鼠标 `click(forDuration:thenDragTo:)`。临时诊断代码已移除，三个面板均保留真实移动断言。
6. 原生菜单栏和工具栏均含布局项，测试查询存在歧义：将工具栏菜单查询限定在主窗口。
7. iPad 横屏 `app.screenshot()` 导出有裁切：改为启动前确定方向并采集 `XCUIScreen.main.screenshot()`，重新采集完整运行截图。
8. 新增原生 SwiftTerm 颜色测试时，iOS 测试 Target 缺少直接链接，出现 TerminalView metadata 未定义：测试 Target 显式引用同一个固定 SwiftTerm 1.19.0 产品后，9 项单元测试通过；未新增第三方库或改变版本。

Xcode 在 UI 失败后自动执行最长 600 秒的模拟器 sysdiagnose，曾阻塞结果导出。确认测试已结束后，停止了本次测试所属的诊断子进程，结果包及失败记录成功保存。脚本现使用 `-collect-test-diagnostics never`；断言、普通日志、截图附件及最终失败退出码保持有效。

## 截图

截图索引见 [screenshots/README.md](screenshots/README.md)，21 张来自 XCTest keepAlways 附件；另附一张 `simctl io screenshot` 在 iPad 实际测试中采集的 2420×1668 横屏截图。图片均原样保留，没有拼图、颜色反转或生成图。同目录原有应用图标截图属于独立工作，本次保留。

```bash
./scripts/export-screenshots.swift build/macOS-ui-20261027-005614.xcresult \
    build/iPhone-ui-20261027-005614.xcresult build/iPad-ui-20261027-005614.xcresult
```

## 未验证与环境限制

- 未在真实 iPhone/iPad、Intel Mac 或 macOS 14 / iOS 17 运行；Intel macOS Rust 库和 iOS 真机 Rust 库仅编译验证。
- 未配置 Apple Developer Team、发布签名、CloudKit Container、TestFlight 或 App Store；本地 macOS 为 ad-hoc 签名，模拟器关闭签名要求。
- 未运行 SSH/SFTP/监控/iCloud/MCP 端到端测试，均属于后续阶段；当前桥接结果不代表真实 SSH 能力。
- 未验证终端输入、ANSI、PTY、真实会话 resize、取消或断线恢复，Phase 1 接入网络后验收。
- macOS 系统管理的“编辑/窗口/帮助”等原生菜单和系统权限文案遵循平台语言；应用自有菜单、工具栏和页面使用所选应用语言。
- 本阶段未运行远端 CI；统一脚本已在本机执行。没有创建 Git 提交或推送。

## 主要改动文件

| 范围 | 文件或目录 |
|---|---|
| 规范与说明 | AGENTS.md、.gitignore、README.md、docs/requirements.md、docs/ARCHITECTURE.md、本文 |
| Apple 工程 | apple/project.yml、apple/ConnDock.xcodeproj（原 SSHClient.xcodeproj）、apple/Package.swift、apple/Apps/{macOS,iOS}/SSHClientApp.swift、Info.plist |
| 偏好与主题 | apple/Shared/Appearance/{AppPreferences,WorkspacePalette}.swift、Shared/Localization/AppLanguage.swift |
| 工作区与导航 | apple/Shared/Components/{WorkspaceRoot,MobileWorkspace,ResizableDivider,LocalizedComponents}.swift、Shared/Models/WorkspaceState.swift |
| 页面 | apple/Features/{Hosts,Terminal,SFTP,Monitoring,Settings}/ |
| 翻译 | apple/Resources/Localizable.xcstrings |
| Rust / 桥接 | rust-core/Cargo.toml、Cargo.lock、rust-toolchain.toml、crates/{ssh-core,apple-ffi}/、apple/Packages/SSHCoreBridge/ |
| 验证 | apple/Tests/{FoundationTests,UIKitThemeTests}.swift、apple/UITests/PhaseZeroUITests.swift、scripts/{verify.sh,check-localizations.swift} |
| 构建与截图 | scripts/{build-rust-apple.sh,generate-bindings.sh,build-xcframework.sh,export-screenshots.swift}、docs/screenshots/ |

完整结构见 README。应用图标相关的 Artwork、Assets.xcassets 和生成脚本为会话期间检测到的独立改动，已保留，记录见 [APP-ICON-VALIDATION.md](APP-ICON-VALIDATION.md)。真实 Git 索引没有被暂存或提交。另用 `build/phase0-review.index` 临时索引检查新文件空白；唯一例外是逐字节保留的任务书中原有 Markdown 行尾双空格和末尾空行。

## 下一阶段

停留在 Phase 0，提交界面供用户确认；移动端 OS 级系统外观联动仍需另一运行时或真机补验。收到后续指令并满足阶段验收后，再选定并锁定兼容的 russh，设计可取消会话与主机密钥验证，通过真实测试服务器完成 Rust → UniFFI → SwiftTerm 的认证、PTY、字节流、resize 和关闭验证。
