# 构建、验证与发布

## 验证源码版本

在 macOS 上构建一次，然后运行隔离检查。构建需要 Swift 5.9 或更新版本的 Xcode Command Line Tools，测试还需要 Python 3 和 Node.js。

```sh
zsh scripts/build.sh
python3 scripts/check-product.py
```

本地构建产物为 `dist/DevBar.app`。检查使用隔离配置和测试项目，浏览器测试保持无头运行。GitHub 的 [Product checks](https://github.com/Bavoch/DevBar/actions/workflows/ci.yml) 在 macOS runner 上执行相同基线。设备和宿主集成按 [平台矩阵](platform-matrix.md) 单独验收。

发布源码时，核对 `scripts/build.sh` 中的应用版本、`CHANGELOG.md` 和官网安装入口。用版本标签创建 GitHub Release，并在发行说明写明已验证的 macOS 和 CPU、已知限制与构建命令。GitHub 随标签自动提供源码归档。官网由 GitHub Pages 发布 `website/` 中的文件。

## 制作正式 macOS 安装包

通过 Developer ID Application 签名并提交 Apple 公证。将公证凭据保存为本机钥匙串 profile。

```sh
DEVBAR_SIGN_IDENTITY='Developer ID Application: …' \
DEVBAR_NOTARY_PROFILE='已配置的钥匙串 profile' \
zsh scripts/package-release.sh --notarize
```

脚本构建并运行基础检查，验证签名，上传 Apple 公证，装订票据并核对 Gatekeeper。成功后生成 `dist/DevBar-<版本>-<架构>.zip` 和同名 `.sha256`。可以在归档目录运行 `shasum -a 256 -c DevBar-<版本>-<架构>.zip.sha256` 核对下载内容。省略 `--notarize` 时，文件名以 `-unnotarized.zip` 结尾，供内部验证。

在每个承诺支持的 CPU 上构建并验收对应产物。用干净账户从实际下载的归档验证首次打开、添加项目、运行与停止、退出后恢复管理、键盘操作及升级后数据保留。验收完成后，上传 ZIP 和校验文件到对应 GitHub Release，再更新官网与 README 的安装入口。

`DevBar.app` 自带 CLI、驱动与帮助文件。项目列表与日志保存在 `~/Library/Application Support/DevBar`。升级时替换 App 即可保留数据。CLI 安装脚本位于 `Contents/Resources/install-cli.sh`，默认在用户目录安装，并保护已存在的同名命令。

[Apple Developer ID 证书说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) · [Apple 公证文档](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution/)
