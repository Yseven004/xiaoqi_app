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
- **空输入与键盘：** 输入框没有任何内容时，用户主动收起软键盘必须同时退出输入焦点，移除光标和焦点边框；不能仅隐藏键盘而留下空输入的焦点。键盘动画、布局重算不能重新抢回焦点。
- **点击外部：** 点击空白处或其他按钮时退出当前输入焦点并保留已输入内容；按钮应在本次点击直接响应，不能要求先收键盘再点一次。点击另一个输入框时正常转移焦点，不得把新输入框的焦点一起清除。
- **有内容与无障碍：** 仅收起键盘时不强制清除已有内容输入框的焦点；不得清空文本、破坏选择区或阻止键盘／辅助技术主动聚焦。除明确的输入任务外，不自动聚焦或弹出键盘。
- **验收：** 后续所有前端表单默认遵守以上规则，覆盖空输入收键盘、点击按钮、点击空白、输入框切换、键盘动画及已输入内容保留；触屏与鼠标均需适用。

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

## Draft Save Feedback

- 用户于 2026-10-24 确认底部统一状态带：位于创建弹窗固定底栏上方，状态与恢复入口同组；实现记录见 [草稿保存与刷新修复](docs/plans/2026-10-24-draft-save-refresh-fix.md)。
- 本机保存和云端同步分开：仅本机写入失败显示“未保存成功”；同步冲突显示“草稿已保存在本机／云端版本有变化”，提供单个“处理同步”入口并禁用发布，不直接展示底层异常或断言另一设备修改。
- 保存成功使用原位状态带，不叠加成功浮层。网络同步不锁住编辑器或阻止退出；内容改变后明确提示尚未保存。
- 保留手动保存；关闭时如当前或另一创建页有未保存修改，提示提供保存后退出和继续编辑；提示右上角 × 表示不保存退出。保存后退出只等待已修改页面的本机写入，失败保留编辑器。
- 列表先展示本机内容，后台读取不替换已有列表为骨架；草稿冲突只标注对应草稿，不能作为市场列表读取的前置条件。外框尺寸、SVG 资产规则及全局输入焦点规则继续有效。

## Supplement Information（2026-10-25，局部扩展）

- 本节仅适用于扩展市场补充资料四态，沿用既有黑白灰体系；冻结目标、独立 SVG 清单与实施记录见 [补充资料规格](docs/design/extension-market-v2/supplement-info-confirmed-2026-10-25.md)。
- 资料概览直接进入介绍或图库；介绍为无行数上限的纵向文本画布，浅灰模板不写入数据。图库保留横排/网格、排序和最多 6 张，不提供说明文字界面但保留历史 caption；空态为独立叠卡裸加号 SVG 与实时“添加第一张图片”文字。
- 默认图标按真实类型统一为技能 file-text、插件 extension、MCP 三节点；白色方圆外框等比缩放，上传图居中 cover。窄屏工具条可分两行，网格适配宽度，关键操作至少 48dp；全局焦点与键盘规则继续有效。
- 状态为“代码已按规格接入；未验证”。用户选择“只实现代码，验证由我执行”；独立 SVG 预览、同状态视觉对照、自动化/静态检查及真机验证均未执行。本节不构成视觉验收。

## Market Layout and Input Corrections（2026-10-25）

- 市场条目和图片网格占满可用宽度，单项从左上角开始；图片网格按稳定列宽等比显示，增删图片不因数量变化重新居中或缩放。
- 添加内容、补充资料、确认共用外框与线形进度条，补充资料在内部滚动。三个步骤底部按钮共用尺寸：次操作 96×44、主操作 150×44，下一步使用现有成功绿色。详细介绍常规态沿用弹窗，展开态按 2026-10-26 用户最新确认使用接近全屏的独立画布；收起后恢复标签与说明。详细介绍不显示“返回后保留已填写内容”，常规弹窗同步缩减原提示区高度，仅保留紧凑底边距；实际返回保留内容的行为不变。键盘只改变可编辑视口，不自动抢焦点。
- 本轮修正优先于此前补充资料独立外框/圆点进度的规格。实施与待验收项见 [市场布局与输入修正](docs/design/extension-market-v2/market-layout-input-fixes-2026-10-25.md)，不改变全局设计令牌；未执行验证。

- 2026-10-26 导入筛选纠正仍有效：Android 包选择器使用支持格式筛选，禁止退回所有文件。见 [导入筛选与正文扩展纠正](docs/design/extension-market-v2/import-editor-correction-2026-10-26.md)；其中固定介绍外框的旧决定已被下述用户确认覆盖。

## Independent Expanded Editors（2026-10-26，用户确认）

- “详细介绍”展开时整个白色画布、标题和完成按钮一起扩大：可用安全区域四边留 12 个逻辑像素，外圆角 16；取消内层输入框边线，收起控件移到顶部工具栏，底部保留内容保留提示。收起恢复小弹窗，正文、选择及控制器保留。
- 主界面输入框展开时隐藏主页顶栏并关闭空间菜单，防止导航按钮与编辑画布重叠；收起恢复顶栏。沿用原有不透明编辑背景及全局输入焦点规则。
- 范围、目标图、技术参考和验收记录见 [独立编辑画布修复](docs/design/extension-market-v2/independent-editor-canvases-2026-10-26.md)。代码已按规格接入；未执行验证，待用户真机验证。

