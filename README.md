# ConnDock

产品与 App 显示名称为 **ConnDock**，Xcode 工程为 `ConnDock.xcodeproj`；Target、模块和二进制开发名称仍为 ConnDock。App Store Connect 已新建独立 ConnDock 记录，旧 TermAll 的 TestFlight 构建属于旧身份，不能作为新 App 的构建。

面向 macOS、iPhone、iPad 的原生 SSH 客户端。Phase 7 已提供终端分屏和 SSH Config 导入，本次 Phase 8 增加文件与服务模式、单跳跳板机、交互式认证/MFA 和 macOS 专用 SSH Agent。阶段记录见 [Phase 8](docs/PHASE8-VALIDATION.md)，后续授权范围见 [剩余阶段](docs/REMAINING-STAGES.md)。真实双设备云端同步、正式沙盒和分发验收按对应记录独立推进。

唯一有效任务书：[docs/requirements.md](docs/requirements.md)。原始 V1.2 导入文件仅保留在本地。主界面视觉参考：[docs/ui/macos-dark.png](docs/ui/macos-dark.png)。后续开发必须遵循 [AGENTS.md](AGENTS.md)，按阶段交付。

## 环境与版本

| 项目 | 固定版本 / 最低要求 |
|---|---|
| 最低系统 | macOS 14、iOS/iPadOS 17 |
| 本次开发工具 | Xcode 27.1、Swift 6.4（Swift 6 模式） |
| 工程生成 | XcodeGen 2.46.0 |
| Rust | 1.99.1，`rust-core/rust-toolchain.toml` |
| UniFFI | 0.32.2，proc macros + library mode |
| Tokio | 1.48.0，网络、时间、同步与两个后台运行时线程 |
| russh | 0.65.0，ring 后端，固定版本 |
| russh-sftp | 3.0.1，固定版本，独立 SFTP Channel |
| SwiftTerm | 1.19.0，固定稳定 1.x API，原生 AppKit/UIKit 包装 |

Rust 依赖由 `Cargo.lock` 锁定；Swift 依赖由 Xcode 工程中的 `Package.resolved` 锁定。rmcp 固定为 3.8.0，随 macOS helper 构建。SwiftData 保存本机主机/分组/标签和同步 journal，Keychain 按用户选择保存认证材料；CloudKit 使用 CKSyncEngine，显式关闭 SwiftData 自动镜像与凭据同步。

macOS **仅支持 Apple Silicon（M 系列，arm64）**，正式放弃 Intel，不发布 Universal Mac 包。XCFramework 仅提供 macOS arm64、iOS arm64、iOS Simulator arm64 三个 slice。Xcode、Rust 构建和验证脚本均排除 x86_64，统一验证会检查实际 App Mach-O 与 XCFramework 架构。

## 首次构建

