---
name: 小七扩展市场 V2 原型
description: 当前 HTML 原型的局部视觉记录；不替代正式产品设计规范
colors:
  ink: "#191919"
  muted: "#6b6b6b"
  surface: "#ffffff"
  soft: "#f4f4f4"
  line: "#e8e8e8"
  selected: "#f0f0f0"
  primary: "#1d1d1d"
  primary-hover: "#373737"
  danger: "#a52b25"
  focus: "#555555"
typography:
  headline:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif'
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1.32
    letterSpacing: "-0.6px"
  section:
    fontSize: "20px"
    fontWeight: 600
    lineHeight: 1.5
  item-title:
    fontSize: "17px"
    fontWeight: 550
    lineHeight: 1.3
  chat-body:
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.8
rounded:
  brand: "9px"
  field: "10px"
  brand-large: "15px"
  prompt: "16px"
  panel: "20px"
  dialog: "25px"
  pill: "99px"
spacing:
  control-gap: "8px"
  row-gap: "14px"
  panel-inset: "20px"
  dialog-inset: "25px"
  page-inset: "32px"
  column-gap: "36px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.surface}"
    rounded: "{rounded.pill}"
    padding: "10px 19px"
    height: "44px"
  button-primary-hover:
    backgroundColor: "{colors.primary-hover}"
  search:
    rounded: "{rounded.pill}"
    padding: "0 14px"
    height: "50px"
  brand-frame:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.brand}"
    size: "40px"
  dialog:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.dialog}"
    width: "600px"
---

# 扩展市场原型视觉记录

## Overview

范围仅为本目录的 HTML 演示原型。以上 token 来自 `src/styles.css` 与 `src/details.css`，描述当前实现，不构成全局品牌规范。产品边界见 [评审说明](../README.md)。

用户确认平板优先的两列市场、手机单列，顶层仅「插件 / 技能」，MCP 归入插件；技能通过聊天创建进入普通新会话。插件、MCP、技能的三张详情方向图已确认并保存在 [approved-details](../approved-details/)。方向确认不等同于 HTML 还原度、全部独立 SVG 或真机验收通过。

当前视觉以黑白灰、轻量列表、胶囊搜索、少量浅灰内容区承载任务。品牌图标保留来源色。演示目录、固定聊天回复与连接结果不代表正式服务能力。

## Colors

主要操作使用近黑色与白色文字，悬停略微变浅；正文、辅助文字、边线和浅灰容器分别使用 `ink`、`muted`、`line`、`soft`。选中页签与文件使用 `selected`。错误文字与卸载图标使用 `danger`，焦点轮廓使用 `focus`。

详情图标原始填充为 `ink`；主按钮里的图标通过 `filter: invert(1)` 显示浅色，当前计算结果约为 `#e6e6e6`，并非替换 SVG 源色。品牌 SVG 不跟随这一反色规则。

## Typography

全界面使用本机系统字体及中文回退，没有额外字体文件。市场标题使用 `headline`；列表名称与说明分别为 17 / 14 px，手机为 16 / 13 px，单行省略。

插件 / MCP 详情标题为 28 px、600、行高 1.25；窄容器下为 25 px。技能名称为 30 px、600、行高 1.3，手机为 25 px；介绍为 17 px、行高 1.7、最多 65ch，手机为 14 px。详情的长名称、描述和信息值允许换行；URL 可断行。

## Layout

市场容器最大宽度 1040 px，默认左右留白 32 px；列表两列、列距 36 px、行高至少 81 px。内容容器不宽于 540 px 时列表变为单列；视口不宽于 600 px 时页面留白为 20 px。设计预览的 834 / 390 是评审尺寸，不是另两套产品规范。

插件与 MCP 详情共用「面包屑 → 身份及操作 → 三条使用示例 → 简介 → 应用 → 技能或工具 → 信息」结构。平板身份区使用 82 px 图标框与 54 px 图形；容器不宽于 710 px 时操作换到下一行，不宽于 540 px 时缩为 66 / 44 px，示例内品牌图标隐藏，信息列由 122 px 标签列缩为 83 px。

