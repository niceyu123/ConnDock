# Phase 7：终端分屏与 SSH Config 导入

用户已授权剩余 P1/P2 按阶段完成。本阶段以 requirements.md 为唯一需求源，先交付不改变网络协议和凭据策略的工作区能力。依据 AGENTS.md，自主完成实现与验证，不增加普通设计选择的审批检查点。

## 方案与取舍

- 分屏采用现有标签的两窗格组合，复用各自 TerminalSession/SwiftTerm，不复制会话、不广播输入；相比同一 transport 下新增 PTY，生命周期改动更小，也支持查看已有会话。每组最多两窗格，支持左右/上下排列、调整比例、焦点切换、取消分屏和关闭单个标签。macOS/iPad regular 展示分屏，iPhone compact 展示所选标签，分组保持。
- SSH Config 使用应用内纯解析器，文件选择→预览→勾选→导入。相比启动系统 ssh -G，无任意命令执行或外部配置副作用。支持明确 Host 别名、HostName、User、Port、通配 Host 默认值与首值优先语义；未支持的 ProxyJump/ProxyCommand/Match/Include 等必须提示并阻止受影响条目静默直连。IdentityFile 只提示用户另选私钥，不读取文件，不存私钥路径为凭据。
- 不自动连接、导入凭据、执行本地命令或修改外部 SSH 配置。现有主机不自动覆盖；导入复用 HostLibrary 的本地与同步变更路径。

## 验证

分屏模型覆盖组合/选择/关闭/取消、会话实例保持、命令目标绑定；SSH Config 覆盖引号、注释、通配默认值、首值优先、危险指令和无效数据。所有新增 UI 同时提供 zh-Hans/en，构建 macOS/iOS arm64，运行统一 verify 与适当 UI 检查。真实云端和物理设备状态独立记录。
