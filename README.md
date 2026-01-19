# MPV Skip Intro & Outro Plugin

这是一个为 mpv 播放器设计的 Lua 脚本，用于跳过番剧/电影的片头（OP）和片尾（ED）。

它支持两种模式：
1.  **自动识别（章节优先）**：自动读取视频内置的章节（Chapter）信息，匹配 `OP`、`ED`、`Intro`、`Outro` 以及中文的 `片头`、`片尾`、`序章` 等关键词，精准跳过。
2.  **手动设置**：对于没有章节信息的视频，可以通过菜单或快捷键手动设置片头/片尾时长。

## ✨ 特性

- **智能章节识别**：支持自定义正则表达式匹配章节标题。
- **uosc 集成**：完美适配 [uosc](https://github.com/tomasklaen/uosc) 界面，提供图形化菜单进行开关、微调和输入。
- **无缝交互**：支持在 uosc 菜单内直接输入数字设置时长，无需跳转原生 OSD。
- **快捷键微调**：支持通过快捷键快速设置当前位置为片头/片尾，或进行 ±5s 微调。
- **防误触逻辑**：
  - 仅在检测到的 OP/ED 区间内触发跳过，避免误跳过正片前的序章。
  - 手动调整时间后立即生效，无需重启脚本。
- **安全稳定**：内置异常捕获，脚本报错不会导致播放器崩溃或快捷键失效。

## 📦 安装

1.  将 `scripts/skip_oped.lua` 复制到你的 mpv `scripts` 文件夹。
2.  将 `script-opts/skip_oped.conf` 复制到你的 mpv `script-opts` 文件夹（可选，用于自定义配置）。

## ⚙️ 配置 (script-opts/skip_oped.conf)

你可以在 `skip_oped.conf` 中自定义默认行为和匹配模式：

```ini
# 是否默认启用
enabled=no

# 是否优先使用章节信息
prefer_chapters=yes

# 默认手动时长
intro_len=0
outro_len=0

# 章节匹配模式 (支持 Lua 正则, 逗号分隔)
opening_patterns=^op%s,^op$, opening$,^opening$,^intro%s,^intro$, intro$,片头,片頭,序章,主题曲,主題曲,开场,開場,序幕
ending_patterns=^ed%s,^ed$, ending$,^ending$,^outro%s,^outro$, outro$,片尾,片尾,尾声,尾聲,闭幕,閉幕,结束,結束,预告,預告
```

## ⌨️ 快捷键绑定

在 `input.conf` (或 `input_uosc.conf`) 中添加以下绑定：

```properties
# === 菜单与开关 ===
Alt+o           script-binding skip_oped/menu           #! 视频 > 片头片尾设置
Alt+Shift+o     script-binding skip_oped/toggle         #! 视频 > 启用/禁用 跳过片头片尾

# === 快捷设置 ===
Alt+t           script-binding skip_oped/intro_set_pos  #! 视频 > 设置当前位置为片头
Alt+w           script-binding skip_oped/outro_set_pos  #! 视频 > 设置当前位置为片尾

# === 微调 (推荐使用按键序列) ===
# 按 t 然后按 -/= 微调片头
t-=             script-binding skip_oped/intro_add      #! 视频 > 片头 +5s
t--             script-binding skip_oped/intro_sub      #! 视频 > 片头 -5s

# 按 w 然后按 -/= 微调片尾
w-=             script-binding skip_oped/outro_add      #! 视频 > 片尾 +5s
w--             script-binding skip_oped/outro_sub      #! 视频 > 片尾 -5s
```

## 🧩 uosc 菜单预览

如果你安装了 uosc，按 `Alt+o` 可以呼出可视化菜单：
- 启用/禁用全局跳过
- 开关“OP/ED 章节优先”
- 手动设置片头/片尾时长（支持直接输入数字）
- 清空设置 / 立即跳过

## ⚠️ 注意事项

- 如果你使用了 `input_plus.lua` 或其他类似的跳过脚本，建议禁用它们的相关功能（如 `chap_skip_toggle`），以免产生冲突。
- 自动模式依赖视频文件的 Chapter 信息，如果视频没有章节，脚本会自动回退到手动时长模式。

## 📝 License

MIT
