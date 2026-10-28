# 顶部标签、面板收缩、常用命令与 SFTP 收藏

日期：2026-10-28。范围依据用户本轮明确指令，补充到 `docs/requirements.md`。用户要求自行测试，本轮没有运行自动化测试或远程命令验收。

本文保留当时执行命令中的工程路径；工程现已更名为 `apple/ConnDock.xcodeproj`。

## 完成内容与实现选择

- macOS 终端标签复用 `TerminalTabBar`，放入原生窗口工具栏的 principal 区域，内容区域不再重复显示。较多标签可横向滚动，保留新标签和关闭按钮。iPhone/iPad 使用原有内容区标签。
- 删除窗口右上角布局按钮。左侧服务器面板和右侧信息面板各自通过标题处的箭头收起，收起后在对应边缘保留展开箭头。原有分隔条调整宽度、显隐偏好持久化及系统菜单/快捷键继续使用。
- 底部始终保留 44 点高的 SFTP/传输任务/命令栏；箭头收缩内容，点击标签选择并展开对应内容。收缩文件浏览时按原有生命周期取消目录浏览及迟到选择，不断开 SSH 或取消已经入队的传输。隐藏信息面板停止监控采集。
- 常用命令支持添加、编辑和删除。仅将用户主动保存的片段存入本机 Keychain，不保存终端历史，不写普通数据库、日志或 CloudKit。最多 100 条，每条命令最多 8192 UTF-8 字节；拒绝非换行/Tab 的特殊控制字符。
- 执行命令必须主动点击执行入口并在确认页查看完整命令和主机/端口/用户；提交时再次校验原会话 UUID、目标和连接状态。目标发生变化时禁用发送，不借用其他标签、不自动重连。命令发送到该交互终端，使用前应确保终端位于 Shell 提示符；MCP 的授权边界保持独立。
- SFTP 可收藏当前目录，以及右键条目对应的目录/文件所在目录。文件收藏保存所选文件名，跳转成功后选中该文件。菜单只展示当前主机地址、端口和用户名的收藏，并可直接打开或取消收藏。
- 收藏最多 200 项，存入本机偏好；损坏的数据不会被空集合覆盖。目录删除、失去权限等沿用既有 SFTP 错误反馈。
- 所有新增文案均具有 zh-Hans/en；新控件使用现有语义配色与 SF Symbols。

## 主要文件

- `apple/Shared/Components/WorkspaceRoot.swift`
- `apple/Features/Terminal/TerminalWorkspace.swift`
- `apple/Features/Terminal/CommandLibrary.swift`（新增）
- `apple/Features/Terminal/CommandsPanel.swift`（新增）
- `apple/Features/Hosts/HostSidebar.swift`
- `apple/Features/Monitoring/MonitorPanel.swift`
- `apple/Features/SFTP/FilesPanel.swift`
- `apple/Features/SFTP/RemoteFilesModel.swift`
- `apple/Features/SFTP/RemoteBookmarkStore.swift`（新增）
- `apple/Shared/Appearance/AppPreferences.swift`
- `apple/Shared/Models/WorkspaceState.swift`
- `apple/Apps/macOS/SSHClientApp.swift`
- `apple/Resources/Localizable.xcstrings`
- `apple/UITests/PhaseZeroUITests.swift`：仅适配已有布局回归的控件引用，没有执行。

## 已执行检查

1. Swift strict 格式检查与 String Catalog 检查：通过，422 个 key 中英完整，源代码引用有效。
2. macOS Local、arm64 构建：通过，`build/layout-tools-macos-build.log`。
3. iOS Simulator Local、arm64 构建：通过，`build/layout-tools-ios-build.log`，保留 ad-hoc 签名。
4. `git diff --check`：exit 0；仓库源文件仍为既有未跟踪状态，不能将这个结果视作完整源码差异检查，源码另外运行了 strict 格式检查。

构建命令使用 `-project apple/SSHClient.xcodeproj -configuration Local ARCHS=arm64 -skipPackagePluginValidation -disableAutomaticPackageResolution build`。macOS 为 `-scheme SSHClient-macOS -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/SSHClient-DerivedData`；移动端为 `-scheme SSHClient-iOS -destination 'generic/platform=iOS Simulator' -derivedDataPath build/iOS CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`。

构建保留已有 `kSecUseAuthenticationUIFail` 弃用警告及无 AppIntents 依赖的元数据提取提示。本次没有修改相关凭据逻辑。

## 交给用户的手动验收

- Xcode 选择 `SSHClient-macOS`、`My Mac`、Run 的 `Local` 配置，按 ⌘R。检查“开始”位于窗口顶部、标签可切换/关闭/新建，多标签和较窄窗口能滚动。
- 分别收起左右面板，再从窗口边缘箭头展开；调整宽度并重启，检查状态保持。
- 收起底部内容后检查三个标签仍可见；选择任一标签可展开，SFTP 与传输进度仍正常。
- 在命令页添加、编辑、删除片段；重启后检查保存。连接测试服务器，在 Shell 提示符下确认执行；确认期间切换/关闭目标会话或断开，检查不会发送到新会话。
- 收藏当前目录、子目录和文件；从其他目录点击收藏直达，文件应被选中。切换另一主机或登录用户，检查收藏隔离；取消收藏后重启检查保持。
- 在中文/英文、浅色/深色、不同窗口尺寸下检查；移动端原生布局、真机 Keychain、正式分发沙盒和 SSH/SFTP 端到端行为尚未验证。

