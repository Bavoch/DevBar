# 发布与验收

DevBar 是原生 macOS 产品。本地开发构建与可公开分发的签名、公证发行包分开处理。

## 构建与命令安装

`zsh scripts/build.sh` 生成自包含的 `dist/DevBar.app`，包括 CLI 和安装器。开发构建默认临时签名。首次安装命令行可执行 App 内的 `Contents/Resources/install-cli.sh`，入口安装到当前用户 `.local/bin`；不需要源码目录、Node、管理员权限或后台 HTTP 服务。现有第三方同名命令不会被覆盖。

复制或移动 App 后，可重新运行新位置中的安装器更新命令入口。发行包不得指向开发者机器的 `.build/release`。用户项目和日志数据独立保存，升级 App 不清除配置。

## 验收矩阵

| 证据 | 检查 |
|---|---|
| 工程识别/配置/环境 | verify_profiles.py、verify_product_portability.py、audit_projects.py、doctor/inventory 的机器可读诊断 |
| macOS 更新与恢复 | verify_sync.py：真实无窗口 App v1/v2，失败保留、并发、超时、启动失败恢复 |
| Web/后台受管进程 | verify_runtime_sync.py：实际 HTTP 运行版本、旧实例退出、无探针不成功、独立宿主适配器 |
| 浏览器插件 | verify_extension_sync.py：实际无头 MV3 后台和无后台插件文档，更新、身份与内容核对 |
| iOS 模拟器 | verify_ios_sync.py：真实构建/安装/更新，应用写出的运行版本/PID，与原生包内容比较 |
| 原有生命周期 | verify_lifecycle.py、verify_freshness.py、verify_desktop.py、verify_entrypoints.py、verify_target_routes.py |
| 分发包 | verify_distribution.py：移动后的 App、CLI 与安装器，独立工作目录，无源码依赖 |
| 原生界面 | 离屏 --self-test-panel、--self-test-menu-refresh 与 --render-panel；不替代真人交互体验验收 |

配置发现是只读测试，不启动目录里的全部应用，也不执行发布、迁移或真实第三方操作。Android/真机和 Blender/OMP/DSH 使用内置驱动，本地 Compose 使用 dockerCompose，其他未实现的宿主仍使用 external 协议；各驱动需要自己的设备端端到端验收。无对应设备、签名、账号时必须明确阻碍。

## 正式分发

使用 Developer ID Application 证书设置 `DEVBAR_SIGN_IDENTITY` 后构建，启用 hardened runtime 与签名时间戳。`scripts/package-release.sh` 负责核对身份、打包，只有显式 `--notarize` 才上传 Apple 公证并装订票据。公证凭据使用已配置的 Keychain profile，不将账号密钥写入源码。

未完成 Developer ID 签名、公证、Gatekeeper 验证以及目标 macOS/CPU 的实际测试前，不称为正式可公开分发版本。当前主机构建仅对应当前 CPU；此处不声称 Intel、所有 macOS 版本或手机设备均已通过。

发行前运行适用的验收矩阵，核对版本、配置兼容性、CLI 退出码及发行 App 内容。保留明确的未验证项；不以“识别所有目录”代替“全部应用运行成功”。

### 0.11 additional platform gates

- `scripts/verify_host_drivers.py`: real Blender/OMP v1→v2 through sync/status/stop.
- `scripts/verify_windows_native.ps1`: real Windows native lifecycle. Run on a
  Windows runner, not under Wine. Transport and persistent remote-host acceptance
  must be reported separately from this native test.
- `drivers/sdk`: mobile app instrumentation; simulator tests never replace a
  connected physical-device install/launch/proof acceptance.
- DSH: verify actual client apply through the official web profile and headless
  Chromium; no foreground window and no mutation of a personal DSH profile.

- Native transports run Python with bytecode writes disabled. After testing
  native drivers against a packaged App, verify its signature again and assert
  that no `__pycache__` directory appeared inside the App bundle.
- See `platform-matrix.md` for remaining hardware, host and distribution gates.

### 工具链与扫描边界回归

`verify_product_portability.py` 用隔离目录检查重命名 Xcode、自定义 Android SDK、PATH 内 adb、工作区带冒号脚本、未知包管理器、顶层软链接及整体阻断状态；不执行工程脚本，不打开窗口。Xcode 路径优先遵循 DEVELOPER_DIR，否则读取 xcode-select；仅安装 Command Line Tools 不算完整 Xcode。Android 检测与受管命令均支持 ANDROID_HOME/ANDROID_SDK_ROOT。

## 自动接入回归

- `verify_automatic_sync.py`：无配置 Node/静态页、精确文档、独立源码测量、编译端口排除、更新与停止。
- `verify_group_sync.py` / `verify_compound_start.py`：组合成员、前置顺序、普通运行、全成员证据、失败清理与循环拒绝。
- `verify_node_graph.py`：保留项目 ESM 编排和预检、Node + 实际 workerd、成员丢失失效。
- `verify_node_process.py` / `verify_python_automatic.py`：实际入口加载、非 HTTP 作业输出 v1→v2、旧缓存与源码变化、独立停止。
- `verify_worker_automatic.py`：项目/已安装 CLI、实际 workerd、原配置兼容标记/变量/静态资产路由、v1→v2。
- `verify_swift_automatic.py` / `verify_frontend_adoption.py`：真实原生可执行文件、严格身份、保守外部接入与端口冲突。
- `accept_sync_plans.py` / `accept_automatic_projects.py` / `accept_group_project.py`：实际工程只读计划及按类隔离运行验收；计划通过不算真实应用验收。

## 开源协作与基础 CI

贡献者先构建一次，再执行 `python3 scripts/check-product.py`。GitHub Actions
使用同一个隔离入口；不带签名凭据，不发布应用，不访问维护者的个人工程。
更完整的设备、宿主和权限归属验收继续按上面的矩阵选择。基础 CI 不能代替
Developer ID、公证和 Gatekeeper，也不能证明其他 CPU 或最低 macOS 版本。

`package-release.sh` 为生成的 ZIP 同时写出 `.sha256`；公证模式的校验值针对
最终装订后重新打包的文件。发布前检查 LICENSE、版本、CHANGELOG、安全报告
入口与 [开源交付检查](open-source-readiness.md)，不要把未公证包标成正式发行。
