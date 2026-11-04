# 原生房贷界面改版

本次将已确认的原型视觉方向应用到 SwiftUI 房贷模块，不使用 WKWebView，也不改变计算资源或云端方案格式。公开版本另采用中性应用标识，按新 App 安装，旧沙盒不会自动迁移；详见公开快照说明。

## 界面与数据边界

- 松柏绿月供主卡、雾灰背景、白色参数与图表区域；浅色与深色分别定义颜色，支持动态字号。
- 三个入口：买房试算、我的房贷、提前还款。提前还款可以选择基于试算或现有合同；仍只保存后端支持的 `new` / `current` 两种方案，展示场景不写进云端协议。
- 月供与成本优先展示，参数按需展开。现有合同缺少必要字段或输入无效时自动展示编辑区，不显示虚构的零月供。
- 组合贷、历史利率/加点调整、已发生的提前还款、银行本金校准、未来 LPR 情景仍可编辑。
- 方式对比、策略对比、还款计划、已还记录、图表数据与计算说明改为原生弹层；明细保留年度汇总与逐月记录。
- 原有按账户/服务器隔离的本机草稿、云端保存/另存/载入/删除、未保存修改提醒和 409 冲突处理保留。

## 代码分工

| 文件 | 职责 |
| --- | --- |
| `Features/MortgageView.swift` | 场景、草稿、云端方案协调与合同编辑。 |
| `Features/MortgageComponents.swift` | 局部主题、主卡、参数控件和策略选项。 |
| `Features/MortgagePresentation.swift` | 把现有计算结果转为月供、成本、期数和图表数据。 |
| `Features/MortgageChart.swift` | 原生 Charts 曲线、选择读数和辅助数据入口。 |
| `Features/MortgageDetailSheet.swift` | 原生比较、明细、数据与说明弹层。 |

`project.yml` 已按目录收集应用、单元测试和 UI 测试源码，无需编辑生成的 `.xcodeproj`。

## 展示口径

- 提前还款后的月供取 `rows[after]`，即提前还款完成后的第一期，不误用提前还款之前的首期。贷款已在提前还款时结清则显示后续月供 0。
- 新组合贷的 `savedMonths` 是所选贷款缩短的月份，不冒充整笔组合贷的缩短时间；现有多合同按整体剩余计划比较。
- 现有房贷立即提前还款时，计算引擎的未来 `paid` 不包含第 0 期那笔本金。展示的未来还款总额使用当前剩余本金加未来利息，包含这笔立即还款。
- 立即提前还款的对比曲线从还款后的余额起画，仅扣除所选合同实际可偿还的本金。
- 摘要显示实际生效的提前还款金额；计划金额超过可偿还本金时，另行标注计划金额，不把超额输入当作实际还款。
- 恢复无效草稿或提前还款条件未完整时，将编辑区保持为显式展开；输入首个有效数字、计算恢复成功后不会自动收起正在编辑的表单。
- 图表用固定的实线绿 / 虚线紫，不随场景过滤重新分配颜色；单轴、从零起、可按住查看，并提供逐年数据列表。

## 检查

Windows 可运行：

```bash
node scripts/check-mortgage.cjs
```

```bash
python scripts/check-native.py --syntax-libs ../scratch/native-check-libs
```

```bash
python scripts/check-contracts.py
```

```bash
python scripts/check-reader-cache.py
```

新增 `Tests/MortgagePresentationTests.swift` 覆盖选中还法、提前还款后月供、提前结清、组合贷缩短口径、立即还款汇总与图表起点、空数据等情况。新增 `UITests/MortgageInterfaceTests.swift` 覆盖三个场景的入口、方式/策略比较、参数展开、图表数据、明细、深色与大字号，并附 XCTest 截图。

原生编译、XCTest、UI 截图与真机验收需要 macOS/Xcode。Windows 上的语法和协议检查不等于 Swift 类型检查或界面验收。本次没有自动触发手动构建工作流，也没有生成 IPA。

在 macOS 上先执行 `xcodegen generate`，再将下面的 `<UDID>` 替换为可用模拟器：

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme ClipStudio -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO -only-testing:ClipStudioTests/MortgagePresentationTests test
```

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme InterfaceChecks -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO -only-testing:ClipStudioUITests/MortgageInterfaceTests test
```
