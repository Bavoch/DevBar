# 公开分发状态

DevBar 采用 [MIT 许可证](../LICENSE)。版本、源码和验证范围见 [GitHub Releases](https://github.com/Bavoch/DevBar/releases)。普通反馈使用 [Issues](https://github.com/Bavoch/DevBar/issues)，请通过 [私密入口](../SECURITY.md) 提交漏洞详情。

| 范围 | 验证方式 |
| --- | --- |
| 源码构建 | macOS 隔离回归、GitHub Actions、搬迁后的 App 和 CLI |
| 正式安装包 | Developer ID 签名、Apple 公证、装订、Gatekeeper |
| 首次使用与升级 | 干净账户安装、启停、重新打开后恢复管理及升级数据保留 |
| 系统和架构 | 在承诺支持的 macOS 与 CPU 上分别验证 |
| 额外平台 | 按 [平台矩阵](platform-matrix.md) 单独验收 |

v0.16.0 首发提供源码。正式安装包的签名、公证与安装验收步骤见 [发布流程](release.md)。更早的 [生产审查](production-review.md) 记录了运行控制改造与当时的本地测试。
