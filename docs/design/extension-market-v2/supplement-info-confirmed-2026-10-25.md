# 补充资料：2026-10-25 冻结与实施记录

后续修正：同日用户在真机反馈后确认三个主步骤外框及进度条统一、介绍输入支持扩展与内部键盘避让、网格单张从左上角稳定排列。涉及这些条目时，以 [市场布局与输入修正](market-layout-input-fixes-2026-10-25.md) 为最新规格；本文保留首轮设计来源与记录，不代表后续视觉验收。

状态：用户已确认四张定稿；代码已按规格接入；未验证。模式为严格目标还原，Operate。主界面及各编辑态以本文件所链接的同源目标为准，不沿用旧折叠编辑方案。用户选择“只实现代码，验证由我执行”，本次仅做源码阅读与实现记录，不代表视觉验收。

## 冻结范围

1. 技能、插件、独立 MCP 共用资料概览；图标与名称同排，简介独立。详细介绍、介绍图片是单击进入原弹窗的直接入口，不先折叠展开。
2. 详细介绍是单一、可纵向持续输入和滚动的文本画布。未输入时显示浅灰引导模板；首字输入后隐藏，清空后恢复。模板不是预填数据，不保存、不发布。顶部返回/完成固定，不自动聚焦。
3. 图片采用已选大图直接编排，保留横排/网格、添加、排序、删除和数量上限 6。移除“展示布局”标签、所有图片说明编辑/显示、底部滑动与说明文案；历史 caption 数据不删。大图和操作条利用全部剩余高度，底部仅留滚动条与紧凑内边距。
4. 空图是三张微散开的叠放卡片，中间只有裸露的大加号，没有圆圈/徽章。下方“添加第一张图片”，整组可点击上传。空态不显示布局切换、重复添加按钮、滚动条或排序提示。取消/失败保留空态，删除最后一张恢复空态。
5. 默认图标只保留技能 file-text、插件 extension、MCP mcp。上传直接打开选择器，取消/失败保留原图；上传图标以 cover 居中铺满方圆外框。已有默认图标按真实类型显示；上传图标保留。草稿、列表、详情和连接入口保持一致。显式保存/发布规则与 API 合约不变。

## 同源目标与 Layout Spec

目标目录：`approved-details/supplement-info-2026-10-25/`。四图是用户最后确认的附件，不能用实际渲染反向替代目标。原始截图约 992×1586/1585；没有已知真实设备 DPR，以 834 dp 宽的等比视口作为可重现的布局比较坐标，另检查 390×844 窄屏。生成图的细微噪声/字形不是最终资产。

| 状态 | 目标 | 约束（目标像素，以实际文件为准） |
| --- | --- | --- |
| 资料概览 | [定稿](approved-details/supplement-info-2026-10-25/overview-approved.png) | 外框约 x97,y361,w800,h1000；内容左右约 44；图标约 133 方形；标题约 36，正文/标签约 24；图标/名称同排；两条资料入口约 120 高；固定底栏 |
| 详细介绍空态 | [定稿](approved-details/supplement-info-2026-10-25/introduction-approved.png) | 外框约 x97,y361,w800,h962；固定标题/说明/细线；介绍内容标签；连续画布与底部保留输入说明；画布内部滚动 |
| 图片已有 | [定稿](approved-details/supplement-info-2026-10-25/gallery-approved.png) | 外框约 x97,y358,w800,h1060；布局/添加工具行；图片原比例显示、第二张露出；下方排序手柄、序号和删除；滚动条靠近底边 |
| 图片为空 | [定稿](approved-details/supplement-info-2026-10-25/gallery-empty-approved.png) | 与图片已有共用外框；叠卡约 514×290，整体在内容区偏上居中；文字与图形分离，不栅格化文字 |

平板尺寸按外框宽与目标约 800 px 的比例换算；手机保持可读文字和至少 48dp 操作区域，名称允许改为纵向排列、资料与网格纵向滚动。步骤 0 的导入/连接布局不纳入此次重排。头部与底栏避让键盘；空输入收键盘必须失焦，点击按钮当次生效，切换输入不清除新焦点。

## 固定资产清单

