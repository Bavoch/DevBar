# DevBar

面向独立开发者的原生 macOS 开发工作台，以菜单栏管理本机 Web、后端、脚本、原生应用及设备／宿主项目的持续开发会话。运行的目的是让源码修改持续反映到应用中。基本运行无需额外的 Node 或 WebView。

本项目按 GitHub 开源、供其他开发者独立安装使用的产品维护。源码构建步骤见下文，协作方式见 [贡献指南](CONTRIBUTING.md)，问题报告注意事项见 [安全说明](SECURITY.md)，变更见 [CHANGELOG](CHANGELOG.md)。正式公开发行状态与待办见 [开源交付检查](docs/open-source-readiness.md)。

产品取舍与适配门槛见 [产品原则](docs/product-principles.md)；真实设备、宿主与公开分发的验收边界见 [平台矩阵](docs/platform-matrix.md)。

菜单栏显示运行项目数量，点击打开深色原生面板：顶部突出运行数量，列表直接提供项目主入口和运行／停止按钮，已停止项目单独分组。项目聚合目录内识别到的进程：桌面应用实际运行时以其为主入口；桌面应用未运行而网页服务运行时显示真实端口并打开网页。桌面应用与网页同时运行时，网页位于“更多 → 附属网页”。只唤起与项目关联的运行实例，不把已安装的旧 App 冒充开发实例。多个真实网页入口通过一个按钮选择。路径、复制地址、打开目录、设置、日志和移除收进每行的“更多”；路径只显示一处，不提供重复悬浮提示。顶部“＋”添加项目，底部刷新和退出。长列表可滚动，Esc 收起，支持 ⌘N 添加、⌘R 刷新。PID 保留在命令行诊断中。退出 DevBar 不会结束开发进程。

项目名称左侧自动展示已有图标，优先读取 Tauri/Electron 配置、HTML favicon、Web manifest 和常见图标路径，也支持常见 AppIcon 资源目录。SVG、PNG、ICO、ICNS 等资源在后台生成 64px 缩略图，在面板显示为 28pt 彩色图标，结果缓存 30 秒；缺失或损坏时使用统一文件夹图标。只读取项目内已有文件，不联网取图，不生成或改写项目资源。运行中和已停止项目均显示图标。

运行中与已停止列表分别按最近操作倒序排列；启动、停止、打开入口或目录、查看日志及切换运行方式会更新顺序。顺序保存在本机，旧项目没有操作记录时按名称排列。

启动阶段快速检测，入口出现后恢复正常频率；展开面板时每 3 秒检测，空闲时每 10 秒检测。扫描在后台执行，面板原地更新并保留项目行与滚动位置，启动／停止期间立即禁用重复操作。刚启动时显示小字“启动中…”，原生或脚本项目没有网页入口时不展示多余提示。失败时保留简短错误和可用的日志入口。

桌面端按项目配置的 bundle identifier、项目内构建产物和 GUI 进程关联，不按名称猜测。运行中的开发态 Electron 必须匹配源码入口，Electron Helper 和独立手机连接进程不作为 GUI 主应用。应用已退出、PID 变化时重新识别，禁止按相同 identifier 接管独立安装的应用、打开裸 Electron 空壳或退回附属网页。没有可打开的桌面构建时显示“桌面端未启动”。

## 自动保存

从终端、编辑器或其他工具启动的项目，识别到主进程后自动保留目录、名称和可识别的启动命令；不会执行命令或复制源码。停止或重启 DevBar 后记录仍在“已停止”列表。已有名称、命令不被自动覆盖；无法推断命令的项目保留目录，首次运行前设置命令。工具进程、只有辅助服务的目录及 DevBar 自身测试工作区不自动导入。

手动移除会记录不再自动保存该目录，防止刷新后立即加回；仍运行的服务会继续按实时发现展示。之后通过“添加项目”可重新保留。移除记录保存在 `excluded-projects.json`，配置和移除均在同一文件锁内合并处理。只读诊断不会保存项目，`--remember-running` 可显式执行一次发现与保存，`--project 目录` 可限定该目录。

## 添加与运行

点击“添加项目…”，选择源码目录后自动读取启动命令并保存，不再额外弹出命令填写框。名称默认采用目录名。识别 package.json 的 dev/start/serve/watch 脚本，以及 Swift Package、Cargo、Go 项目；包管理器优先采用 packageManager 声明，其次读取锁文件。只有无法识别时才填写名称、命令。之后可在“更多 → 设置…”修改。添加后默认持续保留项目，无需再次保存；只有手动移除才从已添加列表删除。添加只读取配置，不执行脚本；在“已停止”列表点击“运行”才启动项目。