需要完整 Xcode、iOS Simulator Runtime、Rustup 与 XcodeGen。Rustup 安装后脚本会自动将 `$HOME/.cargo/bin` 加入当前进程 PATH，不修改 shell 配置。

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain  # SwiftTerm 的 Metal 着色器需要此官方组件
# 如未安装 Rust，请通过 https://rustup.rs 的官方安装步骤安装。
./scripts/build-xcframework.sh
xcodegen generate --spec apple/project.yml
open apple/ConnDock.xcodeproj
```

Xcode 选择 `ConnDock-macOS` 或 `ConnDock-iOS` Scheme。Debug/Release 配置使用 Team `86HC8YA388`、新 Bundle `com.ruohai.conndock` 和独立 `iCloud.com.ruohai.conndock` Container；CloudKit 容器已关联新 App ID，两平台 Development 签名和 entitlement 已核对，发行签名与真实云端验证仍待完成。`Local` 配置保留原 `local.SSHClient.macOS` / `local.SSHClient.iOS`、ad-hoc 签名及无云端权限；测试脚本显式选择 Local，当前仅 Apple Silicon 模拟器。macOS 保留 App Sandbox、出站与用户选择文件读写；为默认关闭的 MCP Unix socket 增加 network.server，未启用时不监听，不提供 HTTP。正式 helper 与主 App 使用独立 macOS App Group；Local helper 为 ad-hoc 诊断形态，不能代替正式沙盒验收。详见 [CloudKit 配置与手动步骤](docs/PHASE4-CLOUDKIT-SETUP.md)。

SwiftTerm 1.19.0 包含生成自身 Git 版本信息的 build-tool plugin。已核查固定版本的插件和生成器，仅读取包内 Git 信息、写入派生 Swift 文件。Xcode 首次打开时可显示插件信任提示；本地脚本通过本次命令的 `-skipPackagePluginValidation` 运行已核查插件，不修改全局信任设置。升级依赖时必须重新检查。

## 使用与范围

- 默认简体中文、跟随系统外观；设置可立即切换 English、浅色/深色。语言、外观、终端配色分别保存在当前设备 UserDefaults，不同步到 iCloud。
- 设置中的终端字体采用系统等宽字体，字号可在 10–24 之间调整；字号变化立即更新当前终端和 PTY 尺寸，独立保存到本机。
- 按最新界面反馈采用接近 Codex 客户端的中性黑白方向：浅色主区域为纯白，深色为近黑，灰阶区分面板。Mac 设置采用左侧分类、右侧内容；移动端根据宽度采用分类导航或双栏。
- macOS：真实主机列表、搜索、分组、收藏、最近连接与右键操作；多标签 SSH 终端、服务器 Inspector 与底部 SFTP 容器。“布局”菜单可显隐、恢复，分隔线可拖动或通过辅助功能调整，布局保存到本机。
- iPhone：服务器、终端、设置三页导航。终端为独立页面，文件和监控通过 Sheet 打开。
- iPad：NavigationSplitView 侧栏与终端工作区；文件、监控和设置使用适合触控的独立 Sheet。窄窗口自动采用紧凑布局。
- “新建连接”支持密码和通过文件选择器导入 OpenSSH Ed25519 私钥（可含口令）。可只保存非秘密配置，也可保存后连接；“将认证信息保存在本机 Keychain”默认关闭，不记住的凭据只用于本次连接。
- 连接表单的“文件与服务模式”只建立认证后的 SSH transport，不请求 PTY 或 shell，供 SFTP 和服务器支持的服务/监控使用；受限账号是否允许 SFTP、exec 仍由服务器决定。
- 跳板机选择一台已保存的直连主机，两端分别验证主机指纹并认证。暂不支持多跳；缺失跳板机、凭据或目标信任时明确失败，不降级直连。未保存连接重新打开时保留路由和模式。
- 交互式认证支持 keyboard-interactive，以及密码/密钥被服务器部分接受后继续验证 MFA。逐轮显示确切账号、地址和服务器原始提示；答案只用于当前请求，不保存。关闭、取消或 iOS 后台会取消未完成认证。
- macOS Agent 只使用明确填写的 SHA256 公钥指纹，不遍历尝试其他密钥，也不做 Agent forwarding。优先选择“使用应用容器内专用 Agent”，在本机终端手动执行表单给出的 `ssh-agent -a ...`、`SSH_AUTH_SOCK=... ssh-add` 命令，并用同一 socket 的 `ssh-add -l` 获取指纹。应用不执行这些配置命令、不读取私钥。socket 与目录书签只在本机保存；容器外系统 Agent 可能被 App Sandbox 拒绝，选择目录不保证开放 socket 网络权限，遇到此限制会明确报错。iOS 不提供 Agent 认证入口。
- 已保存主机可编辑、分组、收藏、删除或测试连接。点击当前已连接主机选中其标签；右键/长按“在新标签页中打开”可建立独立会话。删除配置不强制中断正在使用的终端。
- 首次连接必须明确确认 SHA256 主机指纹；已信任密钥变化将阻止连接。取消连接、关闭标签都会结束后台任务。重连可使用保存的 Keychain 引用；未保存、丢失或不可访问时要求重新输入。修改地址、端口、账号或认证方式不会静默沿用旧凭据。
- SFTP 支持目录导航、新建目录、重命名、删除空目录或文件、上传与下载；文件名按原始值处理。上传使用 64 KiB 数据块和远端临时文件，覆盖须明确确认。下载完成后通过系统保存窗口存储到本机。传输可取消和重试，最终提交时显示“正在完成”。
- Linux 监控使用独立只读 SSH Channel 和 Swift Charts，默认每 5 秒刷新 CPU、内存、根磁盘、网络和 uptime；可暂停。隐藏监控或离开前台停止采集，非 Linux 明确提示不支持。
- 主机支持逗号分隔标签、去重和搜索。iCloud 同步默认关闭；在具备权限的构建中，经范围确认后同步非机密配置、分组、标签和收藏。密码/私钥、主机信任、终端内容和设备偏好不上传；新设备需要重新输入凭据。
- 本地变更与 outbox 同一事务，离线可编辑，前台自动重试；关闭同步保留本地。冲突选择完整逻辑版本、删除优先；账号或云端 Zone 变化暂停并要求重新确认。仅前台自动同步，不承诺后台即时复制。
- 关于页显示实际 App 版本/build 与构建类型；Rust bridge 版本单独通过 UniFFI 从已链接库返回。
- iOS/iPadOS 进入后台后暂停输入、清空未发送队列并停止指标和未完成传输；回前台验证原 SSH 连接后恢复，失败时手动重连。macOS 普通失焦保留会话。
- macOS 快捷键：⌘N 新建连接、⌘K 查找、⌘T 新终端、⌘W 关闭标签、⌘, 设置；⌃⌘S/I/F 显隐三个面板。

## 应用图标

使用用户提供的蓝底白色云朵终端图案。原图和平台适配母版位于 [apple/Artwork](apple/Artwork/README.md)：macOS 使用透明外沿的蓝色圆角底板，iPhone/iPad 使用不透明满幅蓝底，由系统应用圆角。两个 App Target 均通过各自的 `Assets.xcassets/AppIcon.appiconset` 编译图标。应用内左上角使用同一图案的单色透明符号，通过共享资源随深浅色外观呈现黑灰白风格。

尺寸资源已纳入源码；修改平台母版后，可使用 macOS 自带工具重建，无需新增依赖：

```bash
./scripts/generate-app-icons.sh
xcodegen generate --spec apple/project.yml
```

## 验证

```bash
./scripts/verify.sh        # Cargo fmt/clippy/test、翻译检查、三个 arm64 slice、App 架构检查及构建/测试
swift ./scripts/check-cloudkit.swift # 两平台 Debug/Release/Local 配置一致性，不代表签名或云端成功
./scripts/test-cloud-sync-ui.sh      # 三端 Local 同步设置、中英/浅深色与真实截图
./scripts/verify.sh --ui   # 额外运行 macOS / iPhone / iPad UI 自动化及截图附件
./scripts/test-stability.sh # 隔离 Linux 4 连接 90 秒 + 三端后台恢复/反复 tab 释放
./scripts/test-phase6-ui.sh # 三端隐私/真实版本信息、外观与重启/后台恢复界面
python3 scripts/check-release.py --source-only # 隐私资源、图标与本地导出约定
./scripts/archive-release.sh macos --unsigned # 仅 Release 编译归档，不能分发
./scripts/archive-release.sh ios --unsigned   # arm64 真机目标编译，不能分发
./scripts/test-local-ssh.sh  # 本机临时真实 OpenSSH + Rust 集成测试
./scripts/test-local-ssh.sh --apple  # 额外运行三端 Rust/UniFFI/SwiftTerm 链路
./scripts/test-local-ssh.sh --connections # Phase 8 无 PTY、跳板、MFA 和 Agent 的隔离真实 SSH
CONNDOCK_CONNECTIONS_APPLE=1 ./scripts/test-local-ssh.sh --connections # 额外验证三端 transport/SFTP/跳板的 UniFFI 链路
CONNDOCK_TEST_PHASE=phase2 \
CONNDOCK_TEST_METHOD=testSavedHostsUseKeychainAndSwitchLiveSessions \
./scripts/test-local-ssh.sh --apple  # 真实 Keychain、磁盘重开、多会话切换
CONNDOCK_TEST_PHASE=phase2 \
CONNDOCK_TEST_PLATFORM=macos \
CONNDOCK_TEST_METHOD=testRealSSHConnectionFormAndScreenshots \
./scripts/test-local-ssh.sh --apple-only  # macOS 表单、指纹确认、真实键盘输入与浅深截图
```

模拟器名称不同时可覆盖目标：

```bash
IOS_DESTINATION='platform=iOS Simulator,id=<你的 iPhone UDID>' \
IPAD_DESTINATION='platform=iOS Simulator,id=<你的 iPad UDID>' \
./scripts/verify.sh --ui
```

日志和 `.xcresult` 在 `build/`。SSH、主机与文件/监控截图原样导出至忽略的 `build/phase1-screenshots/`、`build/phase2-screenshots/`、`build/phase3-screenshots/`，避免终端内容进入 Git；历史界面截图保留在本地，不纳入仓库。UI 自动化使用独立偏好域和独立 SwiftData 路径，不修改实际主机库。macOS 鼠标自动化运行时请保持桌面空闲。阶段记录见 [Phase 0](docs/PHASE0-VALIDATION.md)、[Phase 1](docs/PHASE1-VALIDATION.md)、[Phase 2](docs/PHASE2-VALIDATION.md)。

模拟器测试需要保留 ad-hoc 代码签名以正常使用系统 Keychain；脚本使用 `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`，不填写虚构 Team 或证书。真机仍需用户在 Xcode 配置真实签名。macOS 的默认派生目录在系统临时目录中，可用 `MAC_BUILD_DIR` 覆盖。Apple 构建/测试脚本互斥运行，避免同一 App 被并发安装或替换。

```bash
./scripts/export-screenshots.swift build/macOS-ui-<时间戳>.xcresult \
    build/iPhone-ui-<时间戳>.xcresult build/iPad-ui-<时间戳>.xcresult
