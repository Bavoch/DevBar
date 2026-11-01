# 开发启动与权限边界

普通运行通过独立 launchd 后台任务执行项目已保存的开发命令，例如 `npm run dev`、`pnpm dev`、项目自己的 watch 脚本。命令、参数、工作目录及项目环境按配置保留；包脚本解析只用于识别与校验，不替换实际命令。

DevBar 负责启动、停止、日志及状态。热更新、源码监听、原生重编译、应用启动身份、签名和隐私请求由项目自己的开发入口负责。DevBar 不注入 Cargo runner，不复制或包装应用，不选择签名证书，不改 bundle identifier、Info.plist、项目配置或系统 TCC 权限，也不在项目源码变化时额外重启进程或发送 Flutter 热重载输入。项目命令失败后记录真实退出码，等待明确重试，不靠隐藏的等待进程或自动重启假装仍在运行。

## 统一执行与停止

| 环节 | 实现入口 | 责任 |
| --- | --- | --- |
| 选择入口 | `ProjectProfiles.profile`、`ProjectStore.suggestion` | 优先使用项目声明的开发脚本，跳过不可用建议 |
| 启动校验 | `ProjectRunner.prepared` | 校验本地前台命令，普通运行拒绝隐式构建适配器 |
| 执行 | `ProjectRunner.start` → `CommandExecution.spawn` → `LaunchIsolation.spawn` | 后台观察进程与原命令各用独立系统任务，不打开 Terminal |
| 状态 | `ProjectPresentation.read`、`RuntimeFreshnessInspector.inspect` | 显示命令存活、可核验就绪、实际退出与失败 |
| 停止 | `ProjectRunner.stop`、`CommandExecution.stop` | 核对会话与进程身份，清理自己的任务及后代 |

所有普通项目默认共用独立 launchd 后台执行后端，无需设置 `DEVBAR_HEADLESS`，不打开或激活 Terminal。命令由登录 shell 执行，加载登录环境并补充已支持的工具链路径；标准输出和错误写入日志，没有交互终端输入或 TTY。需要密码输入或交互问答的命令应先在终端完成准备。

DevBar 只观察存活、可核验入口及退出，不遍历源码。后台观察进程不因源码变更额外重启项目。每个目标记录任务标识、PID、进程签名、用户、进程组和会话 token。停止仅作用于已核对的任务及后代；观察进程异常退出后，仍可按记录清理自己的子进程。独立启动的同目录进程不因目录相同而被误认成受管进程。旧 Terminal 会话仍保留状态读取和停止兼容。

有服务入口或应用实例时可核对就绪；只有命令存活时只说明命令运行中。DevBar 不把存活状态宣称为热更新、业务健康或隐私能力已经通过验收。

## 权限正确归属的具体含义

DevBar 不把自己的应用身份借给项目，不复制应用、换 bundle identifier 或选择证书重签。后台命令不继承 Terminal 已有的录屏等隐私授权；具体权限主体由 macOS 按实际运行身份判断。DevBar 不自动申请录屏、辅助功能、完全磁盘访问或控制 Terminal 的自动化权限。需要这些能力的项目应以实际应用身份单独验收。

自动发现不会探查未明确添加的文稿、桌面、下载和云盘目录。用户明确添加的目录单独处理；不能因为某个无关进程的路径落在私人文件夹中就触发整目录访问申请。

已存在的应用授权不能自动视为其他标识、签名或路径的授权。DevBar 不读取或修改 TCC 数据库，不自动授权或重置。此前注入的开发应用、runner 及相关运行记录在对应会话停止后清理；不改项目自己的应用或授权。

## 显式工具与普通运行

`.devbar.json` 的安装同步、原生构建适配器等是显式工具流程，不是普通启动的隐式后备方案。只有这些适配器而没有项目开发入口时，普通运行要求配置原本的 dev/watch 命令，不冒充开发热更新。普通运行不会因为目标叫 `dev` 自动转入同步、构建、安装或签名流程。

## 验证

`verify_development_isolation.py` 验证不同项目共用相同执行契约：保留参数、工作目录、自定义 runner 与原有应用文件；项目自己的监听更新继续工作；没有监听的命令不会被 DevBar 偷偷重启；退出和显式重试如实反馈。`verify_permission_ownership.py` 验证完整祖先进程链、真实 TCC 录屏权限预检、任务清理及公开 Launch Services 工具边界。预检不代表真实录像成功，也不能保证其他项目原命令的权限主体。

公开机制参考：`man launchctl`、`man launchd.plist`、`man open`，以及 https://developer.apple.com/documentation/appkit/nsworkspace 。

以下是切换后台启动前的历史验收，不代表当前后台路径的隐私权限验收。

2026-10-31 本机终端验收：通过普通启动后端执行原开发命令，三路标准流均为 TTY、工作目录正确；实际系统录屏生成约 2 秒、400×300 视频，TCC 责任主体为 `com.apple.Terminal` 且 Allowed。QuiX 当前运行原 `npm run dev → tauri dev`，祖先进程链包含 Terminal，不含 DevBar；没有开发应用包装或重签。

2026-11-01 复验：QuiX 与 DevBar 均通过各自原 `npm run dev` 入口在 Terminal 中运行。QuiX 为 `tauri dev`；DevBar 的仓库监听位于 `scripts/watch-dev.py`，只编译并运行 debug 产物。通用命令保留和运行安全回归通过；普通终端后端再次生成 2.018 秒、400×300 视频，退出码 0。此记录不替代 QuiX 应用内录屏交互验收。

本机清理：已从系统设置移除 DevBar 的录屏、辅助功能、文件与文件夹、完全磁盘访问和 App 管理记录；未发现其麦克风、相机和自动化记录。旧 QuiX Dev 应用移至废纸篓；旧包装与 runner 目录已清除，6 个失效任务目录于 2026-11-01 归档至用户数据目录中的 `cleanup-backup-2026-11-01`。未清空 TCC 数据库、未批量撤销其他工具权限。自动发现不再访问未明确添加的私人目录。
