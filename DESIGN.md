---
name: Xiaoqi
description: 黑白灰阅读与学习界面规范
colors:
  graphite: "#24272C"
  ink: "#303134"
  secondary-ink: "#555B62"
  muted-ink: "#70747C"
  white: "#FFFFFF"
  fog: "#F7F7F8"
  soft-gray: "#F2F2F2"
  line: "#D5D8DE"
  border: "#E0E0E0"
  alert: "#B3261E"
typography:
  headline:
    fontSize: "21px"
    fontWeight: "600"
    lineHeight: "1.35"
  title:
    fontSize: "16px"
  body:
    fontSize: "14px"
    lineHeight: "1.5"
  label:
    fontSize: "13px"
rounded:
  compact: "8px"
  control: "12px"
  capsule: "13px"
  panel: "22px"
  pill: "9999px"
components:
  button-primary:
    backgroundColor: "{colors.graphite}"
    textColor: "{colors.white}"
    rounded: "{rounded.compact}"
    height: "42px"
  button-secondary:
    backgroundColor: "{colors.white}"
    textColor: "{colors.ink}"
    rounded: "{rounded.compact}"
    height: "42px"
  chip-selected:
    backgroundColor: "{colors.graphite}"
    textColor: "{colors.white}"
    rounded: "{rounded.pill}"
  input:
    backgroundColor: "{colors.white}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
  menu-panel:
    backgroundColor: "{colors.white}"
    rounded: "{rounded.panel}"
---

# Design System: Xiaoqi

## Overview

**Creative North Star: "清爽的黑白阅读桌"**

小七的界面以黑、白、灰为主，让书籍和资料内容保持醒目。黑色用于主要操作和选中状态；白色留给工作区域；浅灰色用来区分背景、提示文字和边界。界面保持安静、清楚，减少装饰。

手机和平板共用这套视觉方向。页面之间通过文字层级、留白和细分隔线建立结构，按钮、输入框和浮层都沿用同一组灰阶与圆角规则。

**Key Characteristics:**
- 黑白灰为主，颜色只承担清楚的状态含义。
- 结构靠文字、间距和细边框表达。
- 阴影只用于需要浮起的菜单和操作胶囊。

## Colors

颜色按用途分组。大面积保持白色和浅灰，深色集中在文字、主要操作和选中状态。

### Primary
- **石墨黑**：用于主要按钮、已选标签和需要突出的文字。
- **正文墨色**：用于正文与普通控件文字。

### Secondary
- **中性灰**：用于说明文字、辅助信息和次级图标。
- **提示灰**：用于占位、弱提示和非重点状态。

### Neutral
- **纯白**：用于输入框、卡片和工作表面。
- **雾灰**：用于引用、代码块等轻量内容区域。
- **浅灰**：用于次级表面和轻度分组。
- **分隔灰**：用于输入框边线和内容分隔。
- **边框灰**：用于菜单和浮层边界。

### Tertiary
- **错误红**：仅用于错误和危险操作，不承担普通装饰强调。

**The Grayscale First Rule.** 优先用文字层级、留白和灰阶表达重点；只有错误或危险状态才使用红色。

## Typography

**Display Font:** Flutter / Android 系统无衬线字体  
**Body Font:** Flutter / Android 系统无衬线字体  
**Label/Mono Font:** 代码内容使用等宽字体

**Character:** 字体清晰直接，重点由字号、粗细和行距区分。阅读材料沿用阅读器或原文设置，不把正文展示字体扩展成全应用 UI 字体。

### Hierarchy
- **Display**（半粗，21px，行高 1.35）：用于 AI 回复中的一级标题。
- **Headline**（半粗，17–19px，行高约 1.35）：用于次级标题。
- **Title**（常规，16px）：用于主要控件标题。
- **Body**（常规，14px，行高约 1.5）：用于正文和表单说明。
- **Label**（常规，12–13px）：用于辅助标签和次要状态。

**The System Sans Rule.** 界面文字沿用系统无衬线字体；代码片段使用等宽字体，阅读内容按阅读器设置显示。

## Layout

以 Android 手机和平板为目标。保持页面内容与操作区层次清楚，给书籍正文留出空间；表单、菜单和辅助操作不应抢过阅读内容。窄屏内容可以换行，宽屏可以使用额外空间，但避免把同一信息重复放进多层卡片。

当前组件常见的内部留白集中在 8、12、16 和 24 dp 左右。精确布局以对应页面代码为准；此文件不把单个页面尺寸推广成全局固定栅格。

## Elevation & Depth

界面以平面和细边框为主。普通内容区域不依赖阴影；菜单和输入区上方的操作胶囊可以用轻柔阴影帮助识别层级。阴影用于区分浮层，不作为装饰。

### Shadow Vocabulary
- **轻浮层**：能力菜单使用低不透明度、短距离的阴影。
- **操作胶囊**：输入区上方的胶囊可以有更柔和的阴影和背景模糊。

**The Overlay Only Rule.** 静态内容优先保持平面；阴影只给需要从页面上浮起的操作层。

## Shapes

使用简洁的圆角矩形和胶囊形。小型控件采用紧凑圆角，输入框稍圆，菜单面板使用更大的圆角，标签采用完整胶囊形。边框保持轻细；不要在同一组控件里混用过多不同形状。

## Components

组件气质保持轻、清楚、直接。以下样式以当前输入区、能力菜单和相关操作控件为依据。

### Buttons
- **主要按钮：** 石墨黑底、白字，用于明确的提交或确认操作。
- **次要按钮：** 白底、浅灰细边框、深色文字；避免用阴影制造层级。
- **状态：** 选中或按下状态用深色填充表达；焦点状态需清楚可见。

### Chips
- **未选中：** 白底、灰色细边框、深色文字。
- **选中：** 深色底、白字；使用胶囊轮廓，不额外添加勾选图标，除非状态需要更明确。

### Cards / Containers
- **背景：** 白色或浅灰。
- **圆角：** 普通内容容器保持克制；菜单面板可使用较大圆角。
- **边框：** 以浅灰细线区分容器。
- **阴影：** 仅浮层使用轻阴影，参见 Elevation & Depth。

### Inputs / Fields
- **样式：** 白底、灰色边框、圆角矩形。
- **焦点：** 边框加深，以黑灰变化表达焦点。
- **禁用 / 错误：** 维持可读对比度，错误文案使用错误红。

### Navigation
- 导航文字和图标使用灰阶；当前项用深色或更高文字权重突出。使用明确的文字标签帮助识别操作。

### Composer Action Capsule
- 输入框上方的操作胶囊使用半透明白底、紧凑内边距和圆角。展开或收起时只做轻量的透明度、旋转过渡，不增加强烈动效。

## Do's and Don'ts

### Do:
- **Do** use grayscale for ordinary surfaces, text, selection, and hierarchy.
- **Do** use spacing and type weight before adding another visual accent.
- **Do** keep inputs and menus readable with clear borders and focus states.
- **Do** use static placeholders during route transitions; reserve small progress indicators for an action in progress.

### Don't:
- **Don't** add saturated accent colors or decorative gradients to ordinary screens.
- **Don't** add heavy shadows to static cards or nest several card layers.
- **Don't** rely on color alone to communicate errors or selection.
- **Don't** use a loading spinner as a page transition.