| 资产 | 来源/许可 | 文件与 viewBox | 显示/状态/消费 |
| --- | --- | --- | --- |
| 技能文档 | 项目既有 Phosphor，MIT，沿用 detail 许可 | `assets/icons/extension_market/detail/file-text.svg`，256² | 技能默认，字形占外框约 56%；所有 SkillPresentationIcon |
| 插件拼图 | 项目既有 Material 资产，沿用现有来源 | `assets/icons/capabilities/extension.svg`，0 -960 960 960 | 插件默认；不再供挑选其他内置图标 |
| MCP 三节点 | 项目既有已确认 Phosphor 三节点 | `assets/icons/capabilities/mcp_connector.svg`，256² | 独立 MCP/连接默认 |
| 图片入口 | 项目既有独立 SVG | `assets/icons/capabilities/image.svg`，24² | 资料入口，小图标 |
| 方圆外框 | 依据图一/图六几何重建，项目自有 | `assets/icons/extension_market/detail/presentation-icon-frame.svg`，100² | 白底、细边；轮廓比例统一；上传另用同轮廓裁切 |
| 空态叠卡与裸加号 | 依据第四张定稿的矩形、旋转角和比例重建，未追踪像素、未嵌位图，项目自有 | `assets/icons/extension_market/detail/gallery-empty-stack.svg`，514×290 | 图片 0 张；与实时文字共同构成一个有语义的上传入口 |
| 补充资料进度线 | 依据已确认创建流程几何重建，项目自有 | `assets/icons/extension_market/detail/supplement-progress.svg`，0 0 720 24 | 资料概览；高度 24×s，按可用宽度铺展；market_skill_editor |

本次新增独立 SVG：`presentation-icon-frame.svg`（0 0 100 100）、`gallery-empty-stack.svg`（0 0 514 290）、`gallery-drag.svg`（0 0 16 24）、`supplement-progress.svg`（0 0 720 24）。`gallery-drag.svg` 为图片卡片排序手柄，显示宽度 16×s；其余来源、状态和消费者见上表。复用 `mcp_connector.svg`（0 0 256 256）。默认图标字形占外框约 56%，白色方圆框按组件尺寸等比显示；概览框为 120×s，空态叠卡按可用宽度等比显示。

资产状态：定稿确认完成；独立 SVG 已建立并接入，用户本次不执行独立预览与页面验证，因此独立 SVG 预览、实际尺寸边界核对及同状态页面对照均待验收。叠卡的连续柔影仅以轻量矢量层表示，不把截图贴片用于最终控件。

## 实施依据与风险

2026-10-25 读取 Flutter 官方 [TextField expands](https://api.flutter.dev/flutter/material/TextField/expands.html)、[ReorderableListView](https://api.flutter.dev/flutter/material/ReorderableListView-class.html)、[ClipRRect](https://api.flutter.dev/flutter/widgets/ClipRRect-class.html)，并参考 GitHub [Flutter 排序示例](https://github.com/flutter/flutter/blob/master/examples/api/lib/material/reorderable_list/reorderable_list_view.0.dart)（master 原始示例，BSD-3-Clause；仅参考原生排序/keys/handle 用法，不复制整个实现）。本机 SDK 路径标识 3.47.5；不升级、不新增依赖。具体 API 以本机 SDK 为准。

真实类型由调用方提供，不能根据旧 icon_asset 猜测技能/插件/MCP。只做显示归一化，显式保存才更新当前草稿，不批量迁移或删除数据。SVG 上传继续拒绝脚本、外链和嵌入图片，图片大小/类型校验保持。回退仅恢复本次 Flutter 与 SVG 改动，不回退/删除用户草稿。

## 验收记录

- 代码实现：代码已按规格接入；未验证。介绍画布无行数上限，灰色模板仅在空值时叠加，不参与保存；图片不显示 caption 但保留已有数据，最多 6 张，支持排序、布局和删除最后一张回空态。
- 源码审阅：覆盖 `market_skill_editor.dart` 与 `skill_presentation.dart` 的资料入口、介绍、图库、类型默认图标、上传、焦点及窄屏布局。审阅发现工具条窄屏风险后，已改为按可用宽度/文字缩放分成两行，关键操作保留至少 48dp，网格按宽度适配；后续源码复看未发现额外实质缺陷。旧技能详情图标已改用 `SkillPresentationIcon` 的真实 file-text。此结论仅为源码审阅。
- 自动化/静态检查：已编写相关测试，未运行；未执行 analyze、test、build、format 或运行应用。待用户覆盖直接入口、模板不保存、长文本滚动、0/1/6 图、排序/删除/布局、旧 caption 保留、三类默认与上传图标、焦点和窄屏。
- 同状态页面对照：未执行；未生成渲染图、截图或对比证据。后续证据仅放 `.codex-artifacts/supplement-info-2026-10-25/`。
- 真机：未执行验证，待用户真机验证。
- server deployment not needed：此次只改 Flutter 展示、交互与独立 SVG，不改变服务端/API/部署文件。
