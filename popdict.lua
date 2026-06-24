--- popdict —— DeepSeek 划词翻译(快捷键版)
--- 选中任意文字 → 按快捷键 → 复制 → 调 DeepSeek → 弹小窗显示译文
--- 母语中文:检测到中文译成英文,其它语言一律译成简体中文。

local M = {}

------------------------------------------------------------------
-- 可调配置
------------------------------------------------------------------
local HOTKEY_MODS = { "cmd", "shift" }
local HOTKEY_KEY  = "t"            -- 默认快捷键 ⌘⇧T
local KEY_PATH    = os.getenv("HOME") .. "/.config/popdict/deepseek_key"
local API_URL     = "https://api.deepseek.com/chat/completions"
local MODEL       = "deepseek-chat"
local COPY_WAIT   = 0.15           -- 模拟 ⌘C 后等待复制完成的秒数

------------------------------------------------------------------
-- 读取 API Key
------------------------------------------------------------------
local function readKey()
  local f = io.open(KEY_PATH, "r")
  if not f then return nil end
  local k = f:read("*a")
  f:close()
  if k then k = k:gsub("%s+", "") end
  if not k or k == "" then return nil end
  return k
end

------------------------------------------------------------------
-- 是否包含中文(粗判 CJK 汉字:UTF-8 首字节 0xE4–0xE9)
------------------------------------------------------------------
local function hasChinese(s)
  return s:find("[\228-\233]") ~= nil
end

------------------------------------------------------------------
-- 译文小窗(可复制,Esc / 点关闭按钮关闭)
------------------------------------------------------------------
local currentWindow = nil
local escTap = nil

local function closeWindow()
  if currentWindow then currentWindow:delete() ; currentWindow = nil end
  if escTap then escTap:stop() ; escTap = nil end
end

-- 简单 HTML 转义
local function esc(s)
  s = s or ""
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function showPopup(title, bodyText, isError)
  closeWindow()

  local color = isError and "#c0392b" or "#1a1a1a"
  local html = string.format([[
    <html><head><meta charset="utf-8"><style>
      * { box-sizing: border-box; }
      html,body { margin:0; padding:0; }
      body {
        font-family: -apple-system, "PingFang SC", sans-serif;
        background: #fbfbfb; color: %s;
        padding: 14px 16px; -webkit-user-select: text; user-select: text;
      }
      .tag { font-size: 11px; color:#999; margin-bottom:6px; letter-spacing:.5px; }
      .body { font-size: 15px; line-height: 1.55; white-space: pre-wrap; word-break: break-word; }
    </style></head><body>
      <div class="tag">%s</div>
      <div class="body">%s</div>
    </body></html>
  ]], color, esc(title), esc(bodyText))

  -- 在鼠标附近弹出
  local mouse = hs.mouse.absolutePosition()
  local screen = hs.mouse.getCurrentScreen():frame()
  local w, h = 420, 200
  local x = math.min(mouse.x + 12, screen.x + screen.w - w - 20)
  local y = math.min(mouse.y + 16, screen.y + screen.h - h - 20)

  currentWindow = hs.webview.new({ x = x, y = y, w = w, h = h })
    :windowStyle({ "titled", "closable", "utility", "nonactivating" })
    :level(hs.drawing.windowLevels.floating)
    :allowTextEntry(false)
    :deleteOnClose(true)
    :html(html)
    :show()

  -- Esc 关闭
  escTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if e:getKeyCode() == hs.keycodes.map["escape"] then closeWindow() ; return true end
    return false
  end)
  escTap:start()
end

------------------------------------------------------------------
-- 调 DeepSeek 翻译
------------------------------------------------------------------
local function translate(text, cb)
  local key = readKey()
  if not key then
    cb(nil, "没找到 API Key。请把你的 DeepSeek Key 填进:\n" .. KEY_PATH)
    return
  end

  local target = hasChinese(text) and "English" or "Simplified Chinese"
  local sys = "You are a professional translation engine. Translate the user's text into "
            .. target .. ". Output ONLY the translation itself — no explanations, no quotes, no extra words."

  local body = hs.json.encode({
    model = MODEL,
    messages = {
      { role = "system", content = sys },
      { role = "user",   content = text },
    },
    temperature = 0.3,
    stream = false,
  })

  local headers = {
    ["Content-Type"]  = "application/json",
    ["Authorization"] = "Bearer " .. key,
  }

  hs.http.asyncPost(API_URL, body, headers, function(status, respBody, _)
    if status ~= 200 then
      cb(nil, "DeepSeek 请求失败(HTTP " .. tostring(status) .. ")\n" .. tostring(respBody):sub(1, 300))
      return
    end
    local ok, parsed = pcall(hs.json.decode, respBody)
    if not ok or not parsed or not parsed.choices or not parsed.choices[1] then
      cb(nil, "返回解析失败")
      return
    end
    cb(parsed.choices[1].message.content, nil)
  end)
end

------------------------------------------------------------------
-- 取选中文字(模拟 ⌘C,用完恢复原剪贴板)
------------------------------------------------------------------
local function withSelectedText(handler)
  local original = hs.pasteboard.getContents()
  hs.pasteboard.clearContents()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)

  hs.timer.doAfter(COPY_WAIT, function()
    local sel = hs.pasteboard.getContents()
    -- 恢复原剪贴板(仅文本)
    if original then hs.pasteboard.setContents(original) end
    if not sel or sel:gsub("%s+", "") == "" then
      showPopup("提示", "没读到选中的文字。请先选中一段文字,再按快捷键。", true)
      return
    end
    handler(sel)
  end)
end

------------------------------------------------------------------
-- 主流程
------------------------------------------------------------------
local function run()
  withSelectedText(function(sel)
    showPopup("翻译中…", sel)
    translate(sel, function(result, errMsg)
      if errMsg then
        showPopup("出错了", errMsg, true)
      else
        showPopup("译文(可选中复制)", result)
      end
    end)
  end)
end

------------------------------------------------------------------
-- 注册快捷键
------------------------------------------------------------------
function M.start()
  hs.hotkey.bind(HOTKEY_MODS, HOTKEY_KEY, run)
  hs.alert.show("popdict 划词翻译已就绪 · 快捷键 ⌘⇧T")
end

return M
