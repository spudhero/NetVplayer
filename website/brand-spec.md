# NetVplayer 官网品牌规范

## 色彩令牌

```css
:root {
  --bg: oklch(100% 0 89.88);
  --surface: oklch(97.071% 0.00265 286.35);
  --fg: oklch(23.158% 0.00381 286.1);
  --muted: oklch(53.99% 0.00769 286.14);
  --border: oklch(86.524% 0.00683 286.26);
  --accent: oklch(56.292% 0.19333 256.16);
}
```

## 字体

- Display: `"SF Pro Display", "SF Pro SC", -apple-system, BlinkMacSystemFont, sans-serif`
- Body: `"SF Pro Text", "PingFang SC", -apple-system, BlinkMacSystemFont, sans-serif`
- Mono: `"SFMono-Regular", "SF Mono", ui-monospace, monospace`

## 视觉语言

1. 纯白主背景与浅灰分区交替，让每一屏只表达一个产品重点。
2. 标题采用高对比深灰，说明文字保持克制宽度与清晰行距。
3. 海蓝只用于主要下载动作、文本链接和必要的焦点反馈。
4. 产品截图使用完整画面与轻量边框，不叠加装饰性光效或拟物框架。
5. 动效仅使用低位移淡入，禁用弹跳、缩放炫技与连续视差。
6. 下载按钮和兼容信息以 GitHub 最新正式 Release 为真源；静态 HTML 保留当前正式版本回退，脚本只采用严格匹配版本化 arm64 ZIP 名称的资产。

整体方向：以 Apple 产品页式留白和层级呈现一款原生、可信、由用户掌控内容的 macOS 播放器。
