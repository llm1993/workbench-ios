# 原生到手工资模块

SwiftUI 原生到手工资计算器，不使用 WKWebView。计算全部在设备端由 JavaScriptCore 执行随 App 打包的纯计算资源，不调用工作台接口，也不上传工资数据。

## 2026-11-12 · 首版界面

- 青绿操作色配暖白内容区，深色模式独立定义色值；到手主数字使用可缩放圆角字体，撕纸分隔线、资金流向条和指标行构成主卡层级。
- 到手试算、工资条、对比改为常驻底部导航，使用安全区域布局；切换场景收起键盘并回到顶部，滚动超过一屏后出现吸顶摘要与「回到顶部」，大字号时导航纵向排列。
- 参数区常驻展开，不折叠：城市、税前月薪与滑杆、社保基数（自动 / 自定义）、公积金比例与基数、专项附加扣除、年终奖与发放月份和计税方式、其他税前扣除、税后扣款、入职月份。城市切换会带出该城市的公积金比例示例。
- 逐月图表为自绘堆叠柱（不使用 Charts 框架），支持「工资 / 含年终奖」两种口径、点柱选月、跳档 `↑N%` 标注和未入职月份的矮柱；配色固定，不随口径重新分配。
- 工资条场景按月展示应发项目、个人扣除、可选的单位缴纳成本、到手合计，以及累计预扣的分步算式和可复制的公式文本。
- 对比场景包含年终奖单独 / 合并计税差额与盲区提示、两份 offer 对比、涨薪边际收益和全年到手柱状概览。
- 方案、计算口径说明、城市预设、年度明细、月份选择和导出文本均为原生弹层。
- `Design/salary-v1/index.html` 是可交互设计预览，复用同一份打包计算资源；`preview-*.png` 是该预览的浏览器截图，不是 iOS 模拟器截图，也不进入 App。预览中的城市与收入是明确标注的示例值。

设计预览已在浏览器通过 62 项断言（三种场景、参数编辑、跳档与盲区、深色、320px 大字号无横向溢出），未记录脚本错误；结果保存在 `Design/salary-v1/verification.json`。

Windows 本次运行 52 项计算检查、8 项原生适配器检查通过，117 个 Swift 文件语法检查通过。新增 `Tests/SalaryTests.swift`（11 项）与 `UITests/SalaryInterfaceTests.swift`（5 项），两套 XCTest 已在下方记录的 macOS 完整构建中执行并通过。

### 原生构建记录

