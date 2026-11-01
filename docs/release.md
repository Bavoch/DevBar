# 构建、验证与发布

DevBar 是面向个人 AI 构建者公开分发的原生 macOS 工具。构建不会安装或启动应用，也不更改全局 AI 规则。

## 本地验证

完成一组完整修改后构建一次，再运行隔离检查：

```sh
zsh scripts/build.sh
python3 scripts/check-product.py
```

检查只使用隔离配置和测试项目，不打开前台浏览器，不访问个人宿主资料，不发布项目。面板使用离屏渲染；真实用户的首次安装和原生交互另行验收。

基础检查覆盖进程与入口解析、面板行为、配置损坏保护、危险入口排除、进程归属与异常清理、多运行方式隔离、分发包搬迁和显式安装同步恢复。相关脚本见 `scripts/check-product.py`；设备和宿主检查按 [平台边界](platform-matrix.md) 单独选择。

历史 `verify_*.py` 中仍有旧协议时代的验收脚本，不能将脚本存在当作本版已通过的证据。以本版基础入口和本次审查记录为准。

## 安装包

`dist/DevBar.app` 包含程序、CLI、驱动与帮助文件。项目数据存放在用户应用支持目录，移动或升级 App 不删除数据。CLI 是可选功能，包内 `Contents/Resources/install-cli.sh` 安装到用户目录，已有其他同名命令不覆盖。

本地默认临时签名，仅用于开发验证。发行需要 Developer ID Application 证书：

```sh
DEVBAR_SIGN_IDENTITY='Developer ID Application: …' \
DEVBAR_NOTARY_PROFILE='已配置的钥匙串 profile' \
zsh scripts/package-release.sh --notarize
```

脚本构建并检查产物、执行签名验证，上传 Apple 公证、装订票据、核对 Gatekeeper，最后重新打包并生成 SHA-256。无 `--notarize` 时只能生成已签名但未公证的验证包，不能标为正式发行。密钥不得写入仓库或日志。

当前脚本构建本机 CPU 架构，未提供已经验收的 universal 包。发布前核对应用身份、版本与变更记录，在承诺支持的 macOS 与 CPU 上分别验证；并完成干净账户安装、退出后管理恢复、升级数据保留、辅助功能及支持渠道检查。源码授权和安全报告入口由维护者确定。[公开分发状态](open-source-readiness.md)
