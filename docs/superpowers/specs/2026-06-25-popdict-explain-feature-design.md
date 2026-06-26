# popdict「解释」功能设计

> 日期:2026-06-25
> 目标:在 popdict 原生 App 里,除翻译外新增「解释」——选中看不懂的概念/代码,调 DeepSeek 用大白话直接讲明白。UI 沿用 Mac 原生毛玻璃,动效丝滑(流式打字机)。

## 范围

- **只改原生 App**:`popdict-app/main.swift` 单文件。
- PopClip 扩展、Hammerspoon 脚本本次不动。

## 确定的设计决策

| 维度 | 选择 |
|------|------|
| 触发方式 | 浮窗里并排两个按钮「🌐 翻译」+「💡 解释」 |
| 解释风格 | 自适应:短概念几句点透;代码/复杂内容分点拆解 + 关键处举例 |
| 输出方式 | DeepSeek 流式(`stream: true`,SSE),打字机式逐字显示 |

## 复用的现有基建

`PopupController` 已有,全部复用,不重造:

- 毛玻璃面板 `makePanel`(`.menu` 材质 + behindWindow 实时模糊 + 圆角 + 细边框 + 系统阴影)。
- `present(content:rect:)`:首次淡入;已有面板则平滑改尺寸 + 内容 crossfade。
- `HoverButton`:无边框、hover/按下浮起高亮(系统菜单项交互语言)。
- `attributedMarkdown`:把简单 markdown(粗体/斜体/等宽代码/链接)渲染成富文本。
- `measuredTextHeight`:真实测量换行后文本高度。
- 滚动容器 + 「复制」按钮 + 分隔线(`showMessage` 里的布局)。
- 失焦关闭、clamp 到屏幕等交互全部不变。

## 改动点

### 1. 双按钮气泡(替换单按钮)

`showButton(at:text:)` 改为构建一个横向容器:

- 容器宽 ~150、高 32。
- 左:「🌐 翻译」`HoverButton`(action `onTranslateClicked`,逻辑不变)。
- 中:1px 竖分隔线(`separatorColor` 半透明)。
- 右:「💡 解释」`HoverButton`(action 新增 `onExplainClicked`)。
- `placedRect` 的宽度同步更新。

`pendingText` 仍保存选中文字,两个按钮共用。

### 2. 流式解释网络层

新增 `explainStream`:

```
func explainStream(_ text: String,
                   onDelta: @escaping (String) -> Void,
                   onDone: @escaping (String) -> Void,
                   onError: @escaping (String) -> Void)
```

- 复用 `readAPIKey()`;无 key 时走 `onError`。
- 请求体:`model: deepseek-chat`、`stream: true`、`temperature: 0.5`、system + user 两条消息。
- 用 `URLSession.shared.bytes(for:)`(macOS 12+ 原生异步,正好等于本项目 `MIN_OS=12.0`)在 `Task` 里 `for try await line in bytes.lines` 逐行读。
- SSE 解析:只处理以 `data: ` 开头的行;`data: [DONE]` 表示结束;其余 JSON 解出 `choices[0].delta.content` 累加,并通过 `onDelta` 在主线程回吐增量。
- HTTP 非 200 / 网络异常 / 解析异常 → `onError`(中文提示,与翻译错误风格一致)。
- 全文累计后在结束时 `onDone(fullText)`。

### 3. 流式浮窗显示(新增三方法)

`showMessage` 每次重建整个面板,太重,不适合逐 token 刷新。新增轻量流式三方法:

- `beginStreaming(at origin:)`:建一次结果面板(空 NSTextView + NSScrollView),显示「解释中…」占位或直接等首字;复制按钮先不出现。
- `streamAppend(_ delta:)`:把增量追加到 `textStorage`(**流式途中用纯文本**,避免半截 markdown 渲染错乱);自动滚到底;**节流地**平滑长高——按内容真实高度算目标高度,超过阈值才动画(短动画 ~0.08s,合并高频更新,约 ≤20fps),到 `maxContentH` 后转为内部滚动。
- `finishStreaming(fullText:)`:把全文用 `attributedMarkdown` 重渲染换上(字体与流式一致,几乎无跳变);加分隔线 + 「复制」按钮(复用现有 footer 布局);最终高度收尾。
- 错误走现有 `showMessage(_, isError: true)`。

### 4. 解释 Prompt(简体中文、自适应)

system 提示(要点):

- 用**简体中文**把用户给的内容讲清楚,目的是让他真正理解。
- 代码:说明整体在做什么 → 逐步拆解关键逻辑 → 点出涉及的语法/库/设计意图 → 必要时一句类比或小例子。
- 术语/概念:大白话讲清"是什么、为什么重要、怎么用"。
- 内容短就短答(几句点透),内容复杂就分点详解。
- 直接开讲,不寒暄、不复述原文;可用简单 markdown(`**加粗**`、`` `代码` ``、`- 列表`)。

