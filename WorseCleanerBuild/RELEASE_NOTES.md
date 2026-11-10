## Cleaner

适用于 iPhone 的 App 缓存扫描与选择性清理实验工具。当前界面使用 SwiftUI、iOS 原生菜单和 SF Symbols，支持搜索、排序、多选、排除管理与访问诊断。

### 安装包

- 附件 `Cleaner-v*-unsigned.ipa` 为**未签名** IPA。
- 安装前需要自己的有效证书、provisioning profile，以及实际授权的独立 App Group。
- 请勿使用其他 App 已共享的 App Group；操作前应自行备份重要数据。

### 清理范围

仅尝试处理已发现、已授权、已扫描且用户明确选中的 App 数据容器内 `Library/Caches` 和 `tmp` 的内容。不会删除 Documents、App 本体或系统数据。

**访问能力不作保证：** iOS 沙盒、签名和系统版本可能阻止第三方 App 容器访问。发布构建成功、模拟器截图测试通过不等于已在所有真机上验证清理效果。本应用不提供 root、越狱或永久签名。

源码、第三方授权及构建说明请阅读仓库根目录 `README.md` 和 `WorseCleanerBuild/README.md`。
