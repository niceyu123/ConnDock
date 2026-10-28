# Phase 3 验收方法

> 历史范围说明（2026-10-27 更新）：macOS 已正式放弃 Intel，仅支持 Apple Silicon（M 系列，arm64）。文内原有 Intel/四架构构建结果仅为历史记录，当前构建和发布范围以 `requirements.md` 与现行脚本为准。

本阶段依赖 `scripts/verify.sh` 的固定工具链，以及本机 OpenSSH 和可用的 Docker Desktop。Docker 仅用于隔离的真实 Linux 测试服务，不是产品依赖或产品功能。所有写测试只允许访问脚本创建的回环服务，不接受生产服务器。

## 基础构建与测试

```bash
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
IOS_DESTINATION='platform=iOS Simulator,id=E875305E-21B1-4FF2-93B8-C065A1C2A1E5' \
scripts/verify.sh
```

包含 Rust fmt、Clippy、默认单元测试、String Catalog、Swift 格式、四架构 XCFramework、两个 App Target 和 macOS/iPhone 基础测试。真实服务用例默认忽略/跳过，必须单独运行，不能将 skip 计为验收通过。

## 真实 SFTP 与 Linux 指标

```bash
scripts/test-linux-services.sh --quick # 小文件、权限、取消、断网与重连、监控基准
scripts/test-linux-services.sh         # 额外执行 2 GiB 上传和 2 GiB 下载
SSHCLIENT_TEST_PHASE=phase3 scripts/test-local-ssh.sh # macOS SFTP 与非 Linux 提示
scripts/test-local-ssh.sh              # 已有 PTY、流控、top、认证与取消回归
```

Linux 脚本使用固定摘要的官方 Debian 12 基础镜像构建临时 OpenSSH 测试镜像，映射 `127.0.0.1` 随机端口，生成临时 Ed25519 主机和登录密钥，只允许测试用户使用公钥登录。脚本不会开启系统远程登录、修改系统账号或用户 `~/.ssh`。测试结束删除私钥并停止/删除该容器。

工作目录是脚本创建的 `build/linux-ssh-test.<随机>/work`，以相同路径映射到容器，让 UI Runner 能只读核对远端标记。父目录权限 0700，登录私钥不放进工作挂载；工作子目录允许容器测试 UID 写入。目录名、文件名和数据均属本次可丢弃测试。无服务绑定公网，无生产凭据。

Rust 正向测试始终使用真实 OpenSSH/SFTP。大文件逐块生成非零数据及偏移头，真实发送和读回所有字节；逐字节比较，并比较流式累计校验值。没有用创建稀疏文件、只检查长度或内存 Mock 代替传输。`/usr/bin/time -l` 测量的是 Rust 测试进程，不代表 SwiftUI/UniFFI 三端内存峰值。

权限覆盖回归在服务器所在环境设置 0755/0640 后执行覆盖并读回 SFTP 属性，避免 Docker Desktop 共享文件系统的跨主机属性缓存影响预置条件。新文件默认 0600；替换现有普通文件时保留普通 rwx 权限及 UID/GID，不恢复 setuid/setgid 等特殊位，无法保留时失败。

监控用固定命令读取 `/proc` 与根文件系统的 `df -Pk /`，不在 PTY 中注入命令。独立 `docker exec` 基准读取前后计数，在窗口内传输 4 MiB 产生实际网络流量，比较 CPU/网络区间速率；CPU 容差为 10 个百分点，网络容差为 50% 或 128 KiB/s 中较大者，容纳基准读取的时间边界差异。内存总量、根磁盘容量、磁盘已用和 uptime 单独比较。容器展示的是 Linux 内核与根文件系统指标，不声称是 cgroup 容器配额指标。

## 三端桥接、生命周期与外观

```bash
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
scripts/test-linux-services.sh --apple-only
```

依次执行 macOS、iPhone、iPad 的 `testSFTPAndLinuxMonitorThroughBridge`。测试实际导入临时配置、核对指纹、连接 PTY，通过产品模型上传/下载并比较文件内容，验证目录操作、陈旧目录选择拦截、缺失本地文件的失败及重试、立即取消传输、终端保持可用、5 秒采样、暂停/恢复、隐藏停止和断开清理。

写入前强制检查 isolated fixture 标记、回环地址和独占 UUID 子目录。创建失败即退出，不清理任何预存同名文件。一次性输入仅置于测试 App 沙盒，读取后删除；脚本按运行 UUID 做最终清理。

语言和外观变化时直接断言已呈现工具 Sheet 的原生 trait 已更新，避免只检查偏好值却交付错误颜色的图片。截图为原始 XCTest 附件，导出至忽略的 `build/phase3-screenshots/`。不把文件内容和终端截图加入 Git。

## macOS 完整界面

```bash
MAC_BUILD_DIR="${TMPDIR}/SSHClient-Phase1-DerivedData" \
SSHCLIENT_TEST_PLATFORM=macos \
SSHCLIENT_TEST_METHOD=testRealSSHConnectionFormAndScreenshots \
scripts/test-linux-services.sh --apple-only
```

通过真实连接表单、系统私钥选择器、指纹确认、SwiftTerm 键盘输入进入 SFTP，验证新建目录、系统上传选择器、下载、系统保存窗口导出、内容比较及删除确认，并拍摄中英浅深工作区。运行时保持桌面空闲。系统权限弹窗、其他应用遮挡或 XCTest 事件服务失败需要独立记录，不能放宽功能断言来伪装通过。

## 取消与结果边界

- Swift Task 的取消不会自动传到当前 UniFFI 生成的异步 continuation。产品额外使用 `RemoteOperation` 取消打开过程，已建立的文件对象通过自身取消信号结束 I/O。
- 每块最多 64 KiB，队列最多 50 项、同时最多 2 项；进度更新节流。浏览有最多 10,000 项及 256 KiB 协议包限制。
- 隐藏文件面板关闭浏览 Channel，但已明确发起的文件传输继续运行；隐藏监控、离开前台或断开连接则停止采样。
- 最终文件提交进入“正在完成”，不能把已经发出的 rename 当作可确定撤销的取消。提交期间断网提示结果不确定，用户应先刷新检查。
- 连接正常时取消会尝试删除远端 `.sshclient-*.part`。真实断网后可能残留临时文件，但不将未完成数据提交为目标；不自动递归清理任意远程目录。
- 物理设备、最低系统、Intel Mac 运行与正式签名仍需另行验收。