user 内容为选中的原文。

## 不做(YAGNI)

- 不加模型切换 UI、不接 deepseek-reasoner(deepseek-chat 够用且快)。
- 不做历史记录 / 多轮追问。
- 不动 PopClip / Hammerspoon。
- 不改取词、事件 tap、权限、菜单栏等任何现有逻辑。

## 验证

- 用 `popdict-app/build.sh` 的 `swiftc`(arm64 + x86_64)编译,确保通过、无警告退化。
- 手动冒烟:选中一段代码/概念 → 点「💡 解释」→ 看流式逐字 + 平滑长高 + 结束 markdown + 可复制。

## 风险

- 流式逐字刷新 + 频繁 panel resize 可能卡顿 → 用节流(高度阈值 + 帧率上限)化解。
- 半截 markdown → 流式纯文本、结束再渲染。
- `bytes(for:)` 需 macOS 12+ → 与 `MIN_OS` 一致,满足。

---

## 实现记录(as-built,2026-06-25)

最终交付比原始设计多做了两块,并经一轮多代理对抗审查 + 自测加固。

### 相对原设计的增量

1. **块级 Markdown 渲染器**(新文件 `popdict-app/Markdown.swift`,`enum MD`)
   原设计只用 Apple 的 inline markdown(`.inlineOnlyPreservingWhitespace`),只渲染粗斜体/行内代码,**块级语法(`##` 标题、`-`/`1.` 列表、```` ``` ```` 代码块、`---` 分隔线、`>` 引用)原样显示**。重写为:自己按行切块 + 块内复用 Apple inline。支持标题分级字号、列表悬挂缩进、代码块等宽浅底、HR 满宽细线(自绘 `NSTextAttachmentCell`)、任务列表 `☐/☑`、ATX 闭合 `#` 清理。`build.sh` 改为编译两文件。
2. **追问(会话浮窗)**
   解释从"单结果浮窗"升级为"会话 transcript + 底部常驻输入框(回车发送)"。`chatStream` 通用化(传完整 messages 数组),解释 = 第一轮,追问 = 后续轮,带完整上下文;聊天式累积、可滚动;流式途中纯文本、整轮结束按 markdown 重渲染。浮窗宽 460、内边距 18。

### 多代理对抗审查修复(20 条确认问题)

焦点抢占(收尾不再 `makeKeyAndOrderFront` 抢键盘)、首轮失败丢原文上下文、`present` 切换时 container 被 autoresize 放大、贴屏底长高逐帧上爬(改固定顶边锚点)、`⌘C/V/X/A` 失效(补最小 `mainMenu`)、中文输入法点候选词误关窗(`hasMarkedText` 时不关)、翻译关窗后幽灵弹窗(`generation` 令牌)、快速连续划词剪贴板竞态(取词串行化)、多屏副屏高度、`as!` 强转崩溃、追问失败整轮回滚等。

### 自测又抓出并修复的回归 ⚠️

把 `startConvoTimer()` 移进 `present` 的 `completionHandler` 后,**accessory + nonactivating 浮窗下该回调不可靠地不触发** → 流式期间面板不长高(憋到结束才弹大,与"丝滑"相反)。改为:定时器立即启动;原 autoresize 放大问题改用"会话切换 `animateFrame:false` 直接定尺寸"解决(翻译仍保留平滑形变)。

### 验证手段(POPDICT_UITEST 自测入口)

`main.swift` 留一个环境变量门控的自测入口(正常使用不触发):驱动真实 App 跑解释 + 程序化追问,把面板渲染成 PNG、把长高高度记入日志。实测:长高轨迹 `141→162→243→…→524` 单调小步无抖动;追问后 `convo` 为 users=2/assistants=2(上下文延续)。

### 代码块渲染修复(用户实测反馈后)

用户实测发现代码块灰底**碎成一行行、宽度不齐、行间有缝**。根因:每行 `\n` 被当段落分隔 → 段落间距叠加成缝;`.backgroundColor` 只画在字形后方 → 参差。修复:
- 代码块内部 `\n` 换成行分隔符 `U+2028`,使整块为同一段落(行间只走 lineSpacing,无段落间距缝隙);
- 新增 `CodeBlockLayoutManager`(`NSLayoutManager` 子类),对带 `MD.codeBlockKey` 标记的整段在背景层画**一块满宽圆角底**;transcript 与翻译结果的 `NSTextView` 都改用它构建。

### 已知小项(可按需再调)

- 多行列表项的手动续行缩进未并入上一项(优雅降级,不影响阅读)。
- 选中代码块文字 ⌘C 复制会得到 `U+2028` 而非 `\n`(用底部「复制」按钮则为干净原文)。