启动命令在所选目录中通过登录 zsh 执行；支持常见 Homebrew、Bun、Cargo 路径和 NVM/.nvmrc。请使用持续运行的前台开发命令，不要使用 `&`、`nohup` 或 `open` 将实际服务交给外部后台进程。

运行默认启动持续开发会话，独立于 `.devbar.json` 的安装同步目标。Tauri/Vite/Next 等已识别的开发工具链自行热更新；没有内置监听的命令由 DevBar 监听源码并自动重新运行（包括 Swift/Rust/Go 的重新编译）。Flutter 修改后发送热重载指令。静态 HTML 使用仅绑定本机的开发服务器，修改后浏览器自动刷新。插件修改后重新构建并重载独立测试浏览器；Xcode 原生目标自动重编译、重启。构建产物和依赖目录不触发重复重启；编译失败保留日志，修改源码后重试。开发监听状态不代表每个平台的界面已经完成验收。

开发启动会拒绝构建预览、直接运行发布目录和裸 Electron 入口。桌面会话按项目声明的 bundle identifier 识别同产品安装实例，先请求优雅退出，再运行开发入口；退出被拒绝时报告失败，不强行终止。项目内旧 `.app` 同样不会被当作开发窗口。失败会话可以直接重新运行；“更多 → 重启开发”只重启所选受管目标。

停止按钮针对项目范围内可识别的进程，可能包含多个服务，悬停会说明范围；停止后配置仍然保留，可再次运行。当前不支持同一项目内各目标独立启停：其他服务运行时项目仍被视为运行，无法从该行单独启动另一目标。自动发现的项目第一次停止时会自动保留目录；没有可靠的命令建议时，再次运行会先要求设置启动命令。“更多 → 设置…”可修改名称和命令，“查看日志”打开启动输出。“移除”只移除保存的配置，不删除源码，也不停止正在运行的程序。

配置、启动记录与日志保存在 `~/Library/Application Support/DevBar/`，文件权限为仅当前用户可读写。启动失败保留日志，菜单显示退出状态或错误。不会自动安装依赖，不会自动执行刚添加的项目。启动前检查是否已运行，防止重复启动。

DevBar 启动的项目使用独立进程组；停止时先发送 SIGTERM，短暂宽限后若该进程组仍未退出（Electron/Chromium 等桌面运行时常忽略 SIGTERM），再对该组升级为 SIGKILL，确保点击“停止”能够真正关闭应用，并处理已识别的后代进程。从终端启动的项目按已验证的主进程及其后代停止，不结束终端、编辑器或独立 MCP 工具所在的进程组，也不会对这类外部进程强制结束。DSH、Claude、Codex 等编程助手及其控制端口不计为项目运行；仅运行工具的启动器也不计入。会核对进程用户和启动时间，避免使用过期 PID。无法可靠关联主进程的程序不提供停止操作。

识别 Agentation、Blender MCP、浏览器自动化等已知工具，辅助端口不再与项目网页入口混排。只有这些工具运行时，不再单独计为运行中的项目。Node 调试端口归入辅助服务。端口按网页、接口、服务、调试、内部、工具及待确认分类。未确认用途的监听不会自动成为网页入口，也不会丢弃。

被系统接管且只使用控制文件描述符和动态内部绑定的嵌入式 Worker，不能单独证明宿主项目仍在运行；DevBar 不以它维持“运行中”或自动结束它。仍有明确公开绑定的独立 Worker 和拥有存活上层进程的运行时继续正常识别。

端口归属先核对进程树、调试参数和框架公开绑定，再验证实际 HTTP 响应。Electron `--remote-debugging-port`、Node `--inspect` 等参数优先识别；不按 9222/9229 这样的端口号码一刀切。Next.js、Vite、Astro、Wrangler/workerd 的内部控制监听不会混入网页；嵌套框架保持各自的绑定范围。指定端口未实际绑定、框架自动换端口时会验证真实监听。多个独立页面保持多个入口。

