# Cleaner — iOS App 缓存扫描与清理

本目录是当前 **Cleaner** App 的源码。桌面显示名称为 `Cleaner`；Xcode target 与部分内部类型仍沿用历史名称 `WorseCleaner`，不影响应用名称。

当前界面采用简体中文文案，App bundle 正式声明 `zh-Hans` 为开发与支持语言，并包含 `zh-Hans.lproj/InfoPlist.strings`；原生复制、查询等文字选择菜单由 iOS 决定最终显示语言，仍可能受设备／单 App 语言设置影响。

## 目前的实现

1. **容器发现：** 先尝试系统可用的 MCM / LaunchServices 只读查询，再使用动态 inode 上限发现普通 App 和 PluginKit 扩展容器；采用最多六线程分块扫描及本地增量索引，温度升高时减少工作线程，手动深度发现会执行完整重扫。未将内部守护进程和系统数据容器纳入清理范围。结果仍不保证绝对完整。
2. **容器识别：** 优先只读解析 LaunchServices 的 CSStore2 数据库，以 App／扩展数据容器 UUID 路径进行精确匹配；数据库路径会在 inode 扫描时发现并缓存，旧版索引缺失时进行有界反向查找。二进制记录采用候选布局与实际容器交叉验证，不能确定时不猜测。其他可访问元数据、保存状态、偏好文件、安装包 Info.plist、已验证的名称和少量离线名称映射仍是回退。数据库只用于识别，不纳入清理目标。
3. **权限检查：** 读取安装后实际生效的 App Group entitlement，要求用户确认所选组是 Cleaner 独占组；尝试获取目标容器的临时访问权限并验证目录可读性。仅在缓存目录因 `EPERM` 被拒绝时，额外尝试 `Caches` 或 `tmp` 的路径限定访问授权。
4. **受限扫描：** 只统计 `/var/mobile/Containers/Data/Application/<UUID>/Library/Caches` 和同一容器内的 `tmp`。无法读取时报告错误，不以 `0 KB` 代替权限失败。
5. **选择性清理：** 仅在扫描成功且用户明确勾选、确认后操作；只删除上述缓存目录内的内容，保留根目录、Documents 和 App 本身。使用描述符相对操作及 `O_NOFOLLOW` 限制路径穿越。
6. **界面功能：** 搜索、排序、选择与排除 App；高级设置、手动发现与诊断；可选 Apple 商店公开名称查询。界面使用 SwiftUI 原生菜单和 SF Symbols。App 列表优先保留右侧缓存容量及选择状态的空间，过长名称最多两行、Bundle ID 中间省略；无障碍大字体下容量单独成行。

## 签名和 App Group

构建配置位于 [`project.yml`](project.yml)，最低部署目标为 iOS 26.0，指定 Xcode 27.0。仓库中的 Bundle ID（`com.example.worsecleaner`）与 App Group ID 只是示例，不能直接用于你的正式签名。

正式安装需用自己的 Apple 开发团队：

1. 配置有效的 Bundle ID、独立的 App Group 和匹配的 provisioning profile。
2. 使用有效证书签署 IPA，确认 App Group entitlement 随签名实际生效。
3. 在高级设置中选择可访问的专用组，并确认此组**没有被其他 App 共享使用**。

**重要风险：** 上游临时访问机制可能替换所选 App Group 的缓存目录；误用其他 App 共享的组可能影响它们的数据。不要将共享组用于本工具。

## 构建与发行

GitHub Actions 工作流：[Build Cleaner unsigned IPA](../.github/workflows/cleaner-ipa.yml)。

`main` 是当前稳定源码。自动化使用 Xcode 27 编译未签名 IPA，并在 Actions 保留构建产物。新版本发布时，在 `project.yml` 中将 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 分别递增为 `0.N.0` 和 `N`；提交到 `main` 后，流水线通过校验并发现该标签尚不存在，就会自动创建 `v0.N.0` 标签并将 IPA 发布到 [Releases](https://github.com/iloveyouwife/Cleaner/releases)。已发布版本不会被自动覆盖。

发布的是**未签名 IPA**。GitHub 构建成功或模拟器 UI 测试通过，并不证明用户设备拥有越权读取能力，也不能替代真机验证。

## 功能边界

- 没有使用旧项目的配对保存、钥匙串配对、AFC/HouseArrest 或 AirTraffic 流程。
- 不提供 root、越狱、永久签名、系统缓存全清、跨 App 任意目录读写。
- iOS 沙盒可能拒绝隐藏元数据或某些缓存目录；实际是否可读写以诊断和扫描结果为准。
- 首次完整 inode 扫描仍可能耗时数分钟甚至更久，后续通过本地缓存、inode 校验和增量扫描加快速度。完整扫描不能保证所有路径均可解析；无法读取的容器不会被当作可清理项目。
- 联网补全名称仅在用户手动操作后向 Apple 查询已知 Bundle ID，每批最多 80 个；未知 UUID 不能因此推导出所属 App。

## 来源及许可证

- 临时访问入口与路径发现：[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)（GPL-3.0-or-later），保留相应源文件及署名。
- 容器 inode 分块扫描与索引设计参考：[kolbicz/WQFiles](https://github.com/kolbicz/WQFiles)（GPL-3.0-or-later）；本项目只扫描普通 App 与扩展数据容器，不包含 WQFiles 的系统文件浏览或编辑功能。
- 有限缓存扫描与清理算法：[YangJiiii/3105](https://github.com/YangJiiii/3105)（GPL-3.0-or-later），见 `LimitedCleanerService.swift` 的来源说明。
- 一部分只读容器信息查询参考 3105；未复制其完整权限提升流程。

按 [GPL-3.0-or-later](LICENSE) 的要求分发源码、版权和许可信息。早期版本的逐条 UI 改动记录不再作为当前功能说明，以现有源码与发行版为准。
