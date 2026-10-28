# Phase 2 本机验收方法

> 历史范围说明（2026-10-27 更新）：macOS 已正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）。文内原有 Intel/四架构构建结果仅为历史记录，当前构建和发布范围以 `requirements.md` 与现行脚本为准。

先运行 `scripts/verify.sh`，再运行以下专项。需要完整 Xcode、已经安装的 iOS Runtime，以及现有 iPhone/iPad 模拟器。所有测试只使用隔离的本机库；不要求提供新的外部凭据。

```bash
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
SSHCLIENT_TEST_PHASE=phase2 \
SSHCLIENT_TEST_METHOD=testSavedHostsUseKeychainAndSwitchLiveSessions \
scripts/test-local-ssh.sh --apple
```

上例会运行 Rust 的真实本机 OpenSSH 集成用例，随后逐个运行 macOS、iPhone、iPad 的原生应用集成测试。临时主机/登录密钥在本次进程结束时删除，sshd 被停止，不更改系统“远程登录”或用户的 `~/.ssh`。临时配置按运行 UUID 归属、权限 0600；原生集成测试读取后立即删除，UI Runner 的只读输入则由脚本清理。

本机服务通过 ForceCommand 使用系统 `/bin/bash --noprofile --norc --noediting -i`，固定 UTF-8 locale 和真实 PS1 提示符，隔离用户 Shell 启动钩子。Shell 请求确认不代表交互 Shell 已准备好，Rust 测试等待该提示符后才输入命令；这只改变临时服务，不更改用户 Shell 配置。只重跑原生专项时可用 `--apple-only`；只运行 macOS 原生专项可加 `SSHCLIENT_TEST_PLATFORM=macos`。

Phase 2 原生专项使用真实 SwiftData 磁盘库和带独立 UUID service 的系统 Keychain，保存两条指向本次真实 OpenSSH 的配置，重开数据库，再从 Keychain 读取 Ed25519 凭据建立两个独立 SSH Session。检查标签切换后各自输出不混入另一会话，真实连接测试完成后自动断开，字号/语言/外观切换不丢连接。删除配置不强制断开正在使用的终端；测试结束后删除 Keychain 临时项并核查无残留。

`HostPersistenceTests` 中的故障凭据适配器只用于注入写入/删除失败；它不负责任何 SSH 连接。正向 Keychain 测试和三端 SSH 专项始终调用系统 Security.framework 与真实 OpenSSH，不以 Mock 连接替代。

UI 持久化用例为：

```text
PhaseZeroUITests/testSavedConfigurationPersistsWithoutConnecting
```

它通过界面填写 `example.invalid` 的非秘密配置，只点“保存”，不发起网络连接；结束应用并重新启动后检查配置仍在，再切换中英和深浅外观。该保留域名是离线持久化测试数据，不能把它描述为 SSH 服务。测试使用独立 SwiftData 目录和偏好域。

macOS 的真实连接表单、键盘输入与浅深运行截图使用另一项完整 UI 流程：

```bash
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
SSHCLIENT_TEST_PHASE=phase2 \
SSHCLIENT_TEST_PLATFORM=macos \
SSHCLIENT_TEST_METHOD=testRealSSHConnectionFormAndScreenshots \
scripts/test-local-ssh.sh --apple-only
```

该流程只接受本机 `127.0.0.1` 的临时服务，使用系统文件选择器导入临时私钥，核对独立计算的主机指纹后才确认连接。通过原生终端键盘输入 ANSI/中文/Emoji 和目录命令，验证远端标记文件，再切换语言/外观继续输入，最后主动断开。UI Runner 的配置只有端点、指纹和文件路径，不含私钥正文；脚本清理其只读配置和临时目录。它不使用内存连接或外部服务器凭据。

两个 Scheme 关闭自动测试截图/录屏，只保留测试显式添加的 PNG，避免文件选择器预览私钥被记录。macOS UI 测试用原生鼠标拖动将测试窗口放到主屏可见范围，截取明确的工作区或设置窗口；测试运行时需保持桌面空闲。这些措施只影响验收进程，不修改日常窗口布局。

可从结果包导出未经合成或编辑的原始运行 PNG：

```bash
scripts/export-screenshots.swift build/phase2-mac-ssh-<时间戳>.xcresult \
  build/phase2-iphone-ssh-<时间戳>.xcresult build/phase2-ipad-ssh-<时间戳>.xcresult
```

Phase 2 截图输出到忽略的 `build/phase2-screenshots/`。导出每次使用独立暂存目录，可重复执行。测试日志不记录密码、私钥、口令或原始终端输出；真实终端截图不进入 Git。macOS 的原生集成专项仍只通过 AppKit 离屏捕获深色图；浅色图由上述真实 UI 流程直接截取实际窗口，已成功交付 `macos-phase2-zh-light-ssh-ui.png` 与同一连接的英文深色图。系统截图服务不可用时可用 `TEST_RUNNER_SSHCLIENT_UI_CAPTURE_SCREENSHOTS=0` 单独检查功能，不能据此声称截图已通过。

本次成功结果可直接导出：

```bash
scripts/export-screenshots.swift build/phase2-mac-ui-ssh-20261027-105734.xcresult \
  build/phase2-macos-ui-acceptance-final.xcresult
```

修正前后结果和完整命令证据见 `PHASE2-MACOS-ACCEPTANCE.md`。

模拟器必须保留 ad-hoc 签名。关闭代码签名时，本机曾复现 Keychain `-34018`；启用签名后真实读写/删除通过。Apple 对该错误与签名 entitlement 的说明见 [Troubleshooting -34018 Keychain Errors](https://developer.apple.com/forums/thread/114456)。脚本不使用虚构 Team、证书或明文凭据降级方案。

物理设备、最低系统版本、Intel Mac 运行、正式签名身份与 Keychain 授权、外接键盘和 IME 需要另行验收；本机模拟器结果不能代替这些结果。执行结果见阶段验证记录。