HTML 页面、认证 HTML 登录页和合法 HTTP(S) 跳转可作为网页；JSON（包括 `+json`）归为接口，401 文本和根路径 404 等响应归为服务，非 HTTP 或超时监听标为待确认。后端项目会显示服务端口并保持启停能力。没有端口的本地脚本或原生项目仍按运行进程展示。

探测优先使用 HEAD；只有 405/501 才回退 GET，并在响应头到达时取消，不下载响应正文。探测最多 4 路并发，短时缓存；不携带 Cookie 或凭据、不跟随跳转，不绕过 HTTPS 证书验证。每个监听在 `--scan-json` 的 `portDetails` 中有类别及判断原因。

## 自动接入运行版本核对

项目已有明确入口时，不需要逐个填写 `.devbar.json`。Web、精确静态页、Worker、浏览器插件、Xcode 模拟器、Swift 原生程序、可推导的 macOS App、OMP/DSH 宿主插件，以及可确认成员的组合启动可自动建立同步计划。已有显式配置优先。普通“运行”也会对可自动验证的进程建立运行证据；“更多 → 更新”使用当前选择的目标，其他目标渐进展开。

证据在真实运行进程、设备或宿主中核对。源码变化、未就绪页面、缺少成员、异平台占位程序与外部实例不会被标成 `current`；非 HTTP 作业的版本证明不代表业务健康。不会为凑覆盖率生成应用入口或自动接管任意外部进程。当前逐类结果和剩余差距见 [本机覆盖记录](docs/local-project-coverage.md)。

## 构建与启动

需要 macOS 13+、Xcode Command Line Tools 和 Swift 5.9+。

```sh
zsh scripts/build.sh
open dist/DevBar.app
```

可将 App 拖入“应用程序”。本地构建使用临时签名，未公证。

## 识别范围

读取当前用户的 TCP 监听端口、运行进程的可执行文件位置与工作目录，向上查找 package.json、Cargo.toml、Package.swift、pyproject.toml、go.mod、.git 等项目标记。同一目录的进程和端口合并为一个项目，IPv4/IPv6 同端口去重。支持无端口的 Node、Python、Ruby、PHP、Java、Go 等运行时，以及源码目录内编译的原生二进制。SwiftPM、Rust 和 Electron 的本地产物可回溯到源码；Xcode DerivedData 通过 info.plist 中的 WorkspacePath 关联源码。

自动发现排除系统、Homebrew、系统临时目录、Library、已安装到 /Applications 的 App 和隐藏源码目录。手动保存的目录优先作为项目边界，也支持没有项目标记文件的目录。DevBar 自身不计入列表。Tauri 原生端与前端归入同一项目。列表要求至少识别到一个主服务、源码程序或脚本，不再仅因残留运行时/工具启动器将项目计为运行中。无法关联源码的已安装 App 不会猜测归属。Xcode 路径解析已实现，但尚未通过真实 Xcode 调试会话验证。

本机进程扫描不读取远程服务器或 Docker 容器内部进程；可通过 external 同步适配器显式接入专用驱动，也不把普通浏览器标签页当作开发项目。浏览器里的本地 Web 项目根据其开发服务识别。完整端口诊断是监听状态，网页入口识别也不代表应用整体健康检查；支持证书有效的本地 HTTPS 探测，自签证书不自动放行；自定义域名和非 HTTP 服务需要对应客户端。无需管理员权限，不读取密钥文件或浏览器数据。扫描期间在内存中检查命令行以识别工具，不记录原始扫描命令行；你填写的启动命令会保存在配置文件中，启动进程继承当前环境。

命令行诊断与检查（无需启动界面）：

```sh
.build/release/DevBar --scan-json
.build/release/DevBar --self-test
.build/release/DevBar --self-test-menu-refresh
.build/release/DevBar --menu-json
python3 scripts/verify.py
python3 scripts/verify_lifecycle.py
python3 scripts/verify_stop_latency.py
python3 scripts/verify_icons.py
python3 scripts/verify_entrypoints.py
python3 scripts/verify_port_roles.py
python3 scripts/verify_desktop.py
python3 scripts/verify_autosave.py
```

使用 `.build/release/DevBar --render-panel 预览.png` 可在不弹出窗口的情况下渲染真实项目面板；`--self-test-panel` 检查按钮分发、忙碌／失败／空列表、长列表滚动和 Esc。

使用 `.build/release/DevBar --icon-project 项目目录` 可查看实际读取的图标来源和缩略图尺寸。

