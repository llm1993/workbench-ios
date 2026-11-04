# 有数原生界面

本轮将已确认的有数原型转成 SwiftUI，不嵌入 HTML，不更改工作台账户协议、剪贴板协议或后端计算。公开版本另采用中性应用及 Keychain 标识，按新 App 安装，不自动继承旧沙盒或钥匙串；详见公开快照说明。

## 页面与操作

- **总览**：物品净值、累计投入、在用日均成本；待补估值、到期提醒及在用物品。这里的物品列表按购入日期排列，不把没有数据支持的“最近使用”当成真实记录。
- **家底**：搜索、服务器品类、状态与标签筛选、排序；所有物品使用同一种列表行。底部固定总览、家底、心愿、复盘和中间的新增入口。
- **物品详情**：扣残值日均成本、账面投入与残值；概览、台账、提醒分段；固定“记一笔”和“更新估值”。封面使用本地品类示意图标，不代表增加了照片上传或识别能力。
- **次级入口**：提醒铃铛打开完整待办；完整统计保留净值/投入、在用日耗、月度统计、状态及成本排行；复盘保留实际卖出盈亏与原钱包漏洞分析。
- **表单**：新增物品先填名称、单价、日期、品类。数量、折旧参数、估值、目标、标签和备注在“更多信息”中；即使没有展开，也会按原值验证和提交。新增成功关闭表单后进入该物品详情。
- **原有管理**：成本/收益/估值快照的新增与删除、提醒新建/编辑/完成/停用/删除、退役/恢复、出售、物品删除、心愿/攒钱和导出均保留。删除与状态变更继续经过确认，不做演示原型中的本地假提交。

## 数据边界

所有生产金额与趋势都来自现有 API。持有日期、Decimal 舍入、数量、未知残值、折旧、收益及出售口径仍由后端 `metrics.py` 决定。

列表的日均成本来自 `gross_daily_cost`；详情主值来自 `net_daily_cost`。未知估值显示待补，不替换为 0；负净成本保持负数。总览净值沿用后端未知估值暂按账面投入的规则，并显示待估值数量。

后端 `sort=value` 表示**账面投入**。当前估值排序在已按服务器筛选出的完整列表中进行，未知值排在已知零元之后，不向服务器发送一个不存在的排序参数。

当前估值操作使用 PATCH 更新 `current_value` 并显式切换为手动估值，由后端留存快照；历史估值仍有独立入口。已卖出物品以成交价计值，因此不提供会误导用户的“更新当前估值”操作。

数据协调器按服务器、令牌、请求路径隔离内存缓存。共用读取可以合并，取消一个读取方不取消其他读取方。成功写入后使所有读取缓存失效，旧读取不能恢复过期结果；旧表单不能使用新会话提交。

金额隐藏是当前模块的展示偏好，不是额外的登录或加密功能。它隐藏结构化金额、图表/数据表和带金额的成本分析标题，不修改数据；显式打开的编辑输入仍显示原值。

## 视觉与图表

复用全局 `Theme` 的页面、表面、正文和操作色，保留主题选择能力。正文使用系统动态字体；底部操作通过安全区布局，辅助大字时详情按钮改为纵向。没有自动播放动画，也不覆盖系统返回导航。

图表使用真实日期轴、零基准（允许负值）、2pt 数据线、8pt 末端标记与 2pt 背景环；可点选日期并展开数据表。默认物品成本只显示一条线，其余成本对比按需展开。数据线配色独立于操作/警告色：

| 角色 | 浅色 | 深色 |
| --- | --- | --- |
| 单条物品日均成本 | `#287F4F` | `#3F9E69` |
| 对比第一序列 | `#2A78D6` | `#3987E5` |
| 对比第二序列 | `#EB6834` | `#D95926` |
| 目标日耗/第三序列 | `#1BAF7A` | `#199E70` |

验证背景为浅色 `#F5F5F1`、深色 `#151816`。三序列通过 all-pairs 色觉/普通视觉分离度检查；浅色橙色、青绿的对比度低于 3:1，使用常驻系列数值、图例、不同线型和数据表作为补充，不仅靠颜色区分。目标线的颜色与线型不会因净成本缺失而变化。

## 验证入口与证据边界

Windows 可运行：

```bash
python scripts/check-native.py --syntax-libs ../scratch/ipa-ui-build-checks
```

```bash
python scripts/check-contracts.py
```

```bash
python scripts/check-reader-cache.py
```

```bash
node scripts/check-mortgage.cjs
```

`AssetsLibraryTests` 覆盖过滤参数、未知值排序、金额隐藏、台账身份、真实日期轴、折叠表单、读取缓存、并发请求、会话隔离、写入失效与失败重试。`InterfaceTests` 中的 `testAssets*` 覆盖底部入口、动态品类/搜索、记录成本、补估值、新增物品、提醒/复盘/统计、保存失败和深色辅助大字。

DEBUG 预览由 `AssetsPreviewFixtures` 提供，仅拦截 `example.invalid`，使用锁保护的内存数据；不会访问真实账号或持久化。`--assets-save-failure` 只让第一笔有数变更失败，重试可以成功。预览中的计算只用于合成测试数据，不能代替后端指标回归或真实服务验收。

macOS 上生成 Xcode 工程后，可分别选择运行：

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme ClipStudio -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:ClipStudioTests/AssetsLibraryTests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
```

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme InterfaceChecks -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO test
```

本轮 Windows 本地检查不包含 Swift 类型检查、Xcode 构建、模拟器截图或真机/真实服务验收。新增 XCTest 与 UI 用例仍需在 macOS 运行；不将此前 0.3.5（9）的构建结果视为这些修改的验证，也不自动触发工作流。
