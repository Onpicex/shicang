# 拾藏

Mac 上的文章收藏夹：复制一个链接按 ⌥⌘S，拾藏把原文、图片完整存到本地，再让 AI 自动分类、打标签、写摘要。手机上看到好文章，用快捷指令「存到拾藏」一点就行，Mac 会接着处理。

原生 SwiftUI App，数据是普通文件，放在你自己的 iCloud 云盘里。

## 能做什么

- **收藏**：X（推文、长文、串推）、微信公众号、一般网页。复制链接按 ⌥⌘S，或点菜单栏、拖进窗口。
- **剪藏**：复制的不是链接、是一段文字或带格式的网页片段，也能存。弹出确认小窗，标题可改；从浏览器复制的保留标题、粗体、列表、引用和图片。
- **摘录**：链接加一大段你复制的文字（≥ 100 字），文字记成「我的摘录」，显示在正文上方。
- **完整保存**：正文转成结构化的块（段落、标题、列表、引用、代码、图片），图片下载到本地；视频只存链接。
- **代码排版修复**：有些公众号排版工具把代码块排成引用框，还把引号、`--` 换成弯引号和破折号。拾藏能认回来，存成真正的代码块（等宽、保留缩进、标语言、可一键复制）。
- **AI 分类**：按你的分类体系自动归类，同时打标签、写一句摘要。你手动改过的分类会作为纠错样例，后面的文章参考它。
- **阅读与搜索**：内置阅读视图、全文搜索、按分类/标签筛选、已读标记。
- **手机收藏**：iPhone 快捷指令把链接写进 iCloud 文件夹，Mac 上的拾藏自动收走处理。手机离线也能存。

## 隐私与网络

- **剪贴板只在你要收藏时才读。** 按快捷键、点「从剪贴板收藏」时才读内容；切到拾藏窗口时只看「剪贴板有没有变、像不像链接」（决定要不要显示收藏横幅），不读内容；其他时间什么都不读，没有后台轮询。日志只记类型和长度，不记内容。
- **只走 https，没有例外。** App 不开任何 ATS 例外，代码里每个请求再过一道检查，本机 localhost 也不放行。复制的 http 链接改用 https 去抓；隐藏浏览器里页面的 http/ws 子资源全部拦掉。
- **不登录任何网站。** X 只用 fxtwitter 公共接口，受保护的推文拿不到；公众号、网页都按未登录状态抓取。
- **AI 密钥只存在本机文件** `~/Library/Application Support/拾藏/secrets.json`（权限 600），不进 iCloud、不进日志、不进导出。平台返回的报错里万一带了密钥，显示和写日志前会替换掉。
- **同时只用一个 AI 平台。** 平台连不上就排队等着重试，不会自动换到别的平台，文章内容只会发给你选的那一家。

## 系统要求

- macOS 26 或更新，Apple Silicon（`scripts/build.sh` 按 arm64 构建）
- Xcode 26（Swift 6）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- 手机收藏需要 Mac 和 iPhone 登录同一个 Apple ID，并打开 iCloud 云盘

## 构建与安装

```sh
git clone https://github.com/Onpicex/shicang.git
cd shicang
scripts/build.sh --open
```

脚本会生成 Xcode 工程、Release 构建、签名，装到 `~/Applications/拾藏.app` 并打开（会先退出正在运行的旧版）。

签名：钥匙串里有名为 `Shicang Local Signing` 的代码签名证书就用它（可用环境变量 `SHICANG_SIGN_ID` 换名字），没有就用 ad-hoc 签名，本机自用一样能跑。自签证书的好处是每次重新构建签名身份不变。

## 设置 AI 平台

设置 → AI 分类 → AI 平台：选平台，地址和推荐模型自动填好；填密钥，点「测试」真发一次分类请求验证，点「保存」生效。

