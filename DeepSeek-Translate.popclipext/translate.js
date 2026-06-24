// DeepSeek 翻译 —— PopClip 扩展
// 选中文字 → 点 PopClip 的 🌐 → 调 DeepSeek → 气泡显示译文
// 方向:含中文 → 译成英文;其它 → 译成简体中文

const axios = require("axios");

function hasChinese(s) {
  return /[一-鿿]/.test(s);
}

// PopClip 把这个函数当作 action 的代码执行;返回的字符串按 after:"show-result" 弹气泡
module.exports = async (input, options) => {
  const text = (input.text || "").trim();
  if (!text) return "没有选中文字";

  const apikey = (options.apikey || "").trim();
  if (!apikey) return "请先在 PopClip 设置里填入 DeepSeek API Key";

  const target = hasChinese(text) ? "English" : "Simplified Chinese";
  const model = (options.model || "deepseek-chat").trim();

  try {
    const resp = await axios.post(
      "https://api.deepseek.com/chat/completions",
      {
        model: model,
        messages: [
          {
            role: "system",
            content:
              "You are a professional translation engine. Translate the user's text into " +
              target +
              ". Output ONLY the translation itself — no explanations, no quotes, no extra words.",
          },
          { role: "user", content: text },
        ],
        temperature: 0.3,
        stream: false,
      },
      {
        headers: {
          Authorization: "Bearer " + apikey,
          "Content-Type": "application/json",
        },
      }
    );
    return resp.data.choices[0].message.content.trim();
  } catch (e) {
    if (e.response) {
      return "DeepSeek 出错(HTTP " + e.response.status + "):请检查 API Key 或余额";
    }
    return "请求失败:" + (e.message || "网络异常");
  }
};