本轮是本地开发构建，未归档、未上传 TestFlight、未验证正式发行签名或真实云端。

## 同日顶部标签样式补充

- 按用户提供的样式方向，macOS 顶部标签改为平直边框、顶部选中指示，取消标签本身的圆角；macOS 26 及以上通过系统 API 隐藏该工具栏项的共享玻璃背景，较旧系统保留兼容分支。
- 新建标签加号移到标签列表内部，紧跟最后一个标签并随列表滚动；新增标签时将末尾加号滚动到可见位置，切换标签时确保目标标签可见。
- 修改文件：`apple/Features/Terminal/TerminalWorkspace.swift`、`apple/Shared/Components/WorkspaceRoot.swift`，需求同步更新。
- macOS 和 iOS Simulator 的 Local/arm64 构建均 exit 0，日志分别为 `build/titlebar-tabs-macos-build.log`、`build/titlebar-tabs-ios-build.log`。Swift strict 格式、422 个中英文 key 校验通过；未运行自动化或界面测试。
- 手动检查：重新按 ⌘R，确认顶部无外层胶囊背景、加号紧邻最后标签，多标签滚动/新增/关闭与中英文、深浅色表现正常。

### 顶部标签左对齐补充

- 将标签从居中 principal 位置改为靠左 navigation 位置，不再使用固定最大宽度造成宽窗口时的右移。
- 新增 `TitlebarPositionReader.swift`，通过公开 AppKit 坐标转换读取工具栏实际起点；将第一个标签定位到下方终端/SFTP 内容列的左边缘，随侧栏宽度和窗口宽度更新。侧栏收起时避免侵入系统窗口控制区域。
- 隐藏标题栏重复的应用名称，侧栏中的 TermAll 名称保留；加号仍紧跟最后一个标签。
- macOS Local/arm64 构建重跑通过：`build/titlebar-alignment-macos-build.log`。本轮修改均在 macOS 条件编译区域；Swift strict 格式检查通过，没有运行自动化或界面测试。手动验收重点为较宽窗口、拖动侧栏宽度及侧栏收起/恢复后的对齐。

### 同日工具栏入口精简

- 用户确认会话中的示意图后授权实施。右上角保留“本地终端”和图标形式的信息面板开关；移除重复的设置、左侧栏、底部面板按钮及尚未实现的分屏按钮。右侧工具区保留内容所需宽度，终端标签使用剩余空间滚动。
- 左下角设置改用原生 `SettingsLink`，补充中英文无障碍名称；应用菜单及 `⌘,` 沿用现有实现。侧栏使用左上角开关或面板内箭头，底部使用自身标题栏按钮与标签。
- 修改文件：`apple/Shared/Components/WorkspaceRoot.swift`、`apple/Features/Hosts/HostSidebar.swift`、`docs/requirements.md` 及本文。源码修改均在 macOS 条件编译区域。
- Swift strict 格式检查、437 个中英文 key 与引用检查、`git diff --check` 均通过。仓库仍为既有未跟踪状态，另外使用 `build/toolbar-before/` 的修改前副本审阅了实际源码差异。
- macOS 构建命令：`xcodebuild -project apple/ConnDock.xcodeproj -configuration Local ENABLE_TESTABILITY=YES ARCHS=arm64 -skipPackagePluginValidation -disableAutomaticPackageResolution -scheme SSHClient-macOS -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/SSHClient-DerivedData build`，最终构建 exit 0，`BUILD SUCCEEDED`；实际可执行文件 `lipo -archs` 为 `arm64`。日志：`build/toolbar-macos-build.log`。保留既有无 AppIntents 依赖的元数据提取提示。
- 自动化尝试：同一工程/配置下运行 `SSHClientUITests-macOS/PhaseZeroUITests/testLanguageAppearancePersistenceAndScreenshots`，结果为 **1 项失败**，见 `build/toolbar-macos-ui.log` 和 `build/toolbar-macos-ui-20261028.xcresult`。测试在 `placeWindowOnPrimaryDisplay()` 的第 61 行失败：窗口 X 坐标为 -1624，主屏左边缘为 0；日志同时记录微信输入法浮窗中断。尚未进入设置页断言，不能计为功能测试通过。
- 随后直接操作运行界面确认：左下角设置打开、zh-Hans/en 即时切换、浅色/深色切换、左侧栏收起/重新展开、侧栏收起后 `⌘,` 打开设置、右侧信息面板收起/重新展开、底部标题栏收起与 SFTP 标签展开。
- 修正工具区宽度分配后，重新启动最终构建并查看实际运行截图，确认右上角“本地终端”和信息面板图标完整显示，左下角仅保留一个设置入口。
- 本轮未运行完整 `scripts/verify.sh`、Rust/网络集成、iPhone/iPad 界面验收、发行签名或云端同步验收。
