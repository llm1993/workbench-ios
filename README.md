# 工作台 · iOS

原生 SwiftUI 工作台，包含有数、未读、加密剪贴板与文件传输、股讯和房贷计算器。最低支持 iOS 17。

当前源码版本为 **0.3.7（11）**，在有数与房贷原生改版的基础上，加入原生局域网文件直传。此仓库从整理后的当前源码建立，不导入旧 Git 历史、旧构建记录或本机产物；测试和构建状态以本仓库的 Actions 为准。

## 使用与数据

- 首次使用需填写自己部署的工作台 HTTPS 根地址，例如 `https://workbench.example.com`；示例域名不是可用服务。
- 登录账号与剪贴板加密解锁是两个独立步骤。除可选的本机阅读库外，工作台功能需要兼容的后端；本仓库不包含后端服务、账号或数据库。
- 登录令牌和内容密钥由运行时写入 Keychain，不应放入源码或配置文件。剪贴板正文在设备端加密。
- 文件传输提供原生 Windows ↔ iOS 局域网直传与明确选择的云端中转；首次配对和收件需确认，直传不会静默转为云端上传。见[使用与验证边界](docs/lan-transfer.md)。
- 房贷通过 JavaScriptCore 调用随 App 打包的纯计算资源，不嵌入或下载网页应用。
- 未读是独立的原生框架模块，保留阅读、缓存、媒体、全文和离线状态处理。

项目与 scheme 仍名为 `ClipStudio`，公开版本采用中性 Bundle ID `com.example.workbench`，阅读框架标识为 `com.example.workbench.reader`，Keychain service 与应用标识一致。此版本按独立新 App 安装，不覆盖旧 App，也不会自动继承旧 App 的沙盒和 Keychain；原 App 可以继续保留。云端账号数据和剪贴板加密协议不因更换本机安装身份而删除或改变。

本版本的快捷入口使用 `workbench://send` 与 `workbench://get`，避免与旧 App 的 URL 入口冲突。

## 构建

项目使用 XcodeGen。请修改 `project.yml`，不要手工维护生成的 `.xcodeproj`。

在 macOS / Xcode 上：

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
xcodebuild -project ClipStudio.xcodeproj -scheme ClipStudio -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

GitHub Actions 的 **iOS Build** 仅手动触发。默认重新运行原生单元测试；启用 `interface_checks` 后，会运行原生界面检查并导出测试截图。构建产物为 `ClipStudio-unsigned-ipa`，**未签名，必须自行签名后才能安装**。

独立的 **iOS Interface Checks** 要求本仓库内成功且产品源码相同的 `source_run`。验证复用会核对运行来源与源码，不能使用其他仓库或不同源码的历史成功记录。

## 本地检查

以下检查不连接生产服务，也不构建 IPA：

```bash
python -I scripts/test-sensitive-check.py
```

```bash
python -I scripts/check-sensitive.py
```

```bash
python scripts/check-reader-cache.py
```

安装检查工具依赖后，验证局域网协议向量和通道边界（不连接设备）：

```bash
python -m pip install -r scripts/requirements-checks.txt
```

```bash
python scripts/check-lan-transfer.py
```

`scripts/check-contracts.py`、`scripts/check-mortgage.cjs` 和完整的 `scripts/check-native.py` 是跨项目开发检查，需要另外提供同级 `workbench` 后端/PWA 与 `weidu-ios` 参考源码，以及各自所需依赖；它们不是独立 Xcode 构建的前置条件。Windows 上的语法或协议检查不等于 Swift 类型检查、模拟器测试或真机验收。

原生测试 scheme：

- `ClipStudio`：应用与阅读模块单元测试。
- `InterfaceChecks`：界面测试。
- `AcceptanceChecks`：单元测试与界面测试。

## 安全与公开范围

- [公开快照说明](docs/public-snapshot.md)
- [有数界面与数据边界](docs/youshu-ui.md)
- [房贷界面与验证边界](docs/mortgage-ui.md)
- [局域网文件传输与验证边界](docs/lan-transfer.md)
- [原生阅读模块来源](Modules/README.md)

请勿提交真实账号、Token、环境文件、签名证书、私钥、本机数据库或个人日志。固定的协议测试向量与 DEBUG 模拟数据不是生产凭证。

敏感信息检查工作流使用只读权限的 Linux runner，不构建或发布 IPA。它检查当前源码，不能代替对新提交、图片、历史记录或发布附件的人工复核。

## 许可

本仓库尚未指定通用开源许可证；公开源码不等同于已授予任意复用授权。第三方依赖及嵌入模块的版权与许可要求应分别遵守。
