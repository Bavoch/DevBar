# Platform acceptance boundaries

DevBar identifies project types separately from verifying a selected running
instance. A configured target is not an automatic claim that every project or
platform is accepted. `current` requires a successful sync receipt and live
read-only status proof. No local sync publishes a production service or store app.

| Runtime | Built-in driver | Acceptance on this Mac / CI |
| --- | --- | --- |
| macOS packaged desktop | macBundle | Native background v1→v2, exact executable and complete installed bundle, rollback and source races |
| Local web / service / development shell | process | Real HTTP application revision, nonce and process proof; missing proof remains runningUnverified |
| Chromium extension | extension | Real dedicated headless Chromium worker and extension document |
| iOS simulator | iosSimulator | Real compilation/install/update, installed content and app-written PID/revision, preserved data |
| Android APK | androidDevice | Real APK v1→v2 on headless ARM64 emulator, installed APK hash and app-written proof; physical Android hardware not connected |
| Physical iOS | iosDevice | Dedicated devicectl install/launch/data-container driver and SDK compiled; paired iPhone/iPad offline, physical acceptance remains pending |
| Windows | windowsSSH | Real Windows Server 2025: native lifecycle, SSH/SFTP, connection-independent background process and nonzero interactive desktop session verified |
| Blender scripts | blender | Actual Blender background host v1→v2 and existing morph project executed; existing foreground document is not reloaded |
| OMP extensions | omp | Actual OMP RPC extension load/reload; existing usage footer project configured and verified in a separate host |
| DSH client plugins | dsh | Official isolated web profile plus headless Chromium; actual client apply and v1→v2 verified |
| Local Compose services | dockerCompose | Actual Linux VM/images/containers, app proof, replacement, preserved volume and stop; no remote Docker or bind-mounted code claim |
| WeChat mini program | No accepted built-in driver yet | Installed official CLI would launch its IDE when absent. No real host acceptance under the required headless-only testing policy |
| Other containers / custom vendor hosts | external extension protocol | An integration interface alone does not count as tested vendor support |
| Libraries / assets / archives | No runtime claimed | Read-only classification; consumer application or host must be explicitly selected |

Native hosts and device apps expose a revision read from actual loaded code or a
built-in revision resource. Expected nonce/target values alone are insufficient.
Device SDK examples live in `drivers/sdk`; they do not bypass device trust,
Developer Mode, signing/provisioning, Android authorization, or vendor login.

Public release additionally requires a Developer ID Application certificate,
notarization and Gatekeeper acceptance. The local signed build and CLI update
path do not satisfy those distribution gates by themselves.
