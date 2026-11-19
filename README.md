# LibreTV iOS（自签版）

把开源项目 [LibreSpark/LibreTV](https://github.com/LibreSpark/LibreTV) 打包成可以用全能签等工具自签安装的 iPhone 应用。

## 安装

到 [Releases](../../releases) 下载最新的 `LibreTV-<版本>.ipa`，用全能签签名安装即可。

- 打开即用，不需要另外部署服务器，也不用输入访问密码。
- App 不内置任何视频源：在「设置 → 源管理」里自己添加点播源 / 直播源或订阅。
- 下载的视频和导出的文件在「文件」App →「我的 iPhone」→ LibreTV 里，日志在 `logs/node.log`。

## 工作原理

LibreTV 现在是 Next.js 服务端应用（搜索聚合、m3u8 代理、登录都在服务端）。本项目把它的服务端整体放进 App：

1. App 内嵌 [nodejs-mobile](https://github.com/nodejs-mobile/nodejs-mobile)（Node 18），启动时在本机 `127.0.0.1:38080` 运行 LibreTV 的 standalone 构建，只对本机开放；
2. 原生壳（Swift + WKWebView）等服务就绪后打开页面，并用本机随机生成的密钥自动登录；
3. iOS 禁止 App 使用 JIT，Node 只能以 `--jitless` 运行，没有 WebAssembly，而 Node 自带的 `fetch` / `undici` 依赖 wasm 版 HTTP 解析器。`nodejs/fetch-shim.js` 用 `http`/`https` 模块实现了服务端用到的 `fetch`、`Agent`、`buildConnector`，构建时通过 `IOS_BUILD=1` 把 `undici` 别名过来，LibreTV 原有的 SSRF 防护逻辑保持不变；
4. iOS 挂起 App 后可能回收监听 socket，`nodejs/main.js` 的看门狗会自动重新监听，切回前台即可继续使用。

视频播放、全屏（支持横屏）、画中画、后台播放声音、下载本集、配置导入导出都可用。

## 目录

| 路径 | 说明 |
| --- | --- |
| `libretv/` | 上游 LibreTV 源码（提交 `ae1c250`，版本 2.24.0），仅 `next.config.ts` 增加了 iOS 构建用的 `undici` 别名，`package-lock.json` 的镜像地址改为 npmjs |
| `nodejs/` | App 内 Node 的启动器、无 wasm 的 fetch 实现及其测试 |
| `ios/` | Swift 原生壳与 XcodeGen 工程描述 |
| `scripts/` | 构建、冒烟测试、模拟器测试、打包 IPA |
| `.github/workflows/build-ipa.yml` | 云端构建：单元测试 → Node 18 jitless 测试 → 模拟器实测 → 未签名 IPA → Releases |

## 许可

LibreTV 以 AGPL-3.0 发布，本仓库的修改与新增代码同样以 AGPL-3.0 发布，见 [LICENSE](LICENSE)。nodejs-mobile 为 MIT 许可。

本项目不存储、不提供任何视频内容，内容的合法性由使用者添加的数据源负责。
