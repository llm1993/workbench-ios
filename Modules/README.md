# 未读原生模块

按用户要求直接迁入同级 weidu-ios 的完整原生实现，不再维护简化的 WorkspaceReader。

- 源码基线与逐文件 SHA-256 见 weidu-source.json。
- WeiduApp.swift 的独立 @main 入口替换为公开的 WeiduModuleView，原 RootView、Store、Database、阅读/媒体/缓存/订阅/OPML/设置均保留。
- WeiduKit 独立模块隔离同名 RootView / Store / Theme / SettingsView；SwiftSoup 与 SQLite 沿用原工程配置。
- 原 ReaderFeaturesTests 一并迁入 WeiduKitTests，并补充设置兼容等回归覆盖；此前用例已纳入 0.3.0 的原生测试。
- 原模块 36 份源码中有 13 份作了明确调整，逐项理由见 weidu-overrides.json；其余 23 份与来源哈希一致。包括独立应用菜单、可切换的卡片/平铺列表、毛玻璃底栏、可选云端 Store/Database、文章工具入口、列表更新开销优化、首条顶部占位修正、正文加载/渲染过渡和存储说明；不是重新实现简化阅读器。
- 默认「工作台同步」：订阅与状态由现有 API 管理，本机缓存及离线修改队列放在 Application Support/Weidu/Cloud/<账号和服务器摘要>。阅读状态先落盘再更新，旧回执不能删除新版本修改。缓存正文、选中订阅、阅读偏好也按账号隔离。
- 「本机阅读库」仍使用原 SQLite/AppSettings 行为，不随账号切换；与云端库明确区分。原独立未读 App 的沙盒不会自动转移；可通过 OPML 导入订阅，OPML 不包含阅读状态和缓存。
- 扩展由宿主原生 ReaderHub 通过 WeiduWorkspaceConnection 接入：AI 只 GET 缓存、点按钮才 POST 生成；每日摘要、订阅管理、多选过滤、稍后读及专用口令、RSS 发现、网页监测均调用原服务。令牌不写入模块缓存；401/账号切换由宿主处理。
- 原生阅读手势、全文切换、媒体、缓存清理、OPML 和排版沿用原模块。云端全文端点不支持强制重抓，所以该模式隐藏本机才有的「重新抓取」操作。
- 0.3.4 的 WeiduKitTests 共 36 项通过，覆盖增量分页/回执交错、前台保留列表、双击隐藏与返回顶部、密度规则、批量已读/计数、离线合并/旧回执、事务回滚与正文保留等；17 项原生 UI 检查通过，包含独立单元格、左滑、提前续页、前后台位置、样式重启保留和底栏留白。check-reader-cache.py 直接取实际 Swift SQL 在临时 SQLite 中验证 8 项缓存/事务/读取边界。尚未完成真机性能和业务验收。

功能补齐后用户已授权推送与打包，0.3.0 构建完成。工作流仍不随 push 自动触发，仅按需要手动验证和构建。
