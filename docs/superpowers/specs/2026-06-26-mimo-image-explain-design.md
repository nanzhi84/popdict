# popdict:接入小米 MiMo + 截图解释图片

> 日期:2026-06-26
> 目标:在 popdict 原生 App 上做两件事——(1)把模型后端从 DeepSeek 换成小米 MiMo(OpenAI 兼容协议),(2)新增「截图解释图片」:popdict 自带框选截图,把截到的图发给 MiMo(`mimo-v2.5` 多模态)用简体中文讲清楚,并能带图追问。
>
> 这两件事是一条线:换成 MiMo 后,`mimo-v2.5` 一个模型既能翻译/解释文字、又能看图,正好支撑截图解释。

## 范围

- **只改原生 App**:`popdict-app/`(`main.swift`、新增 `Screenshot.swift`、`build.sh`),外加 `README.md`。
- **不动** PopClip 扩展(`DeepSeek-Translate.popclipext/`)和 Hammerspoon 脚本(`popdict.lua`)。

## 已确认的设计决策

| 维度 | 选择 |
|------|------|
| 模型策略 | **全部改用 MiMo**(`mimo-v2.5`,一个 key、一个模型管文字+图片);DeepSeek 退场 |
| 图片触发 | **popdict 自带框选截图 + 解释**(不依赖 Snipaste;右键塞进别家 App 菜单技术上做不到) |
| 截图触发入口 | 全局快捷键(默认 **⌃⌥E**)+ 菜单栏「📷 截图解释」两个入口 |
| Key 文件 | `~/.config/popdict/mimo_key`(不读旧 `deepseek_key` 兜底——那是另一家的 key,发给 MiMo 必失败) |
| 图片在浮窗的呈现 | 浮窗顶部放一张**缩略图**(而非纯文字占位) |
| 思考开关 | 请求体带 `"thinking": {"type": "disabled"}`(翻译/解释要快和省,不要推理 token) |

## MiMo 接入事实(已核实)

- Endpoint:`https://api.xiaomimimo.com/v1/chat/completions`(OpenAI 兼容)。
- 看图模型:`mimo-v2.5`(注意 `mimo-v2.5-pro` 是纯文本,不能看图)。
- 图片输入:`content` 用内容块数组,图块为 `{"type": "image_url", "image_url": {"url": "data:image/png;base64,<BASE64>"}}`;**确认支持 base64 data URL**,单图上限 50MB。
- `thinking: {"type": "disabled"}`:OpenAI SDK 里放 `extra_body`;我们直接拼 JSON body,等价于把 `"thinking": {"type":"disabled"}` 放在 body 顶层。
- `max_completion_tokens`:控制单次输出上限(官方示例字段名,非 `max_tokens`)。
- 流式:OpenAI 兼容,`stream: true` 走 SSE,`choices[0].delta.content` 增量——与现有 DeepSeek 解析逻辑一致。**此项为风险点,实现时实测确认**(见「风险」)。

---

## 设计

系统拆成 6 个相对独立的单元,各自职责清晰、可单独理解:

### A. 模型后端(集中常量 + 请求构造)

把现在散在 `translate` / `chatStream` 里的 DeepSeek 硬编码收成集中常量:

```
let kAPIBase = "https://api.xiaomimimo.com/v1"
let kChatPath = "/chat/completions"        // 完整地址 = kAPIBase + kChatPath
let kModel    = "mimo-v2.5"
let kMaxTokens = 4096
let kKeyPath  = kConfigDir + "/mimo_key"   // 原 deepseek_key 改名
```

- `readAPIKey()` 改读 `mimo_key`;**不做 deepseek_key 兜底**。
- 请求体新增:`"thinking": {"type": "disabled"}`、`"max_completion_tokens": kMaxTokens`;保留 `temperature`、`stream`。
- `translate`(非流式)、`chatStream`(流式 SSE)都改用 `kAPIBase + kChatPath` 与 `kModel`;SSE 解析不变。
- 错误文案:"DeepSeek 出错(HTTP …)" → "MiMo 出错(HTTP …)";无 key 提示指向新路径 `mimo_key`。
- 菜单栏「⚠️ 未填 API Key / ✓ 已配置 API Key」沿用,只是检查的是新文件。

> 接口:输入选中文字 / 完整 messages 数组,输出译文 / 流式增量。换后端对调用方(`PopupController`)透明。

### B. 多模态消息(让一条消息能带图)

现状:`chatStream(_ messages: [[String: String]], …)` 只能纯文本。

改动:把消息内容从「只能是字符串」放宽到「字符串 **或** 内容块数组」。最小侵入做法——把签名改成 `[[String: Any]]`,其中:

- 文字消息:`["role": "user", "content": "原文"]`(同今天)。
- 带图消息:`["role": "user", "content": [["type":"text","text":"请解释这张图片的内容。"], ["type":"image_url","image_url":["url": dataURL]]]]`。

