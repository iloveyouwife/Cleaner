# Cleaner v89 边界审查与候选修复（只读研究分支）
 
基准：`v0.89.0`，提交 `badffed9f0e36ed1b404cf2e64b9027b2f09f3f4`。
 
**v89 main、Release、UI、版本号和 IPA 均未修改。本分支暂不发布新稳定版本。**
 
## 两项问题
 
1. `worse_query.m` 原实现为建立权限申请暂存符号链接，直接删除专用 App Group 的 `Library/Caches`（连同其现有内容）。候选修复仅在**同一签名 App Group 的 Library 下**将原目录临时移动为 `Caches.wq-preserved`，然后仍在原路径建立同一指向的符号链接；结束后移除该符号链接并恢复旧目录。遇到已有备份、无法识别路径或回滚失败时拒绝继续，绝不覆盖遗留文件。
2. `LimitedCleanerService.clean` 先清理 Caches、后清理 tmp；若在第一部分删除完后遇到权限错误，原实现会抛错并跳过后验统计。候选修复遇到目录打开失败后停止后续删除，将错误计数 +1，并尝试用原本的后验扫描报告已确认删除的文件与空间；若后验也失败，继续使用原有的 `postCleanupVerificationFailed` 类型而不猜测释放字节数。
 
## 约束与范围
 
- 未改 `WorseCleanerModel.swift`、`CleanerEngine.swift`、`ContentView.swift`、`WCGrant.swift`、`WCPathDiscovery.swift`，也未改 SDK、Entitlements、版本号。
- 删除白名单仍是 `[["Library", "Caches"], ["tmp"]]`，保留 `O_NOFOLLOW`、`openat`、`unlinkat` 等校验。
- `worse_query` 的 class=7、part=3、两种 flags、`container_query_get_single_result` 与 sandbox token 取得和释放过程不变。
- 新增真实临时目录文件系统测试：已有暂存缓存保留、授权查询失败恢复、遗留备份/未知链接拒绝、清理第二目录前 EPERM 后部分统计准确、清理第一目录前 EPERM 不误报释放字节。
 
## 验收门槛
 
模拟器单元测试能够验证文件系统副作用、路径及异常统计，**不能替代 iOS 27.0.1 真机签名 App Group 的 worse_query 授权兼容性测试**；没有真机验证前，不宣称授权未受任何影响，也不推荐合并 main 或正式发布。