2026-11-13 的 [完整 iOS 构建 #13](https://github.com/llm1993/workbench-ios/actions/runs/43354596126) 对产品源码 `5c9ee2fea258f0ee3686aaa0ab8fda630f5bf836` 执行 `full` 验证并成功生成 **0.3.9（13）** 未签名 IPA：

- 应用单元测试 106 项、阅读模块单元测试 65 项，全部通过；其中工资计算测试 11 项，覆盖示例数字、累计预扣跳档与负零、年终奖档位与盲区、社保夹取、图表口径、未入职月份、offer 与涨薪、工资条文本和本地模块注册。
- 界面测试 48 项全部通过；其中工资界面测试 5 项，覆盖三场景可达与重算、工资条算式与单位成本、对比场景、弹层套用方案与跳月、辅助字号可达性。
- 原生测试、iPhone arm64 Release 编译和 IPA 打包均在同一次运行完成，没有复用其他源码的测试记录。
- `validation` 附件保留 `tests.log`、`simulator.log`、`validation-summary.json` 和 18 张工资 XCTest 原生截图（`screenshots/manifest.json` 对号）。截图使用测试示例数据；模拟器验收不能替代物理设备试装。
- 下载后复核 IPA：版本 0.3.9（13）、标识 `com.example.workbench`、iOS 17 最低版本、arm64、未签名；SHA256 `e189aaa3c5ebe47c1eb0b685d792bcb061097469e43d2f61a3c8875e4c3fffad`，本地交付路径 `D:\git\Termux\scratch\ipa\ClipStudio-unsigned.ipa`。安装需先用 Sideloadly 等工具以自有 Apple ID 重签（免费账号 7 天需重签）。
- 已人工逐张复核浅色、深色、辅助字号、参数编辑、工资条（含单位缴纳与个税算式）、对比与弹层的原生截图，并手算核对到手、扣除、累计预扣与年终奖择优数字；三个底部导航图标正常显示，大字号无横向溢出。

## 界面与数据边界

- 模块只在本机计算，没有服务端接口，也就没有可校验的应用权限。门厅在服务器返回的应用卡片之后**本地追加**「到手工资」卡片，不写入 `/api/auth/me` 的应用清单。
- 因此这张卡片不参与门厅设置的排序与隐藏：布局编辑器只接受后端认识的 key，追加未知 key 会被拒绝。服务器应用列表里若出现同名 key 会被过滤，避免重复卡片。Web 门厅不受影响。
- 草稿与本机方案按「服务器地址 + 账号」隔离，写入 Application Support 下的 `salary-<SHA256>.json`，使用原子写入与完整文件保护；账号切换后不会读到上一个账号的草稿。没有云端保存、另存或冲突处理。
- 内置 5 个示例方案（上海 · 一娃租房、北京 · 双娃房贷、深圳 · 应届入职、杭州 · 扣除用满、成都 · 低收入并入更划算），可另存为本机方案。示例不是真实薪酬数据。
- 「导出」把工资条文本写入临时文件后交给系统分享面板，由用户明确选择去向，不自动上传云端或局域网。
- 城市社保基数上下限、比例和专项附加扣除标准都是示例预设，界面与导出文本都注明实际以当地社保年度公布口径和工资条为准。

## 代码分工

| 文件 | 职责 |
| --- | --- |
| `Features/SalaryView.swift` | 场景协调、草稿状态、计算触发、本机保存、分享与提示。 |
| `Features/SalaryEngine.swift` | JavaScriptCore 适配器与内置示例方案。 |
| `Features/SalaryPresentation.swift` | 把计算结果转为文案、流向、指标、图表与工资条文本。 |
| `Features/SalaryComponents.swift` | 局部主题、主卡、撕纸线、资金条、菜单与按钮等控件。 |
| `Features/SalaryControls.swift` | 常驻展开的参数表单。 |
| `Features/SalaryChart.swift` | 自绘逐月堆叠柱、口径切换与读数。 |
| `Features/SalarySlip.swift` | 工资条、单位成本与累计预扣算式。 |
| `Features/SalaryCompare.swift` | 年终奖择优、offer 对比、涨薪边际与全年概览。 |
| `Features/SalarySheets.swift` | 方案、口径、城市、年度、月份与导出弹层。 |
| `Resources/Salary/salary.js` | 计算引擎，与 `Design/salary-v1/salary.js` 逐字节一致。 |
| `Resources/Salary/salary-bridge.js` | 原生桥接层，输出 JSON 友好的默认值、税率表与盲区判定。 |

资源按目录整体进入 bundle 根目录，房贷已占用 `calc.js` / `rates.js` / `native-bridge.js`，所以工资桥接文件必须叫 `salary-bridge.js`。`project.yml` 已按目录收集源码，无需编辑生成的 `.xcodeproj`。

## 展示口径

- 工资个税按累计预扣预缴法逐月计算，展示累计收入、累计扣除、累计应纳税所得额、当月税率与速算扣除数，不用「月薪 × 12」的年税近似冒充逐月结果。
- 「其他税前扣除」只减少应纳税所得额，不减少到手金额；「税后扣款」只减少到手金额。两者在界面上分别标注，不混为一项。
- 社保与公积金基数按城市上下限夹取，自动模式下低于下限取下限、高于上限取上限；自定义基数同样夹取，并显示实际生效基数。
- 年终奖单独计税政策执行至 **2027-12-31**（财政部 税务总局公告 2023 年第 30 号）。「自动」在单独与合并之间择优并显示省下的税额；落在跳档盲区时提示临界值、多缴金额和刚好越过盲区的金额。
- 入职月份之前的月份标记为未入职，不计收入也不计扣除；图表用矮柱表示，工资条不虚构该月到手。
- 图表「工资」口径把年终奖从柱子里拆出，只在发放月单独显示；「含年终奖」口径合并计入。跳档标注是当月适用税率相对上月的变化。
- 涨薪边际展示税前增量、到手增量与留存比例，按同一套累计预扣规则重算，不用平均税率估算。
- 金额保留两位小数并避免出现 `-0.00`；万元汇总与元级明细分别标注单位，税率按百分比展示。

## 检查

Windows 可运行：

```bash
node scripts/check-salary.cjs
```

```bash
python scripts/check-native.py --syntax-libs ../scratch/native-check-libs
```

`check-salary.cjs` 直接在 Node 里执行打包的引擎与桥接层，校验示例方案数字、跳档、盲区、基数夹取、专项附加扣除、图表口径、未入职月份、offer 与涨薪指标和工资条文本。`check-native.py` 额外断言 `Resources/Salary/salary.js` 与设计稿引擎逐字节一致。

`Tests/SalaryTests.swift` 覆盖系统图标存在性、示例数字、累计预扣跳档与负零、年终奖档位与盲区、社保夹取与扣除标准、图表口径拆分、未入职月份与工资条诚实性、offer 与涨薪、工资条文本、示例方案与本地模块注册、展示格式。`UITests/SalaryInterfaceTests.swift` 覆盖三个场景可达与重算、工资条算式与单位成本、对比场景、弹层套用方案与跳月、辅助字号下的可达性，并附 XCTest 截图。

原生编译、XCTest 与 UI 截图需要 macOS/Xcode；物理设备验收另行进行。Windows 上的语法与计算检查不等于 Swift 类型检查或界面验收。

在 macOS 上先执行 `xcodegen generate`，再将下面的 `<UDID>` 替换为可用模拟器：

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme ClipStudio -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO -only-testing:ClipStudioTests/SalaryTests test
```

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme InterfaceChecks -configuration Debug -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO -only-testing:ClipStudioUITests/SalaryInterfaceTests test
```