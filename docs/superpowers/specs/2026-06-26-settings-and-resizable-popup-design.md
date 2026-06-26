# popdict:可缩放记忆浮窗 + 厂商设置 GUI

> 日期:2026-06-26
> 目标:在 popdict 原生 App 上做两件相对独立的事——
> (1)**浮窗可自由缩放并记住大小**:出结果的浮窗(翻译结果 / 解释追问 / 截图解释)能自由拖拽改尺寸,调好后记住,下次同样大小;
> (2)**厂商设置 GUI**:一个设置窗口,让用户自己管理一组 OpenAI 兼容厂商(增删、自定义名字 / Base URL / API Key / Model / 是否支持看图),选一个为「当前使用」;预置 DeepSeek、MiMo 两条。

## 范围

- 只改原生 App:`popdict-app/`(`main.swift`,新增 `Config.swift`、`Settings.swift`),外加 `README.md`。
- 不动 PopClip 扩展、Hammerspoon 脚本。
- 建立在已合入本分支的「MiMo 后端 + 截图解释」之上。

## 已确认的设计决策

| 维度 | 选择 |
|------|------|
| #1 缩放与记忆 | 自由缩放(`.resizable` + 右下角拖拽握把),**记住固定尺寸、内容框内滚动**(放弃原「随内容自动长高」);三种结果浮窗共用一个记忆尺寸 |
| #1 默认尺寸 | 首次无记忆时约 460×380;最小约 300×180 |
| #3 厂商模型 | **通用 OpenAI 兼容厂商列表**(增删、自定义名字/base_url/key/model/是否看图),选一个「当前使用」 |
| #3 预置 | `DeepSeek`(`api.deepseek.com/v1`,`deepseek-chat`,看图✗)、`MiMo`(`api.xiaomimimo.com/v1`,`mimo-v2.5`,看图✓) |
| #3 看图门禁 | 当前厂商未勾「支持看图」时,菜单「📷 截图解释」灰掉,⌃⌥E 弹提示去切厂商 |
| #3 持久化 | `~/.config/popdict/config.json`;首次自动迁移旧 `mimo_key` 进 MiMo 卡 |

---

## 设计

### 单元划分

| 单元 | 文件 | 职责 |
|------|------|------|
| 配置模型 | `Config.swift`(新) | Provider 结构 + AppConfig 单例:读写 config.json、预置、迁移、当前厂商 |
| 后端 | `main.swift` translate/chatStream/readAPIKey | 改读 AppConfig.shared.active 的 base_url/model/key |
| 设置窗口 | `Settings.swift`(新) | 厂商卡片增删编辑 + 保存 → AppConfig |
| 门禁/菜单 | `main.swift` AppDelegate | 看图门禁、菜单「设置…」、状态行 |
| 浮窗缩放 | `main.swift` PopupController | .resizable + 握把 + 记忆尺寸 + 去自动长高 |

---

### #3a 配置模型(`Config.swift`)

```swift
struct Provider: Codable {
    var name: String          // 用户自定义,显示用,唯一标识
    var baseURL: String       // 含 /v1,补全地址 = baseURL + "/chat/completions"
    var apiKey: String
    var model: String
    var vision: Bool          // 是否支持看图(任意 OpenAI 兼容厂商无法自动判定,人工勾)
}

final class AppConfig {
    static let shared = AppConfig()
    private(set) var providers: [Provider]
    private(set) var activeName: String

    var active: Provider? { providers.first { $0.name == activeName } ?? providers.first }

    // 启动时 load();无文件则建预置 + 迁移旧 mimo_key;save() 原子写回
    func load()
    func save()
    func setProviders(_ ps: [Provider], active: String)   // 设置窗口保存时调用
}
```

- 文件:`~/.config/popdict/config.json`,形如:
  ```json
  {
    "active": "MiMo",
    "providers": [
      {"name":"DeepSeek","baseURL":"https://api.deepseek.com/v1","apiKey":"","model":"deepseek-chat","vision":false},
      {"name":"MiMo","baseURL":"https://api.xiaomimimo.com/v1","apiKey":"<迁移>","model":"mimo-v2.5","vision":true}
    ]
  }
  ```
