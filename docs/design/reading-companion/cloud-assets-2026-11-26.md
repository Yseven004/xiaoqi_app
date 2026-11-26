# 伴读解释云的资产与视觉状态

采用按规格接入。静态构图参考 [云朵与问答页](confirmed/cloud-and-discussion-2026-11-26.png)，摆位和整体运动分别以[位置稿](confirmed/cloud-placement-2026-11-26.gif)及[动效稿](confirmed/cloud-whole-motion-2026-11-26.gif)为准。图稿示例尺寸和交互时长提供视觉方向。手机、平板和系统栏的实际尺寸随设备变化。

| 资产 | 来源与独立核对 | SVG 与尺寸 | 消费及状态 |
| --- | --- | --- | --- |
| 云朵轮廓 | 以确认稿的固定白云轮廓为目标，按画布上的起伏和边距手工重建。独立预览 360×160。 | [云朵 SVG](../../../assets/images/reading_companion_explanation_cloud.svg)，viewBox 0 0 360 160。按可用空间限宽，深色主题调整颜色。 | `ReadingCompanionExplanationCloud`。首次带整朵位移动效，重生沿用同一轮廓。 |
| 指向选段的尾巴 | 以摆位稿中的尖尾为目标，手工重建两条边和透明画框。独立预览 100×64。 | [尾巴 SVG](../../../assets/images/reading_companion_explanation_tail.svg)，viewBox 0 0 28 18，组件显示框 28×18 dp 并按摆位转向。 | `ReadingCompanionExplanationCloud`，尾尖朝选段。 |

两项独立资产已用 CairoSVG 渲染并检查，预览位于本机 `.codex-artifacts/reading-companion-cloud-asset.png`。正文、加载反馈、退出和版本切换由 Flutter 控件呈现。组件实拍、整页对照及真机待验证。
