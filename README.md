# popdict · 划词翻译

> 在 Mac 上**选中文字 → 旁边自动冒出「🌐 翻译」按钮 → 点一下出译文**。
> 免费、原生、不依赖任何第三方软件,翻译走 [DeepSeek](https://platform.deepseek.com/)。
> 方向自动判断:**含中文 → 译成英文;其它语言 → 译成简体中文**。

本仓库提供三种实现,推荐第一种(原生 App,开箱即用、自动冒泡、无需快捷键):

| 实现 | 说明 | 需要装额外软件? |
|------|------|------------------|
| **原生 App**(主推) | `popdict-app/` 下的 Swift 菜单栏程序,划词自动冒泡 | 不需要 |
| PopClip 扩展 | `DeepSeek-Translate.popclipext/`,装了 [PopClip](https://pilotmoon.com/popclip/) 的话最省事 | 需要 PopClip |
| Hammerspoon 脚本 | `popdict.lua`,快捷键触发(`⌘⇧T`) | 需要 [Hammerspoon](https://www.hammerspoon.org/) |

---

## 一、原生 App(推荐)

一个常驻菜单栏的小程序(图标 🌐),无 Dock 图标。划词即冒泡,点按钮出译文。

### 安装

**方式 A:下载现成的 dmg**(见本仓库 [Releases](../../releases))

1. 打开 dmg,把 `popdict.app` 拖进「应用程序」。
2. 在「应用程序」里**右键点 popdict → 打开 → 再点「打开」**(只需这一次,绕过"未知开发者"提示)。
3. 菜单栏出现 🌐 即启动成功。

**方式 B:自己编译**(只需 macOS 自带的命令行工具,无需完整 Xcode)

```sh
cd popdict-app
bash build.sh          # 生成 universal 的 popdict.app 和 popdict.dmg
```

> 想让"更新后不丢辅助功能授权",可先在「钥匙串访问」里建一个自签名的代码签名证书,
> 然后 `bash build.sh "你的证书名"` 用它签名(同一证书签名,TCC 授权不会因重编而失效)。

### 配置 API Key

去 [platform.deepseek.com](https://platform.deepseek.com/) 申请一个 Key,然后:

```sh
mkdir -p ~/.config/popdict
echo '你的-deepseek-key' > ~/.config/popdict/deepseek_key
chmod 600 ~/.config/popdict/deepseek_key
```

Key 只保存在本机这个文件里,**不会上传到任何地方**(只在翻译时直接发给 DeepSeek 官方接口)。

### 授权辅助功能

划词监听需要「辅助功能」权限:

- 点菜单栏 🌐 →「辅助功能权限设置…」,或手动打开
  **系统设置 → 隐私与安全性 → 辅助功能**,把 popdict 的开关打开。
- 打开开关后**无需重启**,程序会自动开始监听(内部每秒检测一次授权状态)。

### 使用

在任意 App 里选中一段文字 → 旁边冒出「🌐 翻译」→ 点它 → 原地显示译文(可选中复制,点别处关闭)。

### 排查

- 点菜单栏 🌐,看「辅助功能」「API Key」两项是否都已打勾。
- 日志在 `~/.config/popdict/popdict.log`,记录了启动、授权、取词的每一步。

---

## 二、PopClip 扩展

装了 PopClip 的话,直接双击 `DeepSeek-Translate.popclipext`(或打包后的 `.popclipextz`)安装,
在 PopClip 设置里填入 DeepSeek API Key 即可。选中文字后点 PopClip 工具条上的 🌐。

## 三、Hammerspoon 脚本

把 `popdict.lua` 用 `~/.hammerspoon/init.lua` 里一行 `dofile` 加载,
配好 `~/.config/popdict/deepseek_key`,选中文字按 `⌘⇧T` 弹出译文。详见脚本顶部注释。

---

## 工作原理

- **取词**:优先用 macOS 辅助功能(Accessibility)接口直接读选区文字;读不到时模拟一次
  `⌘C` 复制(用完自动还原你原来的剪贴板)。
- **冒泡**:用全局鼠标事件监听(CGEventTap)感知"划选"动作,在选区旁弹一个无边框浮窗。
- **翻译**:调用 DeepSeek 的 `chat/completions` 接口,按是否含中文决定译入语言。

## 隐私

- API Key 仅存于本地 `~/.config/popdict/deepseek_key`。
- 选中的文字只会发送给 DeepSeek 官方接口用于翻译,本程序不收集、不上传任何数据。

## License

[MIT](./LICENSE)
