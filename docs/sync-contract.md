# 本地更新协议 v2

此文档面向可选 CLI 集成。普通用户使用菜单栏的运行、打开、停止即可。process 目标按项目本地运行入口建立会话；安装替换、设备和宿主操作只来自明确配置。配置识别、命令运行、版本核对和功能验收分别表达。

## 命令与兼容性

```sh
devbar inventory /path/to/workspace --json
devbar doctor /path/to/project --json
devbar init /path/to/project --target 运行目标ID --plan
devbar init /path/to/project --target 运行目标ID --write
devbar sync /path/to/project --target 更新目标ID --json
devbar status /path/to/project --target 更新目标ID --json
devbar stop /path/to/project --target 更新目标ID --json
```

`inventory` 遍历项目配置，不执行项目脚本，输出扫描限制与跳过范围；上限 50,000 个目录、10 层，超限不会声称完整。`doctor` 输出项目角色、运行目标、同步策略、环境缺项与修复建议，不调用自定义探针。`init` 默认只生成草稿，只有 `--write` 才排他创建 `.devbar.json`，绝不覆盖已有文件。

`sync --plan` 不执行构建、启动或探针。`sync` 不安装 SDK、不安装 npm 依赖、不登录账号、不隐式部署生产。项目配置中的命令与 package scripts 一样是可执行代码，应只来自可信项目。`status` 不启动、停止或构建，但会执行已配置且声明只读的 `proofCommand`。

多个同步目标必须显式选择 `--target`；单目标可以省略。未知命令、未知字段、适配器不适用字段、未来 schemaVersion 均拒绝执行。原有 `--sync-project`、`--sync-status` 及诊断参数兼容。

JSON 包含 `schemaVersion: 1`。日期为 ISO 8601；私有存储属于内部格式。退出码 `0`：已验证 current、只读 planned 或成功配置；`1`：setupRequired、failed；`2`：busy、sourceChanged、artifactChanged、stopped、unconfirmed、externalRuntime（runningUnverified 仅保留给缺少探针的 expo:ios）。process 目标返回 starting（仍在启动，退出码 2）、current（命令运行中）、failed（运行失败）、stopped（已停止）、externalRuntime（目录已有外部进程）或 busy。current 不证明源码或业务功能正确。`stop` 成功退出码为 0。doctor/inventory 的 ready 只表示该次诊断完成，不表示应用版本为 current。

## 基础适配器

| strategy | 生命周期 | current 必需的证据 |
|---|---|---|
| macBundle（兼容旧版省略 strategy） | 构建 → 暂存 → 优雅退出指定 App → 替换安装 → 新进程；失败恢复旧 App | 构建前后源码稳定，完整 App 哈希，新 PID/启动身份/路径/bundle identifier |
| process | 建立/复用原项目开发命令的会话：不监视源码、不注入重启或 Flutter 热重载；按命令存活与可核验入口显示状态 | 核对监督进程与记录的运行子进程身份，失败等待中的监督进程不算运行；无版本回执
| extension | 构建（需要时）→ 重启专用浏览器会话 | 独立无头 Chromium 的真实插件后台或插件文档、插件身份、产物内容与新会话 |
| iosSimulator | Xcode 构建/安装/启动到明确的模拟器 | 设备 UDID、bundle identifier、真实 PID、构建与已安装应用的完整内容 |
| external | 显式 syncCommand → 专用只读 proofCommand | 设备、容器或宿主实际返回的版本、同步标识和实例身份 |

macBundle 安装位置必须与产物分开，且不得相互嵌套、不得包含源码目录。已有安装目标必须同一 identifier。构建在停止原应用之前执行；不强制终止有未保存工作的 App。旧 App 保留到新实例通过检查，恢复失败会保留备份并返回路径。构建命令自身必须只负责构建，不能自行覆盖运行安装位置。

process 的 startCommand 必须是持续以前台运行的 dev/watch 开发命令，不能用 `&`、`nohup` 或 `open` 脱离生命周期，也不能是构建预览或安装包启动。会话状态记录在数据目录 `development/`，进程身份由 launchd 任务记录（RunRecord）和运行令牌绑定的子进程记录确定；不按项目名杀进程，不结束日常浏览器或 AI。同一个明确目标已有运行时返回运行状态，重复 sync 不替换它；多个运行方式无法确认归属时提示确认，保留现有运行；同产品安装版与开发会话冲突时只在失败原因里提示，绝不代替用户退出应用。v2 起 process 目标不再执行前置构建、注入运行探针或写入受管回执；`runtimeWitness` 字段被容忍但已忽略。源码监视失败（项目过大等）只降级为“不监视、需手动重启”，不会终止开发命令。

extension 只操作专用 Chromium / Chrome for Testing 资料目录，不更新用户日常浏览器中的插件，不把网页预览当作插件。Manifest V2 不冒充支持。后台需在浏览器实际运行并核对 runtime identity；无后台插件需实际加载插件文档。后续 status 检查同一浏览器实例和插件磁盘内容，不因合法的后台休眠而误报。

