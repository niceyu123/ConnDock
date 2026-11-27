# 加密配置备份

入口：macOS、iPhone 和 iPad 的“设置 → 通用 → 配置备份”。现有的 OpenSSH Config 导入独立保留。

## 使用方式

1. 选择“导出配置…”，设置并再次输入至少 12 个字符的备份密码，然后通过系统保存对话框选择位置。文件名默认为 `ConnDock-Backup.json`；JSON 仅是加密信封，主机信息和凭据均在密文中。
2. 目标设备选择“导入配置…”，选择该文件，输入备份密码，选择“预览”解密查看。
3. 核对主机、分组及凭据数量与主机列表，再选择“确认导入”。结果分别列出新增主机、分组、凭据和跳过的重复主机数量。

请保管备份密码；应用不保存备份密码，也无法找回。只有在 Keychain 中已经保存的凭据才能导出，临时输入且未保存的密码不会包含在备份内。不能读取某个已保存凭据时，整个导出失败，不生成缺失凭据的备份。

## 内容与合并规则

- 包含主机名称、地址、端口、用户名、认证类型、备注、收藏、排序、分组、标签、文件模式、单跳跳板、交互认证选项、公钥指纹，以及已保存的 SSH 密码、私钥和私钥口令。
- 不包含 SSH Agent socket 与目录授权、主机信任决定、MCP 授权、会话、终端内容、命令片段、SFTP 收藏及任务、本机语言/主题/字体/布局、iCloud 账号和同步开关。Agent 在目标设备重新配置。
- 地址（不区分大小写）、端口、用户名相同的主机视为重复，保留本机配置和凭据；同名分组合并。不自动覆盖已有配置。备份内部的重复端点也按此规则跳过。
- 新导入主机及分组使用新 UUID，引用随之映射。新 UUID 不会继承已有 MCP 白名单；连接仍须正常检查主机指纹。与现有跳板认证类型冲突或造成嵌套跳板时，整个导入拒绝。
- 凭据写入本机 Keychain，主机/分组和非机密同步 outbox 在同一次 SwiftData 保存中提交。Keychain 写入失败、元数据提交失败或任务取消时回滚本次数据，清理暂存凭据。Keychain 删除暂时失败时沿用原有待删除重试队列。
- 本机已经开启 iCloud 同步时，新增的非机密配置按现有规则同步。凭据和备份密码不进入同步文档。

## 文件协议和边界

加密信封包含固定的 `format = ConnDock.ConfigurationBackup`、`version = 1`、`kdf = PBKDF2-HMAC-SHA256`、`rounds = 600000`、16 字节随机 salt，以及 Base64 编码的 AES-256-GCM combined sealed box（nonce、密文和认证 tag）。使用系统 CommonCrypto 与 CryptoKit，无新增包依赖。

密钥派生输出 32 字节，GCM nonce 由 CryptoKit 随机生成，格式/版本/算法/迭代数通过固定 AAD 认证。导入只接受上述固定参数，不允许文件指定任意昂贵 KDF 工作量。密码错误和内容被篡改均不能解密，界面返回同一提示。

外部文件最大 24 MiB，解密内容最大 16 MiB，最多 1000 台主机、256 个分组。密码最大 1024 UTF-8 字节；SSH 密码和私钥口令各最大 64 KiB，私钥最大 1 MiB。完整验证 UUID 唯一性、枚举、端口、文本和标签长度、凭据类型、分组引用和单跳引用后才进入保存流程。

系统文件选择器提供 security-scoped URL，读取在后台使用有界 FileHandle；加密、派生和解密在后台执行。明文序列化仅在内存处理，文件导出器仅接收密文。关闭页面及进入后台会取消任务并丢弃界面持有的备份密码和已解密预览；不承诺 Swift 值类型在内存中的所有副本都能物理擦除。

本机 Local 构建和自动化测试不代表发行签名、真机、双设备 iCloud 或 App Store 提交验收。新增文件加密后的发行配置和提交声明需在正式发布流程中重新核对。

## 本机验证（2026-10-31）

