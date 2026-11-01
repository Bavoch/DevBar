# Changelog

## 0.16.0 — Unreleased

- 列表滚动条改为 overlay 悬浮式并弱化（贴面板右缘、半透明），不再占据内容空间；列表内容内边距保持不变。
- 面板行状态文字从「运行中」改为显示实际运行端口（如 localhost:5173，多入口标注数量）；桌面应用、模拟器等非端口目标显示对应运行方式，停止的项目没有运行端口、保持「已停止」。
- 面板新增项目搜索：列表上方搜索框按名称、路径或状态即时过滤，Esc 先清空搜索再关闭面板；搜索框仅在点击时按需取得键盘焦点，面板保持非激活样式、不改变前台应用。
- 面板按钮统一为简洁的无底色单色样式：移除图标按钮的常驻背景与强调色，悬停时显示中性半透明背景并提亮图标；空列表「添加项目」改为纯文本按钮。
- 移除「使用帮助」菜单项及其处理逻辑。
- 面向个人 AI 构建者精简为单一项目列表与运行、打开、停止主流程；自定义命令按需展开。
- 面板操作统一到顶部标题栏：刷新与更多菜单移入标题栏，移除底部操作栏，扫描错误提示改在标题栏展示。
- 统一项目运行控制，不展示启动来源；发现的运行也可停止和重启，执行前核对入口与具体进程身份，保护终端、AI 工具及无关服务。
- 监督进程异常退出后保留可核对的子进程归属，恢复停止能力；多运行方式独立管理。
- 区分启动与运行失败，失败监督进程不计入运行数量；状态从后台快照生成。
- 自动接入统一使用本地运行入口，删除自动推断安装替换和维护者目录扫描。
- 拒绝自动选择发布、部署、脱离管理、构建预览及危险生命周期脚本；诊断与实际运行校验保持一致。
- 项目列表校验重复项和非法路径，损坏配置保留原文件；运行中不能移除管理记录。
- 刷新产品说明与隔离回归；公开分发仍需正式签名、公证、许可与平台验收。

## 0.15.0 — Unreleased

统一运行模型重构（破坏性变更，协议 v2）：

- **process 目标统一为「开发会话」**：`devbar sync` 对 process 目标建立/复用带源码监视的开发会话，源码变化自动重启（工具链自带 watch 时不重复干预，Flutter 热重载）；会话存活即 current。一次性冷启动、adopt 接管、witness 注入、版本回执、EADDRINUSE 换端口重试均已移除；`runtimeWitness` 字段被容忍但忽略。
- **不再退出同产品安装版**：`stopInstalledConflicts` 删除。开发会话失败且检测到同 bundle id 安装版在运行时，只在原因中提示手动处理，绝不代替用户退出应用。
- **状态收敛**：徽章状态从 6+7 种收敛为 运行中/源码已变/运行失败/版本待确认；内容指纹启发式与 `freshness/` 观察基线移除；纯 web 项目的徽章强制隐藏取消。
- **可靠性**：源码监视失败（>20 万文件或读取错误）降级为“不监视”而不是终止会话；目录级读取错误跳过子树；HTTP 探针超时 0.65s→1.5s 并重试一次，unknown 缓存 2s→5s。
- **清理**：删除休眠的自动更新引擎（AutomaticUpdates/ProjectUpdateSetup/autoUpdateTarget）与 `--managed-start` 入口；`--self-test-freshness` 重写为会话/回执双源断言。
- **文档**：sync-contract 升级 v2；schema 中 runtimeWitness 标记 deprecated。


## 0.14.1 — Unreleased

- Add an application-update setup entry that remains available when configuration
  is missing or invalid, and allow automatic updates to be disabled in that state.
- Offer reviewed recovery drafts from the selected project's previous successful
  update; saving never overwrites an existing configuration.
- Pause automatic updates for missing/changed targets and mismatched installation
  paths, and show version uncertainty instead of claiming an outdated build.
- Ignore delayed update events after automatic updates have been disabled.
- Add contributor/reporting templates, isolated product checks and macOS CI.

Earlier local development releases are described in the existing release and
platform documentation; they are not retroactively certified public releases.
