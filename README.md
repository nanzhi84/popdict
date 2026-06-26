<div align="center">

# 🌐 popdict

### 划词即译 · 截图即解 · 原生丝滑的 macOS 桌面 AI 助手

选中文字,旁边立刻冒出「翻译 / 解释」;框选屏幕一块,让 AI 看着图讲给你听。<br>
自带 Key **直连你选的模型 API**,popdict 自己不设服务器、不中转、不收集。

![macOS](https://img.shields.io/badge/macOS-12%2B-000000?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-F05138?style=flat-square&logo=swift&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-3DA639?style=flat-square)
![价格](https://img.shields.io/badge/价格-免费-success?style=flat-square)
![模型](https://img.shields.io/badge/模型-任意%20OpenAI%20兼容-412991?style=flat-square&logo=openai&logoColor=white)

<img src="images/explain.png" width="540" alt="popdict 解释结果:流式 + 完整 Markdown(含表格、代码块)">

</div>

## ✨ 特性

- 🖱️ **选中即出结果** —— 不用复制、不用切窗口,翻译/解释贴在选区旁。
- 📸 **截图让 AI 看图讲解** —— 报错截图、图表、外文界面、文档,框一下就讲。
- ⚡ **流式 + 富文本** —— 逐字输出,完整 Markdown(标题 / 列表 / **表格** / 代码块 / 引用),还能带上下文追问。
- 🎛️ **模型自己挑** —— 内置 DeepSeek、小米 MiMo,可加任意 **OpenAI 兼容**厂商,下拉一键切换。
- 🪟 **原生丝滑** —— 毛玻璃浮窗,可拖拽缩放并记住大小;纯 AppKit,无 Electron、无后台全家桶。

## 🚀 上手

1. **装**:[Releases](../../releases) 下载 `popdict.dmg` → 拖进「应用程序」→ 首次**右键 → 打开**。或自己编译:`cd popdict-app && bash build.sh`。
2. **配 Key**:菜单栏 🌐 →「设置…」→ 选厂商([MiMo](https://platform.xiaomimimo.com/) 支持看图 / [DeepSeek](https://platform.deepseek.com/))→ 填 API Key → 保存(立即生效)。
3. **授权**:系统设置 → 隐私与安全性 → 辅助功能,打开 popdict(划词监听必需)。

## 🧩 用法

| 操作 | 怎么做 |
|------|--------|
| **翻译** | 选中文字 → 「🌐 翻译」(含中文→英文,其它→简体中文) |
| **解释** | 选中代码/概念 → 「💡 解释」(流式 + Markdown) |
| **追问** | 解释浮窗底部输入框,回车继续问 |
| **截图解释** | `⌃⌥E` 框选屏幕 → AI 看图讲解(需「屏幕录制」权限,且当前厂商勾了「支持看图」) |

## ⚙️ 模型厂商

只要是 **OpenAI 兼容**(`/chat/completions`)的服务都能接。设置窗口下拉选厂商,可配 名字 / Base URL / Model / API Key / 是否支持看图,选一个为「当前使用」。配置存本机 `~/.config/popdict/config.json`。

<div align="center"><img src="images/settings.png" width="440" alt="popdict 设置窗口:下拉选择模型厂商"></div>

## 🔒 隐私

popdict 是个 **API 客户端,不是本地大模型** —— 模型在你选的厂商云端跑。你选中的文字、截到的图,**只在你触发时直接发给你自己配置的那家厂商官方接口**;API Key 只存本机,popdict 自身没有服务器,不中转、不收集、不上传任何数据。

## 📄 License

[MIT](./LICENSE) · 仓库还附了 [PopClip](https://pilotmoon.com/popclip/) 扩展和 [Hammerspoon](https://www.hammerspoon.org/) 脚本两种轻量实现(走 DeepSeek)。如果它帮到你,点个 ⭐ 就是最大的鼓励。