iosSimulator 不把 Metro 端口在线当作 App 更新成功。模拟器安装会规范化部分 dylib 权限，故内容比较忽略安装前后的模式差异，仍完整核对所有文件内容、路径及链接，并验证主进程位于相应安装包。Expo 的 JS 来自 Metro，因此还必须配置运行探针，不能仅凭原生壳就报告 current。真机和 Android 使用下文内置 iosDevice/androidDevice 驱动，需设备工具链、应用端证明及实际设备；没有设备不会返回模拟器证明代替。

external 用于尚未实现内置驱动的框架、微信开发者工具和容器等集成。它是公开扩展协议，不代表已内置并验收每种厂商驱动。驱动负责精确设备/宿主选择、更新、锁定及从目标取证；不会根据脚本存活推断远端状态。

## 配置示例

```json
{
  "schemaVersion": 1,
  "targets": {
    "desktop": {
      "strategy": "macBundle",
      "buildCommand": "zsh scripts/build.sh",
      "artifact": "build/MyApp.app",
      "installPath": "~/Applications/MyApp Dev.app",
      "bundleIdentifier": "com.example.myapp"
    },
    "web": {
      "strategy": "process",
      "startCommand": "npm run dev"
    },
    "extension": {
      "strategy": "extension",
      "launchTarget": "extension"
    },
    "ios": {
      "strategy": "iosSimulator",
      "launchTarget": "simulator:MyApp.xcodeproj",
      "sourcePaths": ["Sources", "project.yml", ".devbar.json"],
      "timeout": 600
    },
    "device": {
      "strategy": "external",
      "syncCommand": "python3 tools/update-device.py",
      "proofCommand": "python3 tools/read-device-version.py"
    }
  }
}
```

`launchTarget` 取自 doctor/profile 输出，避免把目录名猜成 scheme。配置字段和类型见 [sync.schema.json](sync.schema.json)。项目根目录每次只使用自身配置，不自动回退至另一个项目的命令。

## 运行版本探针

非 process 目标的更新与启动命令收到 `DEVBAR_SOURCE_DIGEST`、`DEVBAR_SYNC_ID`、`DEVBAR_SYNC_TARGET`（process 开发会话不注入这些变量，也不再要求探针）。驱动应将版本标识关联到实际构建，并从运行中的应用、设备或宿主读取；不能只在验证脚本中回显这些环境变量，也不能用静态 JSON 伪造成功。`runtimeWitness` 及其配套注入（NODE_OPTIONS 预加载、witness 目录）已在 v2 移除。

proofURL 直接返回 HTTP 200 与 JSON；不跟随跳转，不使用 Cookie 或系统凭据，只接受 localhost/127.0.0.1/::1，限制响应 1MB。proofCommand 只向 stdout 输出如下 JSON，stderr 单独记日志；收到 `DEVBAR_PROBE_ONLY=1`，不得构建、安装或启动目标。

```json
{
  "sourceDigest": "实际构建关联的源码指纹",
  "syncID": "运行实例接收的同步标识",
  "target": "web",
  "instanceID": "真实进程或设备内实例的唯一标识"
}
```

以上探针仅适用于需要版本证明的非 process 目标。四个字段必须与本次目标一致，instanceID 不得为空；status 再次核对实例身份。普通 HTTP 200、服务在线或端口存在不足以证明版本一致。

源码默认读取项目范围，忽略依赖、版本控制、常见输出与工作目录。`sourcePaths` 显式收窄实际源码，`exclude` 排除额外生成目录；不能排除根目录。文件缺失、读取失败、外部链接、超出 25 万项/4GB 或核对期间变化均不成功。仅 touch 不触发内容变更。成功运行构建命令仍以项目构建脚本正确为前提，不构成所有业务代码被正确编译的形式化证明。

## 存储与测试

默认数据目录为当前用户 Application Support/DevBar，可用 `DEVBAR_DATA_DIR` 隔离。项目锁、安装位置锁防止并发互相覆盖；日志和同步记录仅当前用户可读写。不会在配置发现阶段执行命令。

测试分别覆盖配置、真实开发会话（启动/幂等/项目自行热更新/停止）、独立宿主、实际插件加载、macOS 应用包替换与崩溃恢复、iOS 模拟器安装与应用自身写出的运行版本。会话状态与运行记录是私有内部格式。屏幕视觉、真实手机、商店、生产部署、第三方宿主驱动和公证分别验收，不能用这些本地测试替代。

## Built-in device and host drivers (0.11)

The additional strategies below execute concrete platform tools. They do not use
`syncCommand` or `proofCommand`. `external` remains available for an unsupported
vendor integration and is not counted as built-in support.