可通过环境变量 `DEVBAR_DATA_DIR` 使用隔离的数据目录进行诊断和测试。支持 `--add-project 目录 --name 名称 --command 命令`、`--list-projects`、`--start-project ID`、`--stop-project ID`、`--remove-project ID`。这些命令使用与菜单相同的存储和运行控制代码。`--start-project ID --wait` 保持 CLI 等待并记录退出状态。

使用 `--desktop-project 项目目录` 可只读检查桌面入口；`--open-desktop-project 项目目录` 使用与面板相同的应用打开逻辑。

## 运行版本

版本徽章只有两个来源：开发会话与受管目标回执。会话运行中不显示徽章（会话自己负责加载最新源码）；橙色“源码已变”表示受管安装类目标的源码已变化、待更新；灰色“版本待确认”表示受管目标证据不完整。非 DevBar 启动的普通进程不显示版本徽章——DevBar 对其一无所知，不做猜测。开发会话失败时项目行以橙色文字提示“开发运行失败；修改后自动重试”。

v2 起不再做内容指纹启发式（源码/产物哈希对比、观察基线均已移除），状态含义收敛为：会话运行中 / 源码已变 / 运行失败 / 版本待确认。可用 `--freshness-project 目录` 只读诊断，`--self-test-freshness` 验证判断逻辑。

项目行只保留一个启停按钮：停止时为播放三角形，运行时为停止方块。点击运行中的项目名称或“更多 → 打开网页／打开应用”可打开对应入口；启动、停止期间立即显示进度并禁用重复操作，停止只做一次轻量进程扫描（不重复完整端口探测），完成后立即把该项目移出“运行中”，不再等待下一轮完整扫描。

点击面板外部（含桌面、其他应用和本应用的其他窗口）会关闭面板；面板内、菜单和状态栏按钮继续正常交互。面板关闭后移除鼠标监听，不拦截外部点击。`--self-test-dismissal` 可离屏检查关闭判断与监听生命周期。

WorkBuddy、OMP、Claude 等开发代理及其控制监听归为工具，不作为项目接口或网页；进程识别忽略提示词、内联代码和工具配置参数中的框架／端口文字。代理启动的真实开发服务仍独立识别。

## 运行方式（0.9）

添加项目时读取本地配置，默认采用已确认的主要运行方式；多端项目可在停止后通过“更多 → 运行方式”选择桌面端、网页端、移动端、后端或子应用。选择会持久保存，已有自定义命令不会被自动覆盖。静态多页面可选择具体 HTML；URL 对空格和特殊字符编码。

- Electron／Tauri 优先桌面启动脚本，明确选择网页端后不会再打开已安装桌面应用。原生 SwiftPM、带 Info.plist 的 macOS 应用、Xcode 工程有独立入口。库不生成猜测的 `swift run`／`cargo run`／`go run`。
- Node 按 packageManager／锁文件和工作区继承关系选择 npm、pnpm、yarn 或 bun；仅选择 dev／start／serve 等运行脚本，不把 build、deploy、数据库迁移或测试当作默认服务。Python 读取声明的 console_scripts 或明确存在的应用入口，并优先本地虚拟环境。
- iOS 工程通过 XcodeGen（需要时）、xcodebuild 和 simctl 构建、安装、运行到可用 iPhone 模拟器；记录具体设备、bundle 和进程身份。打开会回到对应模拟器应用，停止仅针对该项目。Expo 区分 Metro 开发服务、iOS 原生 App、Android 和 Web；静态 app.json 可确定标识的 Expo iOS 目标会启动 Metro 并构建、核对模拟器进程。动态配置和自定义脚本仍由项目自身负责。
- 浏览器插件读取 Manifest V3，检查主要入口和图标资源；需要构建时使用已有 build 脚本。使用独立 Chromium／Chrome for Testing 会话及独立资料目录；不修改日常浏览器资料。内部调试端口不会成为网页入口。普通 Chrome 已移除命令行加载插件支持，不能冒充一键加载。外部 Chromium 的显式 load-extension 会话可识别和打开，但不提供结束整个外部浏览器的停止按钮。[Chromium 官方说明](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/1-g8EFx2BBY/m/S0ET5wPjCAAJ)
- Taro／微信小程序运行编译监听，并可在“开发工具”中打开对应微信开发者工具工程；不会把监听状态称为小程序已运行。Android、Flutter、真机开发脚本检查所需环境；Android SDK、设备、签名、账号和设备权限仍是前提。不自动安装 SDK、登录账号、发布或部署生产服务。