技能详情使用返回 / 标题 / 更多的三列导航、身份简介、可展开介绍、精选案例和底部粘附操作。平板案例为三列；窄容器变成单列横向案例行，缩略图右置并从顶部裁切。技能标记框从 104 px 缩为 70 px，图形从 58 px 缩为 42 px。底部操作考虑安全区域。

编辑器为文件树与编辑区双栏，手机改为文件树覆盖面板。聊天为独立普通会话布局，内容容器最大宽度 880 px。

## Elevation & Depth

列表主要依靠留白、浅灰底色与细边线区分层级。品牌框阴影为 `0 1px 2px #00000005`；菜单为 `0 8px 26px #00000012, 0 2px 5px #00000004`；对话框为 `0 10px 40px #0000000d`。模态遮罩使用 `#0004` 与 1 px 模糊。示例条只在悬停时增加极轻阴影。

## Shapes

页签、常规按钮与搜索为胶囊形；品牌框使用小圆角，详情示例使用中等圆角，菜单与对话框使用较大圆角。技能底部主按钮为 18 px 圆角，手机为 16 px，保留宽而稳定的操作区。尺寸以当前组件 CSS 为准，不把详情局部形状推广到整个 App。

## Components

- **Brand / DetailIcon**：品牌与通用标记消费独立 SVG。来源、尺寸、颜色和状态见 [资产清单](../asset-catalog.md)。图形本身不承载按钮文字或可访问名称。
- **Button / IconButton**：常规最小高度 44 px；粗指针设备的主要操作与图标按钮扩大到至少 48 px。禁用透明度为 0.4；按钮与链接有 2 px 焦点轮廓。
- **TopBar / Search / Row**：两个顶层页签、搜索清除、行内添加与已安装更多菜单；悬停时列表名称加下划线，不增加整张实体卡片。
- **Dialog / 表单**：对话框最大宽度 600 px（按视口收缩），内部滚动；支持 Escape、遮罩关闭、焦点约束及关闭后恢复焦点。输入使用 10 px 圆角细边框，错误提示显示在字段区域。
- **PluginDetail / MoreMenu**：未安装显示安装，已安装显示管理与聊天试用；MCP 管理进入连接设置。更多菜单支持复制链接、个人技能编辑、已安装内容卸载，以及方向键 / Escape。MCP 信息显示连接状态、HTTP 与服务器地址；缺失网站 / 隐私政策显示「未提供」。
- **SkillDetail**：介绍展开状态有 `aria-expanded`，案例打开预览对话框；已安装内容可进入带上下文的普通会话，未安装内容先展示安装流程。
- **官方身份**：`src/config.js` 的 `officialDeveloper` 为「第七世界」。官方条目及旧演示标记由 `developerName()` 统一展示；个人导入保留其作者，不把所有第三方作者替换为官方名称。恢复演示目录时保留安装与个人内容。
- **反馈**：页面加载使用静态骨架，无转圈路由过渡；空、失败、未找到及重试使用文字和按钮。对话框进场为 0.17 s，toast 为 0.15 s；减少动态效果设置会停用动画。

## Do's and Don'ts

- **Do** 以当前源文件和已确认详情方向图为依据，保留平板 / 手机各自结构，并区分演示数据与真实能力。
- **Do** 复用独立 SVG、语义按钮和可访问名称；正式 Flutter 接入前逐项冻结资产与状态映射。
- **Don't** 将参考截图或已确认 PNG 作为运行时页面、按钮或图标贴图。
- **Don't** 把构建通过、静态检测通过或独立资产预览当作浏览器同状态视觉比对通过。

验收记录（2026-10-22）：本轮构建通过，新详情 JSX / CSS 静态检测返回 `[]`；独立详情资产预览已查看。用户选择自行查看：**未执行浏览器点击与 UI 截图对比，待用户视觉验收；未执行验证，待用户真机验证**。不更改 Flutter、服务端或 API，server deployment not needed。
