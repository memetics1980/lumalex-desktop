LumaLex Desktop 0.1.0 build 98 — macOS

本版包含 AI 代理连接与模型参数兼容修复。

安装：将 LumaLex.app 拖到“应用程序”，从那里运行。
需要 macOS 12+。Universal 包包含 Apple Silicon 与 Intel 架构；
目前 Apple Silicon 已测试，Intel 尚未实机验证。

此包采用临时签名，尚无 Developer ID 签名与 Apple 公证。
如无法验证开发者，请核对来源并参考 Apple 说明：
https://support.apple.com/zh-cn/102445
不要关闭系统整体安全保护。

取词：设置中开启屏幕取词，默认快捷键 ⌘⌥L，也可自定义 ⌘/⌥/⇧ 组合。
在系统设置 → 隐私与安全性 → 辅助功能中添加当前 LumaLex.app，
启用后用 ⌘Q 退出并重开。更新后可能需要移除旧条目并重新授权。
AI 需要单独配置 API、模型与密钥，只有取得语境后才提供 AI 按钮。
代理：在“设置 → AI 语境释义 → AI 网络连接方式”选择跟随系统代理，
或手动填写 HTTP／混合端口，例如 http://127.0.0.1:7890（以代理软件为准）。
PAC／仅 SOCKS 配置请改用 HTTP／混合端口；测试成功后点击“保存配置”。
自行导入合法 MDX/MDD 词典；此包不附带词典或 API Key。

Includes AI proxy and model parameter compatibility fixes.

Install: Drag LumaLex.app into Applications and launch it there.
Requires macOS 12+. Universal: Apple Silicon tested; Intel not hardware-tested.
Ad-hoc signed preview, without Developer ID signing or Apple notarization.
If blocked, verify the source and consult https://support.apple.com/en-us/102445
Enable screen lookup in Settings (default ⌘⌥L), add the installed app to
Accessibility in System Settings, then quit with ⌘Q and reopen.
Changed ad-hoc builds may need fresh authorization after an update.
Contextual AI requires your API settings and available source context.
In AI settings, use System proxy or enter the actual HTTP/mixed proxy port,
e.g. http://127.0.0.1:7890. PAC/SOCKS-only configurations need an HTTP/mixed
port instead. Test the connection, then save the configuration.
Bring your own legitimately obtained dictionaries. No dictionaries or keys included.

指南 / Guides:
https://github.com/memetics1980/lumalex-desktop/blob/main/docs/MACOS_GUIDE.zh-CN.md
https://github.com/memetics1980/lumalex-desktop/blob/main/docs/MACOS_GUIDE.en.md