- `MAC_BUILD_DIR=/tmp/ConnDock-DerivedData IOS_DESTINATION='platform=iOS Simulator,name=SSHClient iPhone 17' scripts/verify.sh` exit 0，日志 `build/configuration-backup-verify.log`。包括 Swift strict 格式、双语资源、Python 脚本测试、发布源码检查、Rust fmt/clippy/workspace 测试、生成绑定与三种 arm64 slice、macOS/iOS Local 构建和实际包检查。该轮 macOS 119 项（跳过 6 项）、iOS 105 项（跳过 5 项），均 0 失败。
- 同名分组补充回归先以 `invalid` 失败，修复后最终数据层单元测试为 macOS 120 项（跳过 6 项）、iOS 106 项（跳过 5 项），0 失败。结果分别在 `build/configuration-backup-mac-final.xcresult` 和 `build/configuration-backup-iphone-final.xcresult` 中的 unit test suite；这些结果包同时包含另列说明的早期 UI 失败，不能把整个结果包当作全部通过。
- 新增 10 项数据/密码测试在两平台均通过：随机加密往返、错误密码和 tag 篡改、非法 KDF 参数、弱密码与超限输入、密码/私钥/私钥口令恢复后重开数据库、普通数据库和同步文档无明文凭据、重复主机保留本机凭据、同名分组引用合并、跳板重映射/冲突、Keychain 失败与取消回滚、已保存凭据丢失时拒绝导出。
- 另以临时 Swift harness 与 Python `hashlib.pbkdf2_hmac` / `cryptography.AESGCM` 交叉验证双向解密，中文备份密码通过；不把同一实现自加密/自解密当作唯一密码验证。
- 最终界面修复后 macOS Local 重新构建 exit 0，日志 `build/configuration-backup-mac-acceptance-build.log`。最终 String Catalog 536 个 key 的 zh-Hans/en 检查、改动文件 strict 格式和 `git diff --check` 通过。
- iPhone UI 最终 1 项通过，结果 `build/configuration-backup-iphone-ui-complete.xcresult`：中文入口、英文导出、短密码/不匹配时禁用、有效确认密码、原生导入选择器打开/取消、系统保存页实际打开，均有截图附件。该测试未执行保存到系统 Files 后重新选择该文件恢复；数据与凭据恢复由上面的存储测试覆盖。
- iPad 横屏 UI 同一用例 1 项通过，结果 `build/configuration-backup-ipad-ui-complete.xcresult`，覆盖双栏设置、上述密码流程和两个系统文件面板。早期 app-window 截图有方向/区域异常，改用与既有 UI 测试一致的 `XCUIScreen.main.screenshot()` 后再跑 1 项通过，最终截图结果 `build/configuration-backup-ipad-screen.xcresult`，保留中文设置、英文导出与系统保存页附件。iPhone 截图为系统深色，iPad 为系统浅色；最大字号、VoiceOver 与真实设备专项本轮未人工验收。
- 早期 iPhone UI 发现 Section 上的 presentation 没有弹出，改为挂到具体按钮后通过；截图发现英文大标题截断后改为 inline 标题和简短操作文案。扩展系统保存页测试时，Files 内部取消/返回按钮无法通过 XCTest 稳定定位，原始失败结果保留；最终测试明确检查系统保存页呈现后结束，不声称验证了系统 Files 内部导航。
- macOS UI runner 在启用 automation mode 时超时，未进入 UI 用例；原始错误为 `Timed out while enabling automation mode`，见 `build/configuration-backup-mac-final.log`。不将其计为界面通过，不据此修改系统权限。

主要改动：`ConfigurationBackupView.swift`（入口、密码和预览、系统文件面板）、`ConfigurationSnapshot.swift`（受限备份模型和捕获）、`ConfigurationArchiveCryptor.swift`（加密信封和派生）、`HostLibrary.swift`（凭据暂存、引用映射及事务）、`SettingsScreen.swift`、`Localizable.xcstrings`、对应单元/UI 测试和需求说明。数据库 schema 与 Rust/UniFFI 接口未改变。
