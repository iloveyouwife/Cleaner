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
5. 清理前必须成功扫描，仅对用户手动勾选的目标进行批量确认后清理。
6. **完全不使用配对记录、钥匙串、AFC/HouseArrest、AirTraffic、VPN 或后台音频**。旧 `CacheGuardBuild` 不参与构建。

## 重要：App Group 必须由签名赋权

`worse_query` 要求可用的 App Group；这里是可替换的示例：

- Bundle ID: `com.example.worsecleaner`
- App Group ID: `group.com.example.worsecleaner`

正式安装前，请用自己的 Apple 开发团队注册 **自己的** App ID 和 App Group，
同时修改：

1. `project.yml` 中的 `PRODUCT_BUNDLE_IDENTIFIER`
2. `WorseCleaner/WorseCleaner.entitlements` 中的 App Group

App Group 的实际权限在运行时从签名中读取，不依赖源码中的示例常量。

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
- v3 会在获得容器读取权限后解析容器根目录里的 MCM 元数据，并尝试通过 LaunchServices 找到本地化的 App 名称。系统拒绝名称查询时会显示 Bundle ID 或容器 UUID，而不伪造名称。
- v4 补全 3105 的另一条容器身份识别路径：若隐藏元数据读取失败，会在同一临时授权期间检查 `Library/Saved Application State/*.savedState`、`Library/Preferences/*.plist`，优先使用 LaunchServices 校验候选 Bundle ID，再通过加载 CoreServices、读取 App `Info.plist` 或本地化名称进行展示。扫描结束会报告识别来源、真实显示名称数量及元数据读取 errno，方便判断 iOS 版本对访问的实际限制。
- v4 App 桌面显示名称为 `Cleaner`，App 图标使用用户提供的蓝底白色扫帚图片；缓存 0 字节时显示 `0 KB` 而不是 `Zero KB`。
- v5 针对 iOS 27 第三方 App 的 LaunchServices 名称不可见问题，先在临时只读授权范围内枚举 `/var/containers/Bundle/Application/<UUID>/*.app/Info.plist` 构建当前安装 App 的名称表，再为常见 App 的已知确切 Bundle ID（如微信、淘宝、抖音、京东）提供离线名称回退。未知 Bundle ID 仍如实显示包名，不冒充已确认 App。
- v6 为已识别 Bundle ID 尝试优先显示**真实应用图标**（参考 3105 的 `LSApplicationProxy iconDataForVariant:`，再从本机安装的 `.app` 图标文件或资源中读取）。系统拒绝图标接口时才显示通用占位图。名称读取以当前已安装 App 的本地化 `Info.plist` 优先；新增可自愿点击的「联网补全未识别的 App 名称」，仅把缺少名称的 Bundle ID 发送给 Apple App Store 公开查询接口（每次至多 80 个，支持重复查询），**不从 App Store 拉取或使用受授权限制的图标**。设备或服务器不提供真实名称、图标时会明确回退显示 Bundle ID 和占位图，不保证 100% 识别。
- v7 根据 iOS 27.0.1 真机反馈，修正仅凭 LaunchServices 或安装目录父级扩展取图标的问题：`pathleak_multiple` 单次 inode 遍历同时发现 App 数据根目录和安装包 UUID 目录；对每个已发现安装包目录逐个尝试独立的 `worse_query` 只读授权后读取 `Info.plist` 与资源图标。新增 UIKit 原生图标查询回退，并在「高级设置 → 访问诊断与手动添加」列出安装目录发现数、成功授权数、本地 Info.plist 与图标读取数，以便验证实际权限边界。若 Apple 不授权，不能宣称图标已成功读取。
- v8 修复 v7 的一个真正的枚举错误：当数据容器与应用安装包位于不同 APFS 卷时，`pathleak_multiple` 原来只使用第一个目录的 `fsid`，会让第二个卷的扫描永远为零。现在分别 `statfs` 每个目录、按卷分组并针对每个卷单独调用 `fsgetpath`；统一使用 500 万 inode 限额，避免以数据卷 inode 上限限制安装包卷。首页默认隐藏已确认的少数 Apple 内部服务容器，右上角可恢复显示；切换时清空已选中项目，防止隐藏项目被误清理。**不能保证该修正会突破 iOS 27.0.1 对安装目录的沙盒限制；诊断结果仍应为准。**
- v9 根据真机显示问题精简列表：完全移除 App 行的蓝色通用图标占位，也不再进行耗时的图标读取；将名称已识别、仅获 Bundle ID、只有数据目录 UUID 的容器分组显示，后两组默认折叠。全选只作用于当前显示的条目；搜索可按名称、Bundle ID 或完整 UUID 定位。重新扫描区采用紧凑的缓存统计与进度说明，删除动作仍须显式选中和确认。
- v9 的关键身份限制：**容器 UUID 是 `/var/mobile/Containers/Data/Application/<UUID>` 的目录标识，不是 App 名称，也不是 Bundle ID**。本项目移植 3105 的部分 MCM/LaunchServices/MobileInstallation 只读发现和缓存扫描方法，但没有移植原项目的完整权限提升与容器激活路径。若系统拒绝 `.com.apple.mobile_container_manager.metadata.plist`（例如 `errno=1`），且保存状态与偏好文件也没有可靠线索，便无法把仅有 UUID 的目录安全映射到具体 App。离线的少量确切 Bundle ID 显示名也属于回退映射，不应解读为已读取系统原始名称。系统内部服务可能没有用户可见的 App 名称。
- v10 依照参考界面将搜索入口调整为无边框的浅灰色胶囊：空闲时放大镜和「搜索」居中，进入编辑后自动展开输入区域，并支持清除、搜索键提交与滚动收起键盘。扫描摘要的统计、重新扫描和清理按钮合并为一张紧凑卡片，App 行略收紧纵向留白；不改扫描权限、目标识别和删除范围。
- v11 修复 v10 中 `TextField` 自身留白导致的假居中：未编辑时用独立的按钮将放大镜和「搜索」作为一个整体在胶囊内**严格水平居中**，点按后才切换为可编辑搜索框并请求键盘焦点。整个搜索区域从顶部导航栏的白色区域移到浅灰色分组背景，视觉上和工具栏分开、与下方缓存清理卡片归为同一区域。搜索、清除、键盘收起与筛选行为保持不变。
- v12 收紧「有限清理模式」图标与文字的间距（显式 6pt），缩短首页冗长的分组说明、统一运行结果的次级文字样式；保留完整的名称识别计数和 `errno` 细节到「高级设置 → 访问诊断与手动添加」，首页只显示扫描摘要。修复联网补全提示中错误的字符串插值、重新扫描失败时保留陈旧的缓存大小、清理失败时保留陈旧大小以及更换 App Group 仍沿用旧扫描结果的问题。删除自 v9 停用、从未被当前 UI 调用的本地图标解码/私有 UIKit 图标查询方法、单 App 扫描/清理包装及未使用的示例常量；不改变可清理路径、授权检查及用户确认流程。
- v12 权限说明：真机反馈 `.com.apple.mobile_container_manager.metadata.plist` 在 248 个容器上均返回 `EPERM (errno=1)`，即元数据文件读取被拒绝。可读取 `Library/Caches` 与 `tmp` **不等于**可读取该隐藏元数据文件；仅修改路径或重复 `openat` 不保证能解除沙盒限制。本版本保留元数据、Saved Application State、Preferences 与 MCM/LaunchServices 的多级识别路径；无法确认的 UUID 仍如实归类为「未识别数据容器」，绝不据此猜测所属 App。
- v13 移除右上角重复的「管理已排除 App」入口，仍保留左上角的排除管理；移除普通使用无必要的「显示系统内部服务」切换，已知系统内部辅助服务始终从可选列表隐藏。导航栏按钮统一使用 19pt SF Symbol + 24pt 居中图标区域，页面常规操作统一使用 18pt + 22pt 图标区域，列表勾选区固定 24pt，折叠提示符固定 18pt，原生菜单图标统一使用 17pt + 22pt 布局。将菜单名称缩短为「联网补全 App 名称」，保留该功能，但只用于已经识别 Bundle ID、缺少名称的项目。
- v13 联网功能实测：通过 Apple iTunes Lookup API 请求 `bundleId=com.wuziqi.SenPlayer&country=cn`，返回 `resultCount=1`、`bundleId=com.wuziqi.SenPlayer`、`trackName=SenPlayer - 全能视频播放器 网盘直连`。该 Bundle ID 不在内置固定名称表中，表明联网补全**确有作用**。但 App Store 下架、未上架、地区不匹配的应用可能查不到；只有 UUID 的 168 个未知容器没有 Bundle ID，无法通过这个接口推导所属 App。
- v14 重新整理「高级设置」页：将权限状态、专用 App Group、深度发现、手动添加及访问诊断拆分为清晰分组；长日志默认折叠，签名声明的组与可访问状态仅在展开诊断后显示；安全提示保留但不再占据主要界面。首页的三种 App 分组标题全部使用同一字号、字重及颜色；折叠分组的额外说明只在展开时出现；运行结果默认折叠以减少长文占屏。此版本是 UI 优化，没有改变权限、清理目标或授权确认逻辑。
- v15 依据 iOS 27.0.1 真机截图继续校正布局：主界面「有限清理模式」标题使用更窄的 16pt 图标槽和 4pt 间距，字号与 App 分类标题一致；高级设置的风险说明不再使用 Form 原生 Label 自动图标列，改为 14pt 图标槽 + 6pt 文字间距的多行顶部对齐布局。状态、深度发现、添加容器、诊断入口统一为 20pt 图标槽和 8pt 行间距，避免系统默认 Label 布局造成图标与文字分离。精简长脚注与无授权提示，并将未授权警告提前到 App 列表之前；不改任何缓存扫描/删除或 App Group 安全约束。CI 另外尝试生成模拟器布局截图作为可选检查：模拟器启动参数仅用于展示高级设置，不会变更真机扫描流程。
- v16 高级设置的 App Group 风险图标改用 14pt 图形及 17pt 宽度槽，提示正文改为 13pt footnote，并按首行基线对齐；首页选择菜单移除分割线。没有选中项目时隐藏「取消全选」和「排除选中的 0 个 App」空操作；有选中项后再显示这两个选项，保持菜单紧凑。无排除项目时不再显示无意义的零计数。这一版仅调整排版和菜单呈现，不更改现有清理或权限逻辑。
- v17 彻底移除 App Group 安全提示前的警告图标和自定义图标容器；提示改用系统原生 Section footer 的左对齐纯文本样式，同时删除无用的 `warningFootnote` 辅助视图。安全提示内容、缓存清理和权限逻辑保持不变。
- v18 左上「选择操作」和右上「更多选项」不再使用系统自动留出大图标列的 Menu，改为统一的紧凑 SwiftUI popover：17pt 图标、17pt 文本、20pt 居中图标槽、8pt 图文间距、44pt 行高；移除重复的旧 `menuItem` 布局。联网补全文案精简为「补全App名称」。增加两侧弹窗的模拟器截图检查，保留原有功能和安全限制。
- v19 根据真机反馈，将左右两个弹窗的图标和文字一起缩小到 15pt，图标槽调整到 18pt，行高缩至 40pt；「排除选中的 App」从面积过大的 `eye.slash` 换为与「全选」「取消全选」同系列的 `minus.circle`，使视觉重心更一致。「管理已排除 App」保留语义清晰的列表图标。模拟器同时截图左侧已选项目状态以核对新增图标；权限和清理逻辑没有变化。
- v20 中间排序从系统字号不受控的 Menu/Picker 改成与两侧共用的紧凑 popover，保留当前排序方向的勾选标记；三个菜单文字和图标统一使用系统 `.subheadline`（标准字号下 15pt，可随动态字体设置缩放），每个操作保证至少 44pt 可点击高度。工具栏四个 SF Symbols 改为各自等比缩放至同一个 20pt 光学边界，再置于 24pt 居中槽位，避免仅统一字体大小却出现图形实际尺寸不一致。CI 增加无遮罩工具栏和排序弹窗的模拟器截图。未修改扫描、识别和删除逻辑。
- v21 三个操作菜单统一针对图标视觉尺寸作光学校正：文字仍保留 `.subheadline`（15pt），全部菜单图标改为 `.footnote`（13pt）并居中于 16pt 图标槽，图文水平间距从 8pt 收到 7pt。解决同样用 15pt 时 SF Symbols 的勾选、放大镜、齿轮等实际视觉高度明显大于文字的问题。未修改功能逻辑。
- v22 再次根据真机截图修正图标的实际绘制边界：左／中／右菜单共用 14pt 位置槽，常规符号按 12pt 边界绘制，勾、放大镜和齿轮按 11pt 边界绘制，文字仍为 15pt；图文间距减至 6pt。顶部三个工具按钮改成同一个紧凑组（44pt 按钮点击区域、组内无额外间隔），避免系统在三个独立 ToolbarItem 之间追加多余空白。首页搜索图标缩到 15pt，图标位置槽 17pt、搜索展示时图文间隔 4pt（输入模式为 6pt）。CI 将右侧弹窗截图提前并延长一次截图等待，降低连续重启造成的空白截屏概率。清理与识别逻辑不变。
- v23 只收紧左／中／右三个弹出菜单的纵向排版：菜单行高从 44pt 调整至 38pt、行间距从 2pt 调为 0、容器上下及四边内边距从 6pt 改为 5pt。保留 v22 的 15pt 文字、11–12pt 图标视觉尺寸、6pt 图文间距和全部按钮功能，减少菜单空白、避免重新引入尺寸不统一。
- v24 依据 iPhone 16 Pro／iOS 27.0.1 真机截图统一高级设置页面的字体层级：Picker、Toggle、手动添加、日志入口、状态与扫描操作均使用 17pt `.body` 主文字，副标题统一为系统 `.caption`，Form 单行最小高度 48pt，双行状态卡保留一致的自然高度。将「专用 App Group」简化成「App Group」，「确认是 Cleaner 专用组」简化成「Cleaner」，保留下面关于专用组风险的提示。模拟器截图使用测试专用的示例 App Group 以检查两行设置完整布局，且优先选择 iPhone 16 Pro；不修改真机权限和清理逻辑。
- v25 根据真机跨页面对照修正 v24 字号失配：高级设置中状态、Picker、Toggle、扫描操作、手动输入/添加和诊断入口全部回归 15pt 系统 `.subheadline`（保留 12pt `.caption` 副标题），移除单行最小高度 48pt 的强制设置，恢复系统紧凑行高；首页「运行结果」改为复用「仅识别 Bundle ID」与「未识别数据容器」的同一个 13pt semibold 分组标题组件。保留 v24 的 App Group／Cleaner 简称、菜单图标布局及所有清理权限控制。
- v26 复核 v25 模拟器布局后，发现高级设置的五个分组标题仍使用比首页明显偏大的系统默认标题样式；将「访问状态」「App Group 设置」「扫描工具」「手动添加」「诊断信息」全部直接复用首页 13pt semibold 分组标题组件。高级设置一级操作文字仍统一 15pt，副文字、按钮尺寸、清理与访问权限机制不变。
- v27 根据 iPhone 16 Pro 真机上三个弹出菜单的纵向留白反馈，统一将菜单操作行最小高度从 38pt 微调为 36pt，容器上下内边距从 5pt 收到 3pt；左右内边距仍为 5pt，行间距继续为 0。左侧选择、居中排序和右侧更多菜单仍共用一个布局组件，15pt 文字、11–12pt 图标视觉尺寸和 6pt 图文间距不变；不会影响其他页面及缓存逻辑。
- v35（基于 v27）仅在 v27 基础上微调三个原生 popover：公共菜单宽度改为当前屏幕的 1/2、操作行最小高度改为 22pt，其他弹窗字体、系统圆角、上下 3pt／左右 5pt 边距、图文 6pt 间距和行间距 0 均保持 v27 原样；高级设置仅把「查看访问诊断日志」的文档放大镜图标向右光学校正 2pt，保持文字起点不变。
- v46（基于 v45）对照 iOS 27 原生 SwiftUI 列表、Form、SF Symbols 和动态字体排查 UI 回归：高级设置的访问状态、扫描操作、手动添加、诊断入口统一使用图标和主标题首行对齐的设置行组件，修复 v45 只对访问状态做顶部对齐造成的跨行不一致；状态徽章在无访问权限时不再错误显示绿色；移除扫描动作中具有导航误导性的 chevron；首页统计区在辅助功能超大字号下改用纵向布局、运行状态允许换行；补充高级设置实际行的 UI 测试和超大字号截图。保留 v44 的卡片比例、圆角、主导航结构与所有扫描/清理/授权约束。
- v47 统一改用 SwiftUI 语义 `Label` 和系统 `.titleAndIcon`，但实际 iPhone 16 Pro 截图显示系统自动图文间距过大，双行文字对应的图标仍贴近第一行；因此不能把使用系统组件等同于视觉验收通过。扩充了深浅色及辅助功能截图项目。
- v48 根据 v47 真机截图将设置项改为统一的自定义 `LabelStyle`：保留语义 `Label` 和系统动态字体，22pt 动态预留图标槽、同级图标相同的字号字重，明确使用以完整标题＋副标题块为基准的 `.center` 垂直对齐；图文间隔按实际效果收紧为可随字体缩放的 8pt（非 Apple 规定值）。不采用单图标 `.offset`，其它不同用途图标的尺寸保持层级区分；保留 v44 的整体卡片、字号、导航比例及扫描/删除安全逻辑。
- 首次载入自动执行慢速 inode 深度发现（可能耗时数分钟）；对之前已经确认过的**同一个专用 App Group**，会自动继续扫描缓存。首次新组需要用户确认后手动触发扫描。
- 可选择一个或多个 App 后「排除选中」，排除项会从首页列表和批量扫描/清理里跳过；可在**左上角**「管理已排除 App」恢复。排除信息保存在本地 App 设置中，按容器路径识别，App 重新安装导致 UUID 改变时需重新排除。
- 权限设置、手动添加与可展开的访问诊断位于右上角「高级设置」。
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

GitHub Actions: `.github/workflows/worse-cleaner-ipa.yml` 在 `worse-query-cleaner`、`worse-query-cleaner-fix` 及 `worse-query-cleaner-v3` 至 `worse-query-cleaner-v27` 分支提交时构建未签名 IPA。
