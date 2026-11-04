# 工作台 App 图标

`workbench-app-icon.svg` 直接复用 `workbench/frontend/desktop/icon-maskable.svg` 的四色方块标记，替换旧剪贴板图标。使用完整方形背景，由 iOS 添加图标外形。

已提交生成的 `ClipStudio/Assets.xcassets/AppIcon.appiconset/icon.png`，1024 × 1024、RGB、无透明通道。日常构建直接使用 PNG，不增加云端构建依赖。

需要重新生成时，在工具环境安装 `scripts/requirements-icons.txt`，运行 `python scripts/render-app-icon.py`；若依赖通过 pip `--target` 安装，可传 `--renderer-libs <目录>`。
