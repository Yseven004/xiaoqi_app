# 伴读解释云的资产与视觉状态

采用按规格接入。静态构图参考 [云朵与问答页](confirmed/cloud-and-discussion-2026-11-26.png)，摆位和整体运动分别以[位置稿](confirmed/cloud-placement-2026-11-26.gif)及[动效稿](confirmed/cloud-whole-motion-2026-11-26.gif)为准。图稿示例尺寸和交互时长提供视觉方向。手机、平板和系统栏的实际尺寸随设备变化。

| 资产 | 来源与独立核对 | SVG 与尺寸 | 消费及状态 |
| --- | --- | --- | --- |
| 云朵轮廓 | 以确认稿的固定白云轮廓为目标，按画布上的起伏和边距手工重建。独立预览 360×160。 | [云朵 SVG](../../../assets/images/reading_companion_explanation_cloud.svg)，viewBox 0 0 360 160。按可用空间限宽，深色主题调整颜色。 | `ReadingCompanionExplanationCloud`。首次带整朵位移动效，重生沿用同一轮廓。 |
| 指向选段的尾巴 | 以摆位稿中的尖尾为目标，手工重建两条边和透明画框。独立预览 100×64。 | [尾巴 SVG](../../../assets/images/reading_companion_explanation_tail.svg)，viewBox 0 0 28 18，组件显示框 28×18 dp 并按摆位转向。 | `ReadingCompanionExplanationCloud`，尾尖朝选段。 |
| 侧边连接尾巴 | 沿用批准尾巴的白填充和灰描边，重建水平长三角。独立预览 640×72。 | [侧边尾巴 SVG](../../../assets/images/reading_companion_explanation_side_tail.svg)，viewBox 0 0 160 18，高度 18 dp；宽度按选段端点到云朵侧边轮廓动态计算。 | `ReadingCompanionExplanationCloud`，左右侧放时尾尖对准最近已选行并连接云朵轮廓；深色由组件着色。 |

三项独立资产已用 CairoSVG 渲染并检查，预览位于本机 `.codex-artifacts/reading-companion-cloud-asset.png` 与 `.codex-artifacts/design-review/side-tail-preview.png`。正文、加载反馈、退出和版本切换由 Flutter 控件呈现。组件实拍、整页对照及真机待验证。

## 云内布局与交互

- 不显示标题。关闭按钮位于云朵轮廓以内的右上方，解释正文从其下方开始；超长解释只在云内滚动。切换或生成出新答案后，正文滚动位置回到开头；重生期间保留当前答案与出处。
- 云朵优先放在选段上方；上方空间不足时按逐行选区寻找不压住选段的一侧空位，再考虑下方。侧边尾巴按侧边曲线轮廓定位，并指向最近已选行；上方或下方尾巴锚定最近的已选行。底部动作固定为左侧「重新生成」、右侧「继续聊」，已有另一版答案时才在中间出现版本切换。
- 重新生成时保留当前解释和云朵位置，只在左侧动作内显示小型进度指示与「生成中…」。点击不显示阴影、涟漪或底色闪烁，同时保留键盘焦点提示。
- 按阅读区域宽度缩放，最大 560 dp；窄屏高度至少 224 dp，留出正文和底部动作空间。靠近视口顶部时允许最多 12 dp 的上方空间不足，以保持上方优先并避免大幅遮挡选段。
