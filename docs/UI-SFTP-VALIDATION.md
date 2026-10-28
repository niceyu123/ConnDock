# 工具栏、分组与 SFTP 交互调整

用户于 2026-10-27 批准按会话中的方案实施。以 `docs/requirements.md` 的更新为准，属于现有功能的界面改进。

## 实现

- macOS 窗口工具栏移除新建、连接、断开、上传、下载；侧栏、布局和设置保留，系统菜单及快捷键继续可用。
- 分组标题右侧常驻 `+`，取消分组列表内的创建操作行，折叠状态仍能创建分组。
- SFTP 接收本机文件 URL，支持多文件拖入，显示目标目录与高亮。整个选择先验证为普通文件，同名文件在入队前统一确认；服务端已有的原子替换和失败重试继续生效。上传按钮继续使用系统文件选择器。
- 文件 URL 的沙盒授权随选择/队列保留；传输继续使用既有 64 KiB 分块、最多两个并发任务，不把文件加载到 UI 内存。
- 上传绑定目录与浏览生命周期版本，切换目录后返回、切换会话、关闭面板或断开连接都会使旧选择失效；同目录刷新不会误作新的目标。
- 文件浏览页显示当前任务摘要，传输列表与摘要复用任务行。上传/下载显示进度、已传输/总大小、百分比、状态和操作；未知大小显示不确定进度，空文件完成显示 100%。摘要可进入全部任务，完成后可清除。
- 新增 UI 文案同时维护简体中文和英文；遵循现有深浅色语义配色。

## 修改范围

- `apple/Shared/Components/WorkspaceRoot.swift`
- `apple/Features/Hosts/HostSidebar.swift`
- `apple/Features/SFTP/{FilesPanel,RemoteFilesModel,TransferDiskFile}.swift`
- `apple/Resources/Localizable.xcstrings`
- `apple/Tests/{RemoteServicesTests,SSHIntegrationTests}.swift`
- `apple/UITests/PhaseZeroUITests.swift`
- `scripts/test-{local,apple}-ssh.sh`：让本机临时 OpenSSH 同时支持文件上传/拖拽/下载的界面验收。

## 验证记录

- 首轮针对性红灯：`build/ui-sftp-red.log`，缺少文件选择授权对象与进度计算；实现后 `build/ui-sftp-green.log`，7 项通过。
- `MAC_BUILD_DIR=/tmp/SSHClient-DerivedData IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' scripts/verify.sh`：首轮 exit 0，日志 `build/ui-sftp-verify.log`。
- macOS 74 项（69 通过、5 个需独立 fixture 的项目跳过），iPhone 模拟器 64 项（60 通过、4 跳过）；Rust 普通 suite 52 通过、16 个 opt-in 集成项目忽略；Python 发行检查 10 项通过。
- 真实本机 OpenSSH 桥接：`MAC_BUILD_DIR=/tmp/SSHClient-DerivedData SSHCLIENT_TEST_ISOLATED=1 SSHCLIENT_TEST_PHASE=phase3 SSHCLIENT_TEST_PLATFORM=macos SSHCLIENT_TEST_METHOD=testSFTPAndLinuxMonitorThroughBridge scripts/test-local-ssh.sh --apple-only`，1 项通过；覆盖文件往返、取消、重试和旧目标拒绝，结果 `build/phase3-mac-ssh-20261027-235351.xcresult`。
- 首轮真实界面验收停在目录控件查询：`build/phase3-mac-ui-ssh-20261027-235438.xcresult`。实际截图和 AX 导出证实容器级标识覆盖子控件标识；已移除该容器标识，保留原控件标识。
- 第二轮真实界面验收：`build/phase3-mac-ui-ssh-20261027-235705.xcresult`。目录导航、文件选择上传及文件浏览页传输摘要已走通；停在 Finder 文件定位，尚未执行实际拖入。导出的 Finder AX 表明文件名位于 TextField 的 `value`，原查询只读取 `label`；已将查询补为同时匹配 `label`/`value`，未重跑。
- 用户随后明确要求自行测试，已停止后续测试与构建。最后移除容器标识、完善确认取消清理及 Finder 测试定位后的完整统一验证未重跑；本记录不将首轮统一检查当作最终所有差异的全量通过证明。完整 Finder 拖入、同名确认、下载保存及最终界面回归交由用户验收。

## 验收边界

拖入上传限定普通文件，文件夹递归上传没有纳入本次修改。真实网络验收使用临时回环 OpenSSH；未改动用户服务器。尚未验收正式分发沙盒下的 Finder/第三方文件提供器组合、物理 iPhone/iPad、iCloud Drive 未下载文件、超大批次拖拽。已有真实云端与 TestFlight 的待办仍按原阶段文档处理。