| strategy | Required configuration | Actual evidence |
| --- | --- | --- |
| androidDevice | buildCommand, artifact (single debug APK), device (adb serial), bundleIdentifier, activity | `adb install -r`, exact device, launched Activity, app-written proof/PID, pulled installed APK SHA-256 equals build |
| iosDevice | buildCommand, artifact (signed .app), device (devicectl ID/UDID), bundleIdentifier | devicectl install/launch/processes, copy app-written proof from data container, live PID and executable SHA-256 |
| windowsSSH | artifact (directory), host (OpenSSH alias), remoteStage (SFTP destination), remoteArtifact (staged directory on Windows), installPath, executable (relative), proofURL | SCP transfer, built-in PowerShell stage/hash/switch/rollback, PID + creation time + executable, installed tree hash, actual application loopback proof |
| blender | entry (project Python file), optional hostExecutable | actual background Blender loads and executes entry; private live host response identifies loaded entry bytes and boot instance |
| omp | entry (extension .ts/.js), optional hostExecutable | actual OMP RPC host imports and activates extension; session_start completes and private live host probe confirms boot instance |
| dsh | entry (plugin root index.js), hostExecutable (installed DSH lib/bin.js), optional browserExecutable | isolated official DSH web profile loads a snapshot, actual headless Chromium applies client plugin; CDP reads successful apply evidence on every status |

Device strategies require development instrumentation supplied in `drivers/sdk`.
Write `{"sourceDigest":"<DEVBAR_SOURCE_DIGEST at build time>"}` into
`devbar-build.json` in the iOS bundle or Android assets during the build, then call
`DevBarRuntime.record` once on application startup. Launch passes only the sync
nonce/target; the source revision must come from the installed application.
The default runtime paths are `Library/Caches/devbar-runtime.json` (iOS) and
`files/devbar-runtime.json` (Android). Device apps without this instrumentation
remain unconfirmed. Android release APKs without `run-as`, split APKs, App Store
installs, and unavailable devices are not claimed supported by these drivers.

For Windows, configure an existing trusted OpenSSH alias and matching known-host
key. DevBar never disables SSH host verification, installs credentials, or opens
an inbound network port. `remoteStage` and `remoteArtifact` describe the same staging parent in SFTP
and Windows notation, for example `C:/DevBarStage` and `C:\DevBarStage`.
Each sync creates a unique owned subdirectory so deleted files cannot survive
from an earlier transfer. The local and transferred tree hashes must match.
Staging and installation directories must be independent. The application must
serve the same four runtime proof fields plus its actual `pid`; persist the
built revision in its artifact. A failed replacement restores prior files but
does not claim the stopped old process is current. The Windows CI test exercises
real Windows processes, updates, installed-byte tampering, and stale receipts;
it does not establish access to a user's persistent Windows host.

Blender/OMP/DSH use independent development host sessions. Blender scripts may
write their own declared output files; inspect the entry before first sync.
They do not reload a user's existing unsaved foreground Blender document or OMP
conversation. DSH instrumentation wraps the snapshot's client apply only to
observe successful execution, and leaves project files and personal profiles
unchanged. A passing headless hook proves loading, not every plugin UI behavior.
Python >=3.9 is required for native transports; OMP/DSH also require their own
installed runtime. Missing tools/devices or failed hooks cause a nonzero exit.

### Local Docker Compose driver

`dockerCompose` requires `composeFile`, `service`, `projectName` beginning with
`devbar-`, and `proofURL`; `dockerContext` selects an existing local Unix-socket
Docker context. Remote contexts, privileged/host-network containers, global
container names, external resources, and bind-mounted code are rejected. The
build context must be inside the source project. Only the chosen service is
rebuilt/replaced; volumes survive updates and stop.

The Dockerfile must consume build argument `DEVBAR_SOURCE_DIGEST` and bake it
into the application's revision resource. Runtime receives `DEVBAR_SYNC_ID` and
`DEVBAR_SYNC_TARGET`, and its real HTTP probe returns the standard proof. DevBar
compares the immutable image label/digest, exact container ID/start time and
application instance on every status. A Docker daemon or port being online is
insufficient. `scripts/verify_container_driver.py` exercises actual Linux image
rebuild, container replacement, proof, preserved volume and exact stop.

All built-in native device/host strategies require timeout >=30 seconds. The
transport requires Python >=3.9. Platform Tools 36.0.2 was used in local Android
acceptance because 37.0.1 stalled during USB initialization on this Mac; the
original 37 installation was retained under DevBar/work for diagnosis.

### Windows launch sessions

Set Windows `launchMode: "interactive"` for a desktop development application.
This creates an owned Task Scheduler task using the currently authenticated SSH
user's existing interactive logon token. DevBar requires a nonzero Windows
session ID in the runtime evidence. The user must already be signed into that
Windows desktop; DevBar does not collect or store the user's password. Only the
owned task and exact recorded application process are stopped or removed.

`launchMode: "background"` (default) uses a detached WMI bootstrap outside the
OpenSSH job, so the application survives connection closure. It proves a
background Windows runtime and does not imply that an existing desktop window
has reloaded. Both modes keep normal SSH host-key verification enabled. The
transport uses a compressed, ASCII-only trusted agent command and rejects a
payload exceeding the Windows command-line limit.
