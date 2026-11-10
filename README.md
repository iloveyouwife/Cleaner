# Cleaner

本仓库目前的应用项目是 **Cleaner**，一款基于 SwiftUI 的 iPhone App 缓存扫描与选择性清理工具。

> **当前应用源码位于 [`worse-query-cleaner-v52` 分支](https://github.com/iloveyouwife/IOSurfaceProbe/tree/worse-query-cleaner-v52)。** 此 `main` 分支保留的是早期 IOSurface 诊断研究代码，并不是当前 Cleaner IPA 的构建来源。

## 软件下载

- [Cleaner Releases：下载未签名 IPA](https://github.com/iloveyouwife/IOSurfaceProbe/releases)
- [Cleaner 的完整功能、权限边界和签名说明](https://github.com/iloveyouwife/IOSurfaceProbe/blob/worse-query-cleaner-v52/README.md)
- [Cleaner 源码及构建方法](https://github.com/iloveyouwife/IOSurfaceProbe/tree/worse-query-cleaner-v52/WorseCleanerBuild)

Cleaner 可以在系统权限允许的范围内发现 App 容器，并统计、选择性清理可访问的 `Library/Caches` 和 `tmp`。**不保证能访问所有第三方 App，不清理系统数据，不提供越狱、root 或永久签名。**

Releases 提供的是**未签名 IPA**，安装前需要用户自行签名并正确配置独立的 App Group。具体限制与风险请以当前 Cleaner 分支的 README 为准。

## 历史资料

此分支原为 `IOSurfaceProbe` 研究项目；历史提交和诊断代码继续保留供查阅。仓库名称与定位迁移到 Cleaner 后，不应将早期诊断研究的说明视为当前 App 已实现的功能。
