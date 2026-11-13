# 应用角色动效

Codex 会话使用蓝色伙伴，Claude Code 会话使用橙色小螃蟹。两个角色的六种姿态均使用应用当前的图层、状态文案和动画轨道。标准版用于列表和提醒，迷你版使用应用在28pt及以下采用的简化图层。GIF 放大展示，单态画布为192×240，25fps。

## 蓝色伙伴 · Codex

| 状态 | 标准版 | 迷你版 | 播放 |
|---|---|---|---|
| 运行中 | [working](mascot-working.gif) | [mini-working](mascot-mini-working.gif) | 41.4秒，循环 |
| 空闲 | [idle](mascot-idle.gif) | [mini-idle](mascot-mini-idle.gif) | 6.4秒，循环 |
| 待确认 | [attention](mascot-attention.gif) | [mini-attention](mascot-mini-attention.gif) | 8秒，循环 |
| 待回答 | [question](mascot-question.gif) | [mini-question](mascot-mini-question.gif) | 8秒，循环 |
| 待查看 | [ready](mascot-ready.gif) | [mini-ready](mascot-mini-ready.gif) | 8秒，循环 |
| 运行失败 | [error](mascot-error.gif) | [mini-error](mascot-mini-error.gif) | 8秒，循环 |

[标准六态总览](mascot-six-states.gif) · [迷你六态总览](mascot-mini-six-states.gif)

## 橙色小螃蟹 · Claude Code

| 状态 | 标准版 | 迷你版 | 播放 |
|---|---|---|---|
| 运行中 | [crab-working](mascot-crab-working.gif) | [crab-mini-working](mascot-crab-mini-working.gif) | 41.4秒，循环 |
| 空闲 | [crab-idle](mascot-crab-idle.gif) | [crab-mini-idle](mascot-crab-mini-idle.gif) | 6.4秒，循环 |
| 待确认 | [crab-attention](mascot-crab-attention.gif) | [crab-mini-attention](mascot-crab-mini-attention.gif) | 8秒，循环 |
| 待回答 | [crab-question](mascot-crab-question.gif) | [crab-mini-question](mascot-crab-mini-question.gif) | 8秒，循环 |
| 待查看 | [crab-ready](mascot-crab-ready.gif) | [crab-mini-ready](mascot-crab-mini-ready.gif) | 8秒，循环 |
| 运行失败 | [crab-error](mascot-crab-error.gif) | [crab-mini-error](mascot-crab-mini-error.gif) | 8秒，循环 |

[标准六态总览](mascot-crab-six-states.gif) · [迷你六态总览](mascot-crab-mini-six-states.gif)

## 播放与映射

所有 GIF 均无限循环。提醒类动效和总览每8秒重播，提醒动作在每轮开头播放，随后保持姿态。运行中的41.4秒包含起伏、双鳍（双钳）与眨眼的完整共同周期，空闲的6.4秒包含呼吸和睁眼的完整共同周期。`preview-*.png` 是同一导出过程在3.2秒处的静帧。

已查看的完成结果和已停止状态复用空闲姿态，暂时无法获取状态时复用异常姿态。这些映射由应用的 `PhaseAppearance` 决定。

在项目根目录重建全部 GIF 和预览图：

```sh
./scripts/export_mascot_gifs.sh
```

脚本复用 [状态与角色映射](../../Sources/SignalApp/MascotView.swift)、[原生图层](../../Sources/SignalApp/AnimatedMascot.swift)和[动画轨道](../../Sources/SignalApp/MascotAnimation.swift)，并检查导出文件的帧数、时长、尺寸、播放次数和动作变化。