`PopupController` 内的会话上下文 `convo` 仍以文本为主,额外保存一个:

```
private var attachedImageDataURL: String?   // 本轮会话附带的图(base64 data URL),整段会话期间保留
```

`sendTurn()` 构造 `messages` 时:首条 user 若 `attachedImageDataURL != nil`,则把它的 content 拼成「text 块 + image_url 块」;其余轮次为纯文本。**每轮都重发这张图**,确保追问时模型仍记得图。

> 接口:`chatStream` 仍是「给完整 messages,回吐增量/完成/错误」,只是 content 类型放宽。文字链路行为不变。

### C. 框选截图遮罩(新文件 `popdict-app/Screenshot.swift`)

一个独立组件 `RegionCapture`,入口:

```
func capture(completion: @escaping (NSImage?) -> Void)
```

- **遮罩窗口**:一个铺满「所有屏幕并集矩形」的无边框透明 `NSWindow`,层级 `.screenSaver`(盖住一切),`ignoresMouseEvents = false`,十字光标。用单窗口跨多屏,绘制与坐标统一在一个空间里。
- **自定义 `SelectionView`**:
  - 画压暗层(黑 ~0.35 alpha),选区矩形内部挖空(clear)。
  - `mouseDown` 记起点,`mouseDragged` 实时更新选区并重绘,选区旁显示「宽×高」像素尺寸。
  - `mouseUp`:选区面积够大(> ~8×8)则确认,否则当作取消。
  - `keyDown` 收到 `Esc`(keyCode 53)→ 取消 `completion(nil)`。
- **捕获**:确认后取选区的全局屏幕坐标矩形,调
  `CGWindowListCreateImage(rect, .optionOnScreenBelowWindow, CGWindowID(window.windowNumber), [.bestResolution, .boundsIgnoreFraming])`
  ——只截遮罩窗口**下方**的真实画面,压暗层不会进图,也无需先隐藏窗口再等一帧。拿到 `CGImage` 后转 `NSImage`,再 `orderOut` 关遮罩。
  - 取不到(返回 nil)兜底:`CGDisplayCreateImage(displayID, rect:)`。
  - 坐标换算:`CGWindowListCreateImage` 用的是 Quartz 左上原点全局坐标;`NSEvent`/`NSWindow` 用 AppKit 左下原点。换算时以「所有屏幕并集」高度翻转。这套翻转逻辑集中在一个 helper 里,避免散落出错。
- **编码**:`NSImage` → `CGImage` → 若最长边 > 2048px 等比缩小 → `NSBitmapImageRep` PNG → base64 → `"data:image/png;base64," + b64`。提供 `func encodeToDataURL(_ image: NSImage) -> String?`。

> 这组 `CGWindowListCreateImage` / `CGDisplayCreateImage` 在 macOS 14 起标记弃用但仍可用;ScreenCaptureKit 的 `SCScreenshotManager` 要 macOS 14+,而本项目 `MIN_OS=12.0`,故现阶段用前者。后续若要去弃用,再迁 ScreenCaptureKit 并抬最低版本。

### D. 屏幕录制权限

截图需要「屏幕录制」权限(TCC,与现有「辅助功能」彼此独立)。

- 检查:`CGPreflightScreenCaptureAccess()`(macOS 10.15+,返回 Bool)。
- 申请:`CGRequestScreenCaptureAccess()`(首次弹系统授权;返回是否已授予)。
- 触发截图前:若未授权 → 调一次申请,并弹普通提示浮窗/对话说明「请在 系统设置 → 隐私与安全性 → 屏幕录制 打开 popdict,**首次授予后通常需要重开 App 才生效**」,同时打开设置页 `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`。
- 菜单栏增加状态项:「✓ 屏幕录制:已授权 / ⚠️ 屏幕录制:未授权(截图解释需要)」+「屏幕录制权限设置…」入口;沿用现有 `refreshMenu` 机制刷新。

### E. 触发与图片会话入口

- **全局快捷键**:用 Carbon `RegisterEventHotKey` 注册默认 **⌃⌥E**(Control+Option+E)。理由:系统级、稳定、能消费按键、不需额外权限;避开 Snipaste 的 fn+f1/f2 和 macOS 截图 ⌘⇧3/4/5。需 `import Carbon` 并在 build.sh 链接 `-framework Carbon`。热键回调里发起 `RegionCapture.capture`。
- **菜单栏入口**:状态菜单加「📷 截图解释 (⌃⌥E)」,action 与热键同一入口。
- **图片会话**:`PopupController` 新增 `beginImageConversation(image: NSImage, instruction: String = "请解释这张图片的内容。")`:
  - 把 `image` 编码成 data URL 存进 `attachedImageDataURL`;`convo = [(role:"user", content: instruction)]`。
  - 复用现有会话浮窗(transcript 滚动区 + 底部追问输入栏)。
  - transcript 顶部插入一张**缩略图**(`NSTextAttachment` 承载缩放后的图,宽度贴合浮窗内宽)+ 指令文字气泡,然后 `sendTurn()` 流式出解释。
  - 浮窗定位:无文字选区坐标,放到截图选区右侧(取不到则屏幕中上方),复用 `clampToScreen` / `beginConversation` 的定位思路。
  - 追问、回滚、失焦关闭等行为与文字解释完全一致(图始终在 `attachedImageDataURL` 里,每轮重发)。