扫描和目录审查只读配置，不启动工程或执行 package scripts。模拟器运行方式来自 [Apple 工具链](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)；Metro 和本机原生构建是 [Expo 的不同阶段](https://docs.expo.dev/guides/local-app-development/)。

诊断：`--profile-project 目录` 输出所有运行方式和环境缺项；`--select-target 项目ID --target 目标ID` 切换已保存项目；`--run-target 目录 --target 目标ID` 执行专用目标。测试用 `DEVBAR_HEADLESS=1` 使专用浏览器无头启动，且不打开模拟器前台窗口。

完整目录审查：`python3 scripts/audit_projects.py --output 审查.json`，同时生成 Markdown。`verify_profiles.py`、`verify_target_runtime.py extension`、`verify_target_runtime.py ios`、`verify_target_routes.py` 覆盖运行方式选择、真实无头插件加载、模拟器生命周期及路由隔离。iOS 测试需要 Xcode、XcodeGen 和已安装模拟器运行时。

外部启动的 iOS 模拟器 App 按 CoreSimulator 中的 App bundle、源码配置的唯一 bundle identifier、设备 UDID 和实际进程身份关联；标识在多个源码工程中重复时不猜测归属。真实手机内进程不属于本机进程扫描，真机脚本状态不会冒充手机应用状态。

## 任务完成后的统一更新（0.11）

DevBar 提供统一的同步、核对和诊断协议：

```sh
devbar doctor /path/to/project --json
devbar inventory /path/to/workspace --json
devbar init /path/to/project --target 运行目标ID --plan
devbar sync /path/to/project --target 更新目标ID --json
devbar status /path/to/project --target 更新目标ID --json
```

项目根目录 `.devbar.json` 配置更新目标；单目标可省略 `--target`，多目标必须明确选择。支持 macOS 应用包、开发会话（process）、独立无头浏览器插件、iOS 模拟器以及 androidDevice、iosDevice、windowsSSH、blender、omp、dsh、dockerCompose 内置驱动和 external 扩展协议。process 目标即开发会话：源码变化自动重启，会话存活即 current，无需版本探针；其余目标仍按协议核对运行证据。

macOS 应用包先构建校验，再优雅退出指定安装位置的旧 App，暂存替换并核对新进程，失败恢复旧应用。受管会话只停止自身记录并核对身份的进程；外部已有实例不会被静默接管。插件采用独立无头 Chromium，不操作日常浏览器。iOS 模拟器核对实际设备、安装内容和进程；真机、Android、Flutter、容器、DSH/OMP 宿主需提供实际目标取证的专用驱动，不能用本机任务状态代替。

已配置项目在“更多”中可直接“更新应用”。环境检查由命令行 `devbar doctor` 提供。App 自带独立 CLI 与安装器，首次可执行 App 内的 `Contents/Resources/install-cli.sh`；开发者也可执行 `zsh scripts/install-cli.sh`。只读 `init --plan` 展示配置草稿，`--write` 才创建文件且不覆盖已有配置。

配置字段、JSON 退出码、版本证明及边界见 [本地更新协议](docs/sync-contract.md)，签名、公证、分发包测试和完整验收矩阵见 [发布与验收](docs/release.md)。

项目审查使用 `python3 scripts/audit_projects.py --output work/coverage.json`，包含项目角色、运行方式、同步适配器与缺项。素材、库、宿主插件、容器、备份、内嵌组件及空目录明确分类；审查只读，不代表全部真实应用已执行或验收。

## 开发运行与兼容同步协议

面板不再提供“更新应用”、更新设置或自动打包安装开关，也不读取已有自动更新开关执行后台安装。“运行”始终进入开发会话，已有自定义开发命令保留。`.devbar.json` 不得把 `npm run dev` 改写为构建安装。

上面的 `sync/status` CLI 作为本地安装与外部集成的兼容协议保留，不参与面板的开发生命周期。它不能用来代替热更新，也不证明开发会话已应用修改。DevBar 自身任务收尾按工作区约束使用该协议更新本地工具。

未支持的宿主、真机与自定义命令需要具体运行环境验收；仅启动命令、开启监听或 HTTP 200 不代表所有设备和页面已自动刷新。只有现成应用包、没有源码构建入口的项目不能冒充开发会话。