```

## 目录

```text
AGENTS.md
docs/requirements.md              # 唯一有效任务书
docs/ARCHITECTURE.md              # 架构、职责和边界
docs/ui/macos-dark.png            # 用户提供的设计参考
apple/project.yml                # 可重复生成工程的配置
apple/ConnDock.xcodeproj          # 已生成工程与共享 Schemes
apple/Apps/{macOS,iOS}/           # 两个原生 App 入口
apple/Shared/                    # 设备偏好、主题、布局和工作区模型
apple/Features/                  # Hosts/Terminal/SFTP/Monitoring/Settings
apple/Resources/Localizable.xcstrings
apple/Packages/SSHCoreBridge/     # 生成的 UniFFI Swift + XCFramework
apple/{Tests,UITests}/
rust-core/crates/{ssh-core,apple-ffi}/
scripts/                         # 构建、绑定生成和验证
```

Phase 1 验收方法见 [docs/PHASE1-TESTING.md](docs/PHASE1-TESTING.md)。Phase 1 功能验收已通过，按用户确认进入 Phase 2；后续阶段需要新的指令。未完成的真实验收不能用模拟结果代替。

Phase 2 专项方法见 [docs/PHASE2-TESTING.md](docs/PHASE2-TESTING.md)。已验证三端的 SwiftData/真实 Keychain/真实多标签 SSH，以及 iPhone、iPad 的界面重启持久化。macOS 补充验收已通过 6 项常规 UI 测试与 1 项真实 SSH 界面测试，补齐中文浅色和英文深色的真实终端截图；修正原因、原始结果包与运行限制见 [macOS 补充验收](docs/PHASE2-MACOS-ACCEPTANCE.md)。该阶段验收后已按用户新指令继续 Phase 3。

Phase 3 的 SFTP 与 Linux 监控实现、本机真实 Linux/2 GiB/三端专项及统一构建已通过。方法见 [docs/PHASE3-TESTING.md](docs/PHASE3-TESTING.md)，具体计数、原始结果、文件范围和未验证项见 [docs/PHASE3-VALIDATION.md](docs/PHASE3-VALIDATION.md)。15 张运行截图索引位于忽略的 `build/phase3-screenshots/README.md`。Docker 只用于隔离验收，不是产品运行依赖。该阶段之后按新指令进入 Phase 4。

Phase 4 的实现、正式配置与本机验证已完成；macOS 已按最新要求仅支持 M 系列。配置/Schema/真实验收步骤见 [docs/PHASE4-CLOUDKIT-SETUP.md](docs/PHASE4-CLOUDKIT-SETUP.md)，结果和未完成的签名/真实云端项见 [docs/PHASE4-VALIDATION.md](docs/PHASE4-VALIDATION.md)。同步 Mock 只在测试 Target，不能代替真实 CloudKit 验收。6 张三端中英浅深运行截图索引位于忽略的 `build/phase4-screenshots/README.md`。旧开发身份与正式身份的沙盒/Keychain 组独立；保留旧开发数据，不自动复制活动 SQLite 或导出凭据。该阶段后已按用户指令进入 Phase 5。


Phase 5 使用方法和边界见 [MCP 配置](docs/PHASE5-MCP-SETUP.md)，执行计划见 [Phase 5 计划](docs/PHASE5-PLAN.md)，最终结果见 [Phase 5 验证](docs/PHASE5-VALIDATION.md)。隔离真实链路运行 `scripts/test-mcp.sh`；加 `--codex` 验证本机 Codex CLI，使用临时参数，不改全局客户端配置。MCP 默认为关闭；请求仅访问用户明确授权的 UUID，凭据留在主 App 的 Keychain 中。该阶段后已按用户指令进入 Phase 6。

Phase 6 的后台恢复、输入取消、多标签与发布准备见 [计划](docs/PHASE6-PLAN.md)、[验证记录](docs/PHASE6-VALIDATION.md)、[人工验收矩阵](docs/PHASE6-ACCEPTANCE.md)、[隐私说明](docs/PHASE6-PRIVACY.md) 和 [本地归档/TestFlight 准备](docs/PHASE6-RELEASE.md)。真实云端、正式 helper 沙盒、设备权限和分发验收按记录继续保留待办。

2026-10-28 用户授权剩余 P1/P2 分阶段实施，其他平台客户端暂缓。Phase 7 已接入终端分屏与 SSH Config 导入，详见 [验证记录](docs/PHASE7-VALIDATION.md) 与 [后续阶段](docs/REMAINING-STAGES.md)。macOS 使用布局菜单、⌘D/⇧⌘D 或标签右键分屏；iPad 使用终端工具栏的分屏菜单。两窗格输入独立，SFTP/监控/命令跟随所选窗格。主机列表的导入按钮可选择 SSH Config 文件，先预览再保存；不支持的连接选项会阻止对应配置导入，凭据需另行输入。

## 2026-10-28 内部命名统一

工程 Target/Scheme 使用 `ConnDock-macOS`、`ConnDock-iOS`，Swift 模块和可执行文件为 `ConnDock`，共享包为 `ConnDockKit`，UniFFI 模块为 `ConnDockFFI`，Rust 包使用 `conndock-` 前缀，MCP helper 为 `conndock-mcp`。使用新的 Scheme 重新构建；已有外部 MCP 配置需按设置页展示的新 helper 路径更新。

为保持已有数据可访问，Local Bundle ID `local.SSHClient.*`、本地 `SSHClient` 数据目录、Keychain 服务名以及 CloudKit 的 `SSHClientConfigV1`/`SSHClientPrivateV1` 标识继续保留。这些是持久化兼容标识。正式 Bundle ID 和独立 CloudKit 容器继续使用 ConnDock 身份。历史阶段验收文档中的旧命名反映当时的构建结果，不代表新命名已通过发行或云端验收。UniFFI 生成物通过脚本重建。