- **迁移**:`load()` 时若 config.json 不存在 → 用上面两条预置初始化;若旧 `~/.config/popdict/mimo_key` 文件存在,把内容填进 MiMo 卡的 `apiKey`;`active="MiMo"`;随即 `save()` 落盘(迁移一次)。`mimo_key` 文件保留不删(无害)。
- `active` 存名字;`active` 计算属性在找不到时回退第一条,保证永不为 nil(只要至少一条厂商;设置窗口禁止删到 0 条)。
- 用 Codable + JSONEncoder(`.prettyPrinted`)/JSONDecoder;读失败(损坏)时回退预置并日志告警,不崩。

### #3b 后端改读当前厂商(`main.swift`)

- 删去对 `kAPIBase`/`kModel`/`kKeyPath`(作为后端来源)的硬编码使用;`kKeyPath` 仅保留给迁移读取旧文件。
- 新增便捷读取:`func activeProvider() -> Provider?`(= `AppConfig.shared.active`);`readAPIKey()` → `active?.apiKey`(空算无)。
- `translate` 与 `chatStream`:
  - 无 active 或 key 空 → 错误提示「没配置 API Key,请点菜单栏 🌐 →『设置…』填入当前厂商的 Key」。
  - URL = `active.baseURL + "/chat/completions"`;`"model": active.model`;`thinking:{type:disabled}` 与 `max_completion_tokens` 保留(对 MiMo 有效;对不认识该字段的厂商,多数 OpenAI 兼容服务会忽略未知字段——**风险点见下**)。
  - 错误文案里「MiMo 出错」改为通用「\(active.name) 出错」。

### #3c 设置窗口(`Settings.swift`)

- `SettingsController`:持有一个标准 `NSWindow`(标题「popdict 设置」,可关闭,~520×460),`NSApp.activate` + `makeKeyAndOrderFront` 打开。
- 内容:顶部一句说明;中间 `NSScrollView` 里竖直堆叠**厂商卡片**;底部「+ 添加厂商」「保存」「关闭」。
- **厂商卡片**(自定义 `NSView`,圆角浅底):
  - 单选圆点「● 当前使用」(同一时刻全列只能一个选中;点某卡的圆点把它设为 active)。
  - 文本框:名字、Base URL、API Key(`NSSecureTextField`)、Model。
  - 复选框「支持看图」。
  - 「删除」按钮(列表只剩 1 条时禁用,保证不删空)。
- 顶部「+ 添加厂商」:追加一张空白卡(名字默认「新厂商」,baseURL 占位 `https://`,model 空,vision 关)。
- 「保存」:收集所有卡片 → 校验(名字非空且不重名;至少一条)→ `AppConfig.shared.setProviders(_:active:)` → `save()` → `refreshMenu()` → 关窗。校验失败弹 NSAlert 指出问题、不关窗。
- 「关闭」:不保存直接关。
- 打开窗口时从 `AppConfig.shared` 渲染当前卡片。

### #3d 看图门禁 + 菜单(`main.swift` AppDelegate)

- 新增菜单项「设置…」→ `openSettings()` 打开 `SettingsController`(AppDelegate 持有一个实例,避免重复创建/释放)。
- 「📷 截图解释」菜单项:`isEnabled = AppConfig.shared.active?.vision == true`(不支持时灰掉)。
- `onScreenshotExplain()` 开头加:若 `active?.vision != true` → 弹 NSAlert「当前厂商『\(name)』不支持看图,请在『设置…』里切换到一个勾了『支持看图』的厂商(如 MiMo)」并 return(在屏幕录制权限检查之前)。
- 菜单「API Key」状态行改为反映当前厂商:`✓ 当前:MiMo(已配置 Key)` / `⚠️ 当前:DeepSeek 未填 Key`。

### #1 浮窗可缩放 + 记忆大小(`main.swift` PopupController)

- **可缩放**:`makePanel` 的 styleMask 加 `.resizable`;设 `p.minSize`/`contentMinSize ≈ 300×180`;`p.delegate = self`(PopupController 实现 `NSWindowDelegate`)。
- **拖拽握把**:新增 `ResizeGripView`(右下角 ~16×16,自绘三道斜线)。`mouseDragged` 时按光标位置改窗口 frame——保持**左上角不动**,`新宽 = max(minW, 光标X - frame.minX)`、`新高 = max(minH, frame.maxY - 光标Y)`、`origin = (frame.minX, frame.maxY - 新高)`。仅给「结果/会话浮窗」加握把,按钮气泡不加。
- **记忆尺寸**:
  - `UserDefaults.standard` 存 `popupSize`(宽、高两个数)。
  - `windowDidEndLiveResize`(边缘缩放)与握把 `mouseUp`(回调 PopupController)→ `saveSize(panel.frame.size)`(仅在「内容浮窗」状态时存,按钮气泡不存)。
  - 打开内容浮窗时用 `savedSize() ?? 默认(460×380)`;clamp 到屏幕可见区。
