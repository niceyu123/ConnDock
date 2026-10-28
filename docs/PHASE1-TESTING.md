# Phase 1 真实 SSH 验证

本页记录 Phase 1 的一次性连接验收方法。新建连接后，先通过可信渠道核对主机指纹并确认，再开始认证。主机密钥变化将强制阻止连接，不能在同一提示中忽略变化。当前 Phase 2 已增加 SwiftData 主机配置与可选 Keychain 凭据保存，基本 SSH 集成仍可单独运行。

## 本机可重复集成测试

先运行 `scripts/verify.sh` 构建和基础测试，再运行：

```sh
scripts/test-local-ssh.sh
scripts/test-local-ssh.sh --apple
```

第一个命令在随机回环端口启动系统 `/usr/sbin/sshd`，生成临时 Ed25519 主机和登录密钥，仅允许当前用户。它不启用系统“远程登录”、不创建账号、不修改 `~/.ssh`、不安装服务或依赖。指纹直接来自生成的主机公钥，SSH 客户端始终进行身份校验。退出时停止本次服务并删除临时私钥；结果和无秘密的服务配置留在已忽略的 `build/ssh-test.*`。

第二个命令额外运行 macOS、iPhone、iPad 的真实 `SSH → Rust → UniFFI → SwiftTerm` 测试。测试配置以权限 0600 临时写入测试宿主的 Documents，测试读取后立即删除。每次运行带独立 UUID；退出时还会查询 Xcode 可能迁移后的模拟器数据目录，仅清理本次 UUID 的残留。产品代码不读取测试配置。三个 XCTest 结果与实际运行视图截图附件保存在 `build/phase1-*-ssh-*.xcresult`。默认使用已有的 `SSHClient iPhone 17`、`SSHClient iPad Pro 11` 模拟器，可通过 `IOS_DEVICE`、`IPAD_DEVICE` 指定本机真实存在的其他模拟器。

覆盖：Ed25519、未授权密钥拒绝、密码认证被禁用时的失败传递、未知主机确认与拒绝、密钥变更拦截、交互 PTY、`pwd`/`ls -la`、中文/Emoji/ANSI 字节、Ctrl+C、通过 `stty size` 回读 resize、正常退出、主动断开、重新连接、传输突然中断、输出积压时取消、4 MiB 双向窗口流控及交互式 top。Rust 的无服务测试另覆盖连接拒绝、握手超时、握手期间取消和释放对象。

本机服务禁止密码认证，因为测试不会创建系统账号或修改系统认证配置；因此它**不能证明密码登录成功或密码启用时的错误密码拒绝**。这两项已另用用户提供的真实外部服务器和普通账号验证，指纹来自本机已有的系统 `known_hosts`。密码仅通过关闭回显的运行时输入写入权限 0600 的临时文件，测试后已删除。根账号未使用。

## 外部测试服务

只把非秘密元数据和秘密文件路径放到临时 shell 环境中，不能把密码内容放在命令参数、环境变量或仓库里：

```sh
export SSHCLIENT_TEST_HOST='<test host>'
export SSHCLIENT_TEST_PORT='<port>'
export SSHCLIENT_TEST_USER='<test user>'
export SSHCLIENT_TEST_FINGERPRINT='SHA256:<trusted fingerprint>'
export SSHCLIENT_TEST_KEY_FILE='/absolute/private/key/file'
export SSHCLIENT_TEST_PASSWORD_FILE='/absolute/password/file'
# 加密 Ed25519 密钥需要时设置 SSHCLIENT_TEST_PASSPHRASE_FILE，内容只从文件读取。
cd rust-core
cargo test --locked -p sshclient-core --test openssh -- --ignored --test-threads=1
```

指纹必须来自服务器控制台或可信管理员，不能仅依赖当前网络 `ssh-keyscan` 的返回值。测试不会打印密码、私钥或终端输出；断言只报告稳定状态/错误代码。密码文件末尾单个换行将被去除，不要把换行作为密码的一部分。

在三端应用中人工检查：输入普通测试账号、密码或从系统文件选择器导入 OpenSSH Ed25519 私钥；核对指纹；运行 `pwd`、`ls -la`、环境有则运行 `top`/`htop`；检查 ANSI 颜色、中文、Emoji、Tab、方向键、Esc、Ctrl+C、滚动和选取。调整窗口/iPad 分栏、旋转 iPhone 并通过 `stty size` 核对行列。断开及重新输入凭据重连，再切换中英、深浅/系统外观。

必须分别记录本机集成、外部服务器、模拟器和物理设备结果。当前环境没有可信的外部服务器指纹与用户授权私钥时，不运行该外部验收，也不将本机测试描述为外部服务器已通过。

## 开发环境说明

macOS 验证构建默认放在 `${TMPDIR}/SSHClient-DerivedData`，可用 `MAC_BUILD_DIR` 覆盖。此机器在受保护的 Documents 目录内运行测试宿主时，曾停在 dyld 读取动态库的阶段；移到系统临时构建目录后正常。应用的沙盒和出站权限保持启用，没有授予完全磁盘访问。Apple 验证脚本使用互斥目录阻止同时启动多组针对同一应用的 Xcode 测试。

只重跑某个真实 SSH 用例时，可设置 `SSHCLIENT_TEST_FILTER=openssh_bidirectional_window_flow_control scripts/test-local-ssh.sh`。终端截图通过 `scripts/export-screenshots.swift` 导出；Phase 1 自动写入已忽略的 `build/phase1-screenshots/`，不把真实终端内容写入 Git。
