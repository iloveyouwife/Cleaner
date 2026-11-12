# Cleaner Legacy · iOS 15.4 TrollStore 只读探针

目标：在 **不影响 Cleaner v89 稳定版** 的独立研究分支，验证 iOS 15.4 + TrollStore 能否直接枚举 App 容器与读取 `Library/Caches` / `tmp`。

## 已验证的架构差异

Cleaner v89 使用 iOS 26+ 的 SwiftUI（`glassEffect`、`scrollEdgeEffectStyle`、`onScrollGeometryChange`、`onScrollPhaseChange`）以及 `worse_query` + App Group 沙盒授权，不能直接运行于 iOS 15.4。

TrollStore 官方 README 说明：在支持版本上，可保留应用二进制内由 `ldid` 添加的任意 Entitlements；`com.apple.private.security.no-sandbox` 是支持的取消沙盒方式之一；**但安装器不是自动赋予每个应用全部访问权限**。iOS 15.4 属于支持版本。

官方来源：https://github.com/opa334/TrollStore

## 当前探针做什么

- 单独的 iOS **15.4 最低部署目标**，使用 iOS 15 原生支持的 `NavigationView` / `List`，不使用新系统 SwiftUI 修饰符。
- 不加载 Cleaner 原本的 `worse_query`、`WCGrant`、LaunchServices 私有索引及 App Group 授权。
- 通过文件系统直接枚举 `/var/mobile/Containers/Data/Application`，用 `open(O_NOFOLLOW | O_DIRECTORY)` 验证根目录、`Library/Caches` 和 `tmp` 能否访问。
- 默认请求 **仅** `com.apple.private.security.no-sandbox = true`，不加入危险的 banned entitlements、不使用 `platform-application` 或 root helper。
- **严格只读**，不移动/删除/修改任何文件；旨在区分“签名未生效”“只能安装”“真的可读取目标目录”。
- UI 展示具体 errno，包括 `EPERM` 与 `ENOENT`，不能把无权限显示为 0 KB。

## 编译与签名

独立 GitHub Actions 使用 Xcode 27 SDK 编译 iOS 15.4 Deployment Target，再运行：

```bash
ldid -SLegacyProbe/LegacyProbe/LegacyProbe.entitlements Payload/LegacyProbe.app/LegacyProbe
ldid -e Payload/LegacyProbe.app/LegacyProbe
```

然后打包 `Cleaner-LegacyProbe-iOS15.4-TrollStore.ipa`，用 TrollStore 安装。IPA 仅用于适配性验证，不是正式清理版本。

请在手机上打开探针 → 点击「检查 App 容器读取权限」→ 查看发现数、可打开 Caches 和 tmp 的数量及 errno。尚不能保证 iOS 15.4 真机已经通过，必须用目标设备验证。

## 确认读权限后接入清理功能的方案

1. 保留原版 `LimitedCleanerService` 文件描述符式安全操作（`openat`/`O_NOFOLLOW`），仅允许 `Library/Caches` 和 `tmp`；项目须遵守该文件的 GPL-3.0-or-later 来源许可。
2. 建立 `LegacyFileAccess` 适配层，绕过 `WCGrant.readablePath`、`worse_query` 和 App Group，但每次扫描、每次删除都校验目标根目录是带 UUID 的 App 容器。
3. 将 Finder 从 MCM / LaunchServices 漏洞路径改为直接读目录；App 名称需要可验证的元数据映射，不可把 UUID 猜成应用名。
4. UI 使用 iOS 15 支持的 `NavigationView`、`List` 和简单 `TextField`；先解决启动、扫描和删除安全性，再按原版设计逐步复刻。
5. 只允许明确勾选后的清理，删除后重新扫描验证统计；对锁定文件、运行中的 App、沙盒权限失败显示错误，不夸大释放空间。
6. 做完单元、模拟器及真实 iOS 15.4 + TrollStore 测试，再决定发布独立 Legacy 清理 IPA。

当前 branch：`research/ios15-trollstore`。正式 v89 的 `main` 未修改。