预设了 Anthropic（默认）、CRS 中继（自建）、OpenAI、Google Gemini、DeepSeek、Kimi、通义千问、智谱 GLM、豆包、OpenRouter、硅基流动，以及「其他（OpenAI 兼容）」。

- 模型可以改，也可以「拉取模型列表」后从下拉里选。主模型不可用时依次试同一平台的备用模型。
- 地址填法宽松：只填域名、填到 `/v1`、填完整端点都行。只填域名时自动补 `https://`。
- **CRS 中继** 指自己部署的 [Claude Relay Service](https://github.com/Wei-Shaw/claude-relay-service)，没有默认地址，填到 `/api`，如 `https://relay.example.com/api`。
- 本机模型（Ollama、LM Studio 等）要先给它配上 https，再用「其他」填地址。
- OpenAI 兼容平台按 JSON Schema → JSON 模式 → 只靠提示词逐级降级，探到哪级能用就记住；结果都再过一遍本地校验。

没设置 AI 也能收藏，文章先放在「未分类」，设置好以后会自动补上。

## iPhone 快捷指令

见 [docs/快捷指令.md](docs/快捷指令.md)：在 Mac 上用 `scripts/make_shortcut.py` 生成、`shortcuts sign` 签名，隔空投送到 iPhone 导入。

## 数据放在哪

| 位置 | 内容 |
|------|------|
| `iCloud 云盘/拾藏/Library/<id>/` | 每篇一个文件夹：`article.json`（结构化正文和元数据）、`article.md`（Markdown 版，任何编辑器都能打开）、`images/`、原始网页快照（`source.html.gz`，解析规则升级后可在本机重新解析） |
| `iCloud 云盘/拾藏/Config/` | 分类体系、标签别名等 |
| `iCloud 云盘/拾藏/Inbox/`、`iCloud 云盘/快捷指令/拾藏Inbox/` | 待处理的收藏（处理完删除） |
| `~/Library/Application Support/拾藏/` | 本机缓存、索引、日志、`secrets.json`（不同步） |

## 命令行

`Core` 是一个 Swift Package，App 和命令行工具共用。命令行主要用来调试和回归，最好配隔离的测试目录：

```sh
cd Core
swift run shicang extract https://example.com/some-article          # 只抓取，Markdown 打到标准输出
swift run shicang run --root /tmp/shicang-test <链接>...              # 完整流程，写进测试目录
swift run shicang classify --root /tmp/shicang-test                 # AI 分类
swift run shicang search --root /tmp/shicang-test 关键词
swift run shicang ai-test --provider deepseek --key-env DEEPSEEK_API_KEY   # 测试 AI 平台（密钥只从环境变量读）
```

全部子命令见 `Core/Sources/shicang/main.swift` 顶部注释。

## 开发

```sh
cd Core && swift test        # 单元测试
```

| 目录 | 内容 |
|------|------|
| `Core/Sources/ShicangCore/` | 抓取（X / 公众号 / 网页 + 兜底通道）、HTML → 块、代码识别、文件库读写、队列、AI 分类、搜索、阅读视图 HTML |
| `Core/Sources/shicang/` | 命令行工具 |
| `Core/Tests/` | 单元测试 |
| `App/` | SwiftUI App（`project.yml` 由 XcodeGen 生成工程） |
| `scripts/` | 构建安装、图标生成、快捷指令生成 |

App 里的调试指令（`shicang://debug/...`）只在设置了环境变量 `SHICANG_TEST_ROOT`（隔离测试目录）时生效，正常使用时一律忽略。

## 目前的限制

- 只有 Mac 版，iOS 版还没做（手机先用快捷指令）。
- 不支持小红书。
- 视频只存链接，不下载。
- 只认 https 的网站；只有 http 的网站收藏会失败，失败列表里会说明原因。
- 需要登录才能看的内容（受保护的推文、付费文章）拿不到。

## 许可

[MIT](LICENSE)。第三方组件见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