- **去掉自动长高**:
  - 移除 `convoTimer`/`startConvoTimer`/`growConversation` 及其所有调用(`installConversationPanel`、`onAskSubmit`、`finishTurn`、`convoError`、`beginImageConversation`)。
  - 会话浮窗改为固定(记忆)尺寸;transcript 的 `NSScrollView`([.width,.height] autoresize)随窗口缩放重排,内容超出即内部滚动;流式时仍 `scrollTranscriptToBottom`(已有)。
  - `installConversationPanel(at:)` 直接用记忆尺寸建面板(不再 22pt 起步再长高)。
- **翻译结果浮窗**(`showMessage`,`showCopy=true` 的结果):同样用记忆尺寸 + 内部滚动 + 握把;瞬时态(「翻译中…」/错误)保持原小尺寸自适应(短暂,不参与记忆)。
- **panel 复用注意**:`present()` 跨状态复用同一 panel。需区分「内容浮窗」(可缩放、加握把、记忆)与「按钮气泡 / 瞬时态」(固定尺寸、无握把、不记忆)。用一个 `panelIsResizable` 标记当前态决定是否保存尺寸、是否显示握把。

---

## 改动文件清单

| 文件 | 改动 |
|------|------|
| `popdict-app/Config.swift`(新) | Provider + AppConfig:config.json 读写、预置、迁移、active |
| `popdict-app/Settings.swift`(新) | SettingsController + 厂商卡片 UI + 保存 |
| `popdict-app/main.swift` | 后端读 active;看图门禁;菜单「设置…」/状态;PopupController 缩放+握把+记忆+去自动长高 |
| `popdict-app/build.sh` | SRCS 加 Config.swift、Settings.swift |
| `README.md` | 配置改为「设置…」管理厂商;说明缩放记忆;截图解释看图门禁 |

## 验证

- universal(arm64+x86_64)`build.sh` 编译无警告退化。
- 离线/可脚本验证:`AppConfig` 的 config.json 读写 + 迁移逻辑(用临时目录跑独立小程序)。
- 手动冒烟:
  1. 首启自动迁移:旧有 `mimo_key` → 设置里 MiMo 卡已带 Key、默认当前;翻译/解释/截图解释照常。
  2. 设置窗口:改名、改 model、加一条新厂商、切「当前使用」、保存 → 翻译走新厂商。
  3. 把「当前使用」切到 DeepSeek(未勾看图)→ 菜单「截图解释」灰掉,⌃⌥E 弹提示。
  4. 浮窗:拖右下握把 / 拖边缘改尺寸 → 关掉重开,尺寸保持;长解释在框内滚动。
- 多代理对抗审查(并发/持久化竞态/窗口缩放与 autoresize/迁移边界/门禁时序/内存)。

## 风险

- **未知 `thinking` 字段**:非 MiMo 厂商(DeepSeek 等)可能不认 `thinking`。**决策:始终发 `thinking` 与 `max_completion_tokens`**——OpenAI 兼容服务对未知字段普遍忽略(DeepSeek 亦然),这是默认行为。仅当实测某厂商因此返回 400 时,才改成「只对勾了支持看图的 MiMo 系厂商附带 `thinking`」。本期按「始终发」实现并以实测验证。
- **borderless + resizable 边缘命中区窄**:故加显式握把作为主要交互;边缘拖拽作为补充。
- **窗口缩放与现有 autoresize**:容器/滚动区已是 [.width,.height],但需确认输入栏固定底部、握把固定右下角,缩放后不错位。
- **去自动长高的回归**:`growConversation` 牵连首轮定位、贴屏底锚点等逻辑;移除后要确认会话浮窗在记忆尺寸下首轮、追问、回滚、截图缩略图都正常。
- **config.json 损坏 / 迁移竞态**:读失败回退预置不崩;`save()` 原子写(写临时文件再 rename)。
- **设置改动即时生效**:后端每次调用读 `AppConfig.shared.active`,保存后下一次翻译/解释即用新值,无需重启。

## 不做(YAGNI)

- 不做非 OpenAI 兼容协议。
- 不做每种浮窗各自独立记忆尺寸(三种共用一个)。
- 不做厂商连通性测试按钮 / 模型列表拉取(填什么用什么)。
- 不碰 PopClip / Hammerspoon。
