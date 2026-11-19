# 第三方组件

拾藏本身以 MIT 许可发布（见 [LICENSE](LICENSE)）。下面这些第三方组件各自沿用原许可。

| 组件 | 用途 | 许可 | 来源 |
|------|------|------|------|
| Readability.js | 网页正文抽取（随代码分发：`Core/Sources/ShicangCore/Resources/Readability.js`，原样保留文件头版权声明） | Apache License 2.0，Copyright (c) 2010 Arc90 Inc 及 Mozilla 贡献者 | https://github.com/mozilla/readability |
| SwiftSoup | HTML 解析（Swift Package 依赖，构建时下载） | MIT，Copyright (c) Nabil Chatbi | https://github.com/scinfu/SwiftSoup |
| KeyboardShortcuts | 全局快捷键（Swift Package 依赖，构建时下载） | MIT，Copyright (c) Sindre Sorhus | https://github.com/sindresorhus/KeyboardShortcuts |

Apache License 2.0 全文：https://www.apache.org/licenses/LICENSE-2.0

运行时还会调用这些公开服务（不随代码分发）：fxtwitter 公共 API（读取公开推文）、你自己在设置里选的 AI 平台。
