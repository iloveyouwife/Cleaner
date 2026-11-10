# Cleaner

**Cleaner** 是一个面向 iPhone 的 App 缓存扫描与选择性清理工具，使用 SwiftUI 构建，界面适配 iOS 27。

它尝试发现设备上的 App 数据容器，统计可访问的缓存大小，并在用户**手动选择及确认**后清理指定项目。能否访问其他 App 的容器取决于系统权限、实际签名及设备环境；本项目**不保证**所有设备或所有 App 都可扫描、清理。

## 当前功能

- 发现与识别普通 App 和扩展的数据容器；优先从本机 LaunchServices 数据库按容器路径对应 Bundle ID 和显示名称，旧系统格式或读取失败时回退到原有名称识别；无法确认归属的目录独立显示。
- 扫描每个可访问容器的 `Library/Caches` 和 `tmp`，显示缓存大小。动态 inode 上限和本地增量索引用于减少漏扫与重复扫描。
- 搜索、按缓存大小排序、批量选择、排除指定 App，以及管理已排除项目。
- 清理前二次确认；仅处理被选中、已扫描且可访问的容器。
- 高级设置提供 App Group 授权检查、深度发现、手动添加路径和访问诊断。
- 可选的 App 名称补全：由用户主动触发，使用 Apple 的公开查询接口；不会上传缓存文件。
- 使用原生 SwiftUI 菜单、SF Symbols 和动态字体；包含浅色、深色及辅助功能布局测试。

## 下载

最新未签名 IPA 和历史版本见 [GitHub Releases](https://github.com/iloveyouwife/Cleaner/releases)。

**IPA 未签名，不能直接安装。** 使用前须由自己的开发者证书及匹配的 provisioning profile 签名，并配置独立且确实可用的 App Group。普通签名不代表一定能访问其他 App 的缓存。

## 适用范围与限制

- 工程的最低部署版本为 **iOS 26.0**，使用 **Xcode 27.0** 构建；此前的界面测试不等于已验证所有系统版本的实际文件访问权限。
- 删除范围只限于经过验证的 App 数据容器内的 `Library/Caches`、`tmp` 内容；不会清理系统数据、Documents 或整个 App 容器。
- 容器发现包括普通 App 与 App 扩展，不扫描或清理 InternalDaemon、系统数据容器。首次完整发现仍可能耗时较久，后续优先使用本地索引增量扫描；索引会校验路径和 inode，并周期性全量刷新。
- 不提供 root、越狱、永久签名、全设备沙盒读写或绕过 iOS 权限的保证。
- 没有依赖配对文件、AFC/HouseArrest、VPN 或后台音频来执行当前清理流程。

## 源码与构建

- [Cleaner App 源码及技术说明](WorseCleanerBuild/README.md)
- [XcodeGen 工程配置](WorseCleanerBuild/project.yml)
- [IPA 构建与发行工作流](.github/workflows/cleaner-ipa.yml)

## 版本管理

- `main` 是 Cleaner 当前稳定源码，也是后续开发与发行的入口。
- `v0.52.0`、`v0.53.0` 等 Git 标签固定对应的发行版源码；已发行的版本不会被覆盖。
- 每次将新版本提交到 `main`，GitHub Actions 都会构建并测试。修改 `WorseCleanerBuild/project.yml` 中的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION` 后，流水线会为尚未发布的新版本自动创建标签、Release 和未签名 IPA 附件。

本仓库当前仅维护 Cleaner 应用源码、测试和发行流程。

Cleaner 的缓存访问部分参考了 [forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)、[YangJiiii/3105](https://github.com/YangJiiii/3105)；容器发现、增量索引及 LaunchServices CSStore2 解析思路参考并适配了 [kolbicz/WQFiles](https://github.com/kolbicz/WQFiles)。保留原始授权和署名；详见 [GPL-3.0-or-later 许可证](WorseCleanerBuild/LICENSE)。
