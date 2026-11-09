# 清存 WQ / WorseCleaner

独立的 iOS App 缓存扫描与清理实验项目。

## 来源与授权

- 沙盒扩展入口：[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)，原作者 Taj C (forcequit)，GPL-3.0-or-later。保留原始 `worse_query.h/.m`。
- 安全的描述符相对递归扫描/清理：[YangJiiii/3105](https://github.com/YangJiiii/3105)，GPL-3.0-or-later。改编 `LimitedCleanerService.swift`。
- App 容器目录查询：参考 3105 的 `mcm_bridge.m`，只保留只读的容器发现；没有复制它的 kernel exploit、sandbox_escape、MCMActivate 或 MobileHouseArrest 宿主校验。

遵循 GPLv3（见 `LICENSE`）；分发 IPA 时请同时提供本项目对应源代码和许可证。

## 本版与旧 AirLift 的区别

1. 使用 `worse_query` 对**已发现的 App 数据容器根目录**获取临时沙盒扩展。
2. 在扩展有效期间复用 3105 的 `openat` / `readdir` / `unlinkat` 缓存算法。
3. 只允许 `/var/mobile/Containers/Data/Application/<UUID>/Library/Caches` 和 `/tmp` 两个缓存根目录；不删除根目录本身，拒绝跟随符号链接。
4. 扫描先检查根目录及缓存目录是否可读。失败明确报告 errno，不将“没有权限”误报成“0 KB”。
5. 清理前必须成功扫描，并由用户对**每个 App 单独确认**。
6. **完全不使用配对记录、钥匙串、AFC/HouseArrest、AirTraffic、VPN 或后台音频**。旧 `CacheGuardBuild` 不参与构建。

## 重要：App Group 必须由签名赋权

`worse_query` 要求可用的 App Group；这里是可替换的示例：

- Bundle ID: `com.example.worsecleaner`
- App Group ID: `group.com.example.worsecleaner`

正式安装前，请用自己的 Apple 开发团队注册 **自己的** App ID 和 App Group，
同时修改：

1. `project.yml` 中的 `PRODUCT_BUNDLE_IDENTIFIER`
2. `WorseCleaner/WorseCleaner.entitlements` 中的 App Group
3. `WorseCleaner/CleanerEngine.swift` 中的 `groupID`

签名时 provisioning profile 必须允许相同的 App Group。仅重签名 IPA、但没有匹配的 App Group entitlement，**不能让漏洞工作**。
诊断页面现在会读取安装后实际生效的 App Group entitlement，而不是盲信构建时的示例值；如果签名工具更换了组名，可在界面选择实际授权的组。
**不要选其他 App 正在使用的共享组**：上游 worse_query 会临时替换该组的 Library/Caches，可能影响其他 App，所以界面要求额外确认这是清理器独占的组。
GitHub Actions 生成的是**未签名编译产物**，无法代替你的签名证书/授权。

## 功能限制与验证

- 公开仓库自述支持 iOS 26.x / 27.2，**没有在你的 iOS 27.0.1 设备上验证实际缓存读写**。不能据此宣称已成功清理。
- App 列表读取是最佳努力的只读 MCM / LaunchServices 查询；有时只能列出本工具自身，不能把它误判成设备只有一个 App。
- 可手动粘贴已知的容器 UUID 根路径，或者选择源于 worse_query 的慢速 pathleak inode 目录发现。后者最多尝试 500 万 inode，结果可能不完整，也可能耗时数分钟。
- `worse_query` 只提供目录沙盒扩展，不保证所有文件都可写、也不等于越狱/root。
- 界面按 3105 CleanerView 的搜索、排序、选择、摘要与批量清理结构移植，保留独立的权限诊断入口。
- 扫描后 App 可能自行生成或改变缓存；清理结果以实际删除数量与二次扫描为准，若出现错误应停止。
- 这里对 3105 的扫描逻辑增加了严格错误传递：深层目录不可读时扫描会失败；清理如出现失败项也不会被标为完全成功。
- App 的 `Caches` 和 `tmp` 也可能包含离线数据、登录态或下载内容；请备份后测试，不要首先操作重要 App。
- 上游 `worse_query` 会临时删除并重建**本工具的专用 App Group 的 Library/Caches**。请不要让其他软件共用这个 App Group。

## 构建

本地需要 macOS、Xcode、XcodeGen。

```bash
cd WorseCleanerBuild
xcodegen generate
xcodebuild -project WorseCleaner.xcodeproj -scheme WorseCleaner -sdk iphoneos -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions: `.github/workflows/worse-cleaner-ipa.yml` 在 `worse-query-cleaner` 分支提交时构建未签名 IPA。