### F. 看图的提示词

扩展现有解释 system prompt(`kExplainSystem`),补一段图片分支:

> 如果用户给的是图片:先一句说清这张图整体是什么(截图 / 图表 / 报错 / 界面 / 照片 / 文档…),再解读其中关键信息。报错或代码截图 → 定位问题并给排查/解决方向;图表 → 读出趋势与要点;界面/流程 → 说清它在干什么。其余规则(简体中文、简则简答繁则分点、可用 markdown、不复述)不变。

---

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `popdict-app/main.swift` | A 后端常量与请求;B 多模态 messages;D 权限检查 + 菜单项;E 热键注册 + 菜单入口 + `beginImageConversation` + 缩略图;F prompt |
| `popdict-app/Screenshot.swift`(新) | C `RegionCapture` + `SelectionView` + 捕获 + 编码 |
| `popdict-app/build.sh` | SRCS 加 `Screenshot.swift`;链接 `-framework Carbon`;dmg 安装说明改 MiMo key 路径 + 新功能/权限 |
| `README.md` | DeepSeek → MiMo;key 路径 `mimo_key`;新增「截图解释」用法、⌃⌥E、屏幕录制权限 |
| `docs/superpowers/specs/2026-06-26-mimo-image-explain-design.md`(本文件) | 设计与实现记录 |

## 验证

- **编译**:`popdict-app/build.sh` 的 `swiftc`(arm64 + x86_64 universal),通过且无警告退化(弃用 API 警告除外,会单独说明)。
- **手动冒烟**(需在 `~/.config/popdict/mimo_key` 填入有效 MiMo key):
  1. 选中中文 → 「🌐 翻译」→ 出英文;选中英文 → 出中文。(MiMo 文字链路)
  2. 选中一段代码/概念 → 「💡 解释」→ 流式逐字 + markdown + 可追问。(MiMo 流式)
  3. 按 **⌃⌥E**(或菜单「📷 截图解释」)→ 框选一块屏幕 → 浮窗出缩略图 + 流式图解 → 追问一句仍能结合该图回答。
  4. 框选时按 `Esc` → 干净取消,无浮窗。
  5. 关掉屏幕录制权限 → 触发截图 → 出引导提示并打开设置页。
- **自测入口**:沿用 `POPDICT_UITEST` 思路,新增一条用**内置/本地测试图**驱动 `beginImageConversation` 的路径(免得 headless 下还要真截图、真屏幕录制权限),验证多模态 messages 构造 + 缩略图渲染 + 上下文保留。

## 风险

- **MiMo 流式**:`stream:true` 按 OpenAI 兼容假定;实现后用真实 key 实测确认 SSE 字段一致(非流式 `translate` 风险更低,可先验它)。若不兼容,退化为非流式一次性返回。
- **`thinking:{type:disabled}`**:你给的官方示例里就这么用,应被接受;若 MiMo 报未知字段错,去掉该字段即可。
- **截图 API 弃用警告**:`CGWindowListCreateImage`/`CGDisplayCreateImage` 在 14+ 弃用但仍可用;编译会有 deprecation 警告(不视为退化)。真不可用再迁 ScreenCaptureKit / 抬 `MIN_OS`。
- **屏幕录制权限首授需重开 App**:macOS 已知行为,靠文案讲清,必要时引导用户重启 App。
- **大图 base64**:retina 全屏级截图编码后体积大、增 token 与延迟;用「最长边 ≤ 2048px 缩放」缓解。
- **多屏坐标翻转**:Quartz(左上原点)↔ AppKit(左下原点)易错;翻转集中到单一 helper 并在多屏下手测。
- **Carbon 热键冲突**:⌃⌥E 默认值若与用户其它工具冲突,需改键(本期不做自定义 UI,改常量即可)。

## 不做(YAGNI)

- 不做模型切换 UI(已定全改 MiMo)。
- 不做本地 OCR;图直接发 MiMo。
- 不做快捷键自定义界面(默认 ⌃⌥E,改键改常量)。
- 不碰 PopClip 扩展 / Hammerspoon 脚本。
- 不做多图 / 音频 / 视频输入(MiMo 支持但超范围)。
