# Cleaner Legacy v0.2 — iOS 15.4 启动兼容修正

## 上一版 v0.1 的明确问题

- v0.1 IPA 不含 `Assets.car`、`CFBundleIcons`，图标确实没有被编入安装包。
- v0.1 使用 Xcode 27 编译的 SwiftUI App，虽然 `MinimumOSVersion=15.4`，但没有测试 iOS 15.4 真实设备能否启动。具体闪退原因必须通过 iOS 崩溃日志确认，不能把编译成功当作真机兼容。
- 上一版直接加 `com.apple.private.security.no-sandbox` 权限，但没有制作普通沙盒签名的对照包，无法排除权限签名导致的启动问题。

## v0.2 修复

- **彻底移除可执行程序中的 SwiftUI 和 Swift 运行时依赖**：只编译 `LegacyProbe/ObjC/main.m`（UIKit + Objective-C），兼容系统提供的旧 API。
- 复制原版 Cleaner v89 的 `AppIcon` 原始 1024 PNG 和资源目录，并在 Xcode 项目中配置 `ASSETCATALOG_COMPILER_APPICON_NAME`。构建中必须检查 `Assets.car` 与 `CFBundleIcons`。
- 把启动和扫描分开：应用打开时只创建原生 UIKit 主界面，不自动扫描；必须点击按钮才做只读访问诊断。
- 两种 IPA：`...-TrollStore.ipa` 保留 `no-sandbox` entitlement 供正常读容器；`...-LaunchOnly.ipa` 不请求该 entitlement，使用不同 Bundle ID，可用于区分是否签名权限引起闪退（此对照包预计无法读取其他 App）。
- `MinimumOSVersion` 强制检查 iOS 15.4；对可执行文件运行 `otool -L`，禁止链接 SwiftUI 和任何 Swift 动态库。
- 目录访问只使用 `open(O_NOFOLLOW)` 与 `readdir` 进行只读检查，不删除、重命名或写入任何其他 App 文件。

## 安装和反馈

1. 使用 TrollStore 安装 `Cleaner-LegacyProbe-v0.2-iOS15.4-TrollStore.ipa`；如果旧探针已经安装，可先删除旧版再安装，避免缓存显示旧图标。
2. 打开应用，首页必须立即显示“启动成功”和 iOS 系统版本；此时不会进行目录扫描。
3. 点击“检查 App 容器读取权限”，查看容器总量、Caches/tmp 可读数量和 errno。
4. 如果仍然闪退，用 **对照包** `Cleaner-LegacyProbe-v0.2-LaunchOnly.ipa` 检查是否能打开。它是正常沙盒应用，仅用于判断 SwiftUI、签名、设备版本原因，不代表已经有读取权限。
5. 如果两个版本均闪退，取“设置→隐私与安全性→分析与改进→分析数据”的应用崩溃日志（含 `Termination Reason` / `Exception Type`）才能定位剩余原因。

> 不能通过模拟器替代 iOS 15.4 + TrollStore 设备实测。保留 Cleaner v89 正式版和清理逻辑原样。
