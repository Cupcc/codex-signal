# 素材来源

## 应用图标

`app-icon.svg`、`app-icon.png` 与原生资源中的 `AppIcon.icns` 沿用本项目原创蓝色伙伴，使用独立的微笑表情与浅蓝圆角底板。运行 `python3 scripts/build_app_icon.py` 可从同一角色源代码重建全部图标尺寸，没有使用第三方图标素材。

## 默认圆润皮肤

`toy-working.svg`、`toy-attention.svg`、`toy-idle.svg`、`toy-question.svg`、`toy-error.svg` 为本项目原创的蓝色括号伙伴，延续「团团」的资产命名。用户要求重新设计并以蓝色为主，本轮重新绘制头罩、冰蓝面罩与括号侧鳍，删除奶白方团、叶片、腮红、脚与键盘配件。主体保持蓝色，状态通过表情、侧鳍和局部标记表达。

`toy-mini-*.svg` 是供 24–28px 使用的光学校正版本，扩大头罩与面罩、去掉阴影、高光与光标细节。21px 的接力条也使用简化版。源代码 [build_toys.py](build_toys.py) 可用 Python 3 无依赖重建全部十个 SVG。

参考既有圆润 icon toy 的亲和感，没有复制 Coucou、CodeIsland 或 OpenAI 的角色图片与造型代码。正式画面均使用此组原创资产；静态SVG保留为回退资产，HTML通过 `mascot-art.js` 与 `mascot-motion.js` 增强为五态动效；绘图与动画均为本项目原创。

## Claude Code 橙色小螃蟹

`crab-*.svg` 与 `crab-mini-*.svg` 为本项目原创的橙色小螃蟹「钳钳」，用于 Claude Code 会话。按用户要求使用专属橙色与螃蟹造型：圆壳、眼柄、一对钳子与六条短腿，配奶油色腹部与深棕色眼睛，不使用蓝色。由 [build_toys.py](build_toys.py) 以纯矢量路径绘制，与蓝色伙伴共用状态角标和姿态语义。

螃蟹是通用动物形象。没有复制 Anthropic 或 Claude Code 的标志、吉祥物、像素图或其他第三方角色图片，也不表示得到 Anthropic 的背书。

## 可选经典皮肤参考

本目录的 `dex-working.svg`、`dex-attention.svg`、`dex-idle.svg` 从 [CodeIsland 的 DexView.swift](https://github.com/wxtsky/CodeIsland/blob/main/Sources/CodeIsland/DexView.swift) 的像素矩形坐标和色板转写为静态 SVG，供本项目设计稿使用。

来源：wxtsky/CodeIsland，Copyright (c) 2026 wxtsky，MIT。许可证全文位于 [CODEISLAND-LICENSE.txt](CODEISLAND-LICENSE.txt)。读取时间：2026-11-09。

保留 Dex 的像素云轮廓、终端脸和键盘/等待/休息语义。SVG 是静态姿态，不代表已实现原项目动画，也不是新增第三方图片。等待感叹号和休息标记为便于静态识别的定格。

本项目为基于 CodeIsland 的设计探索，未宣称得到原项目或 OpenAI 的背书。
