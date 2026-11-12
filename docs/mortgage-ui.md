# 原生房贷界面改版

SwiftUI 原生房贷模块，不使用 WKWebView，也不改变计算资源或云端方案格式。公开版本采用中性应用标识，按新 App 安装，旧沙盒不会自动迁移；详见公开快照说明。

## 2026-11-11 · 第二版界面

- 暖白底色、白色内容区和松柏绿操作色；深色模式独立定义色值。主数字采用可缩放的圆角字体，月供、成本、操作形成清楚的层级。
- 买房试算、我的房贷、提前还款改为常驻底部导航，使用安全区域布局。切换场景收起键盘并回到页面顶部，大字号时导航改为纵向布局。
- 月供主卡取消大面积绿色背景，试算增加本金 / 利息占比条和文字比例；保留原有计算结果与还款方式对比入口。
- 收起的参数区直接显示贷款金额、年限、年利率，组合贷显示贷款类型；展开后保留原有完整表单。我的房贷优先展示各合同进度，再展示曲线，并增加提前还款入口。
- 图表改为固定实线绿 / 虚线琥珀色，实线下方使用轻量面积填充；仍保留原生按住选期、辅助数据和明细入口。
- `Design/mortgage-v2/index.html` 是可交互设计预览，复用打包的计算资源。预览合同与日期是明确标注的示例，不读取账户或草稿，不进入 App，也不是 iOS 模拟器截图。

Windows 本次运行 17 项计算检查、8 项原生适配器检查通过，106 个 Swift 文件语法检查通过。`MortgageInterfaceTests` 已适配底部导航，并补充滚动后切换场景回到月供的检查。

设计预览已在浏览器检查三种场景、组合贷参数编辑、还款方式与提前还款策略切换、深色显示，以及 320px 大字号下核心区域无横向溢出；未记录脚本错误。`Design/mortgage-v2/preview-light.png` 与 `preview-dark.png` 是该预览的截图，不能代替 SwiftUI 实际渲染验收。

### 原生构建记录

2026-11-11 的 [完整 iOS 构建 #12](https://github.com/llm1993/workbench-ios/actions/runs/43011514086) 对产品源码 `77d3ab5aea79bdf65e0197c6155d5b3df4f186a0` 执行 `full` 验证并成功生成 **0.3.8（12）** 未签名 IPA：

- 应用单元测试 95 项、阅读模块单元测试 65 项，全部通过；其中房贷展示测试 11 项，包含三个导航入口的普通与选中图标存在性检查。
- 界面测试 43 项全部通过；其中房贷界面测试 6 项，覆盖底部导航、切换后回到月供、参数编辑、比较与明细、深色和辅助字号。
- 原生测试、iPhone arm64 Release 编译和 IPA 打包均在同一次运行完成，没有复用其他源码的测试记录。
- `validation` 附件保留 `tests.log`、`validation-summary.json` 和 XCTest 原生截图。截图使用测试示例数据；模拟器验收不能替代物理设备试装。
- 下载后复核 IPA 的版本、应用与阅读框架标识、iOS 17 最低版本和 arm64 架构；三份房贷计算资源与上述源码逐字节一致，发布包不含测试或设计预览文件。已人工复核浅色、深色、辅助字号、参数、提前还款与比较面板的原生截图，三个底部导航图标正常显示。

## 界面与数据边界

- 暖白背景、白色月供、参数与图表区域，松柏绿强调操作；浅色与深色分别定义颜色，支持动态字号。
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
- 图表用固定的实线绿 / 虚线琥珀色，不随场景过滤重新分配颜色；单轴、从零起、可按住查看，并提供逐年数据列表。

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

原生编译、XCTest、UI 截图需要 macOS/Xcode；物理设备验收另行进行。Windows 上的语法和协议检查不等于 Swift 类型检查或界面验收。云端完整验证使用手动 `iOS Build` 的 `full` 模式，成功后生成未签名 IPA 和原生截图，并记录 `validation-summary.json`。

在 macOS 上先执行 `xcodegen generate`，再将下面的 `<UDID>` 替换为可用模拟器：

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme ClipStudio -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO -only-testing:ClipStudioTests/MortgagePresentationTests test
```

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme InterfaceChecks -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO -only-testing:ClipStudioUITests/MortgageInterfaceTests test
```
