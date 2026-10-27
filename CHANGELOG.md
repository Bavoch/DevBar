# Changelog

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
