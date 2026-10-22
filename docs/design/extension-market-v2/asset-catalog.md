# 扩展市场 V2 · 资产清单

日期：2026-10-22。范围：`prototype/`。插件 / MCP / 技能三张详情方向图已获用户确认；HTML、矢量重建素材及其实际显示效果仍待用户手动验收。市场既有资产继续作为设计候选，未冻结为正式 Flutter 资产。

## 参考与验收边界

- 原始市场参考为用户提供的截图与视频，文件列表及原始路径见 [README](README.md#原始参考)。仅用于结构、比例与交互参考，不在运行时加载。
- 已确认生成方向图：[插件](approved-details/plugin-approved.png)、[MCP](approved-details/mcp-approved.png)、[技能](approved-details/skill-approved.png)。这些 PNG 仅作视觉目标，不充当页面背景、图标或按钮素材。
- 品牌独立预览：[assets.html](prototype/public/assets.html)，图形为 64×64。详情独立资产表：[detail-assets.png](prototype/.impeccable/review/detail-assets.png)，图标为 64×64，案例图为 220×300；该表已打开并检查。它是矢量资产栅格预览，不是浏览器 UI 截图。
- 用户选择自行查看：未执行浏览器 / 设备渲染验收，不声称与方向图像素一致。以下记录源码与资产本身，不代表资产逐项获批。

## 品牌 SVG

生成入口：[prepare-icons.mjs](prototype/scripts/prepare-icons.mjs)。主来源为本地安装的 **Simple Icons 16.35.0**；集合采用 [CC0-1.0](https://github.com/simple-icons/simple-icons/blob/16.35.0/LICENSE.md)，各品牌来源、指南与商标条件仍按项目 metadata 记录，集合许可不等于获得品牌背书或商标授权。Slack / Canva 在当前包中缺失，使用官方仓库 **13.21.0** 标签的原始 SVG。

所有文件都是独立路径 SVG，不包含位图 `<image>`：`viewBox="0 0 24 24"`。由 `src/ui.jsx` 的 **Brand** 消费；常规图形 28×28 / 框 40×40，普通 large 图形 44×44 / 框 66×66。插件 / MCP 详情身份区覆盖为 54×54 / 框 82×82，窄容器恢复 44×44 / 66×66；示例条为 27×27，手机隐藏。

| 资产 | 独立 SVG 路径 | 源填充色 | 原始品牌来源 / 分发来源 |
| --- | --- | --- | --- |
| GitHub | [github.svg](prototype/public/icons/github.svg) | `#181717` | [GitHub logos](https://github.com/logos)，Simple Icons 16.35.0 |
| Google Drive | [googledrive.svg](prototype/public/icons/googledrive.svg) | `#4285F4` | [Drive branding](https://developers.google.com/drive/web/branding)，16.35.0 |
| Notion | [notion.svg](prototype/public/icons/notion.svg) | `#000000` | [Notion](https://www.notion.so)，16.35.0 |
| Supabase | [supabase.svg](prototype/public/icons/supabase.svg) | `#3FCF8E` | [原始 SVG](https://github.com/supabase/supabase/blob/4031a7549f5d46da7bc79c01d56be4177dc7c114/packages/common/assets/images/supabase-logo-wordmark--light.svg)，16.35.0 |
| Figma | [figma.svg](prototype/public/icons/figma.svg) | `#F24E1E` | [Figma brand](https://www.figma.com/using-the-figma-brand/)，16.35.0 |
| Slack | [slack.svg](prototype/public/icons/slack.svg) | `#4A154B` | [Simple Icons 13.21.0 原图](https://raw.githubusercontent.com/simple-icons/simple-icons/13.21.0/icons/slack.svg) |
| Canva | [canva.svg](prototype/public/icons/canva.svg) | `#00C4CC` | [Simple Icons 13.21.0 原图](https://raw.githubusercontent.com/simple-icons/simple-icons/13.21.0/icons/canva.svg) |
| Linear | [linear.svg](prototype/public/icons/linear.svg) | `#5E6AD2` | [Linear](https://linear.app)，16.35.0 |
| Airtable | [airtable.svg](prototype/public/icons/airtable.svg) | `#18BFFF` | [Airtable newsroom](https://airtable.com/newsroom)，16.35.0 |
| Vercel | [vercel.svg](prototype/public/icons/vercel.svg) | `#000000` | [Vercel brands](https://vercel.com/geist/brands)，16.35.0 |
| Dropbox | [dropbox.svg](prototype/public/icons/dropbox.svg) | `#0061FF` | [Dropbox branding](https://www.dropbox.com/branding)，16.35.0 |
| Todoist | [todoist.svg](prototype/public/icons/todoist.svg) | `#E44332` | [Doist press](https://doist.com/press)，16.35.0 |
| Shopify | [shopify.svg](prototype/public/icons/shopify.svg) | `#7AB55C` | [Shopify brand assets](https://www.shopify.com/brand-assets)，16.35.0 |

状态映射：默认 / 悬停 / 已安装 / 未安装使用同一品牌 SVG，状态通过外层按钮、更多菜单及文本体现；不重新着色品牌图形。安装、连接失败等业务状态不另造品牌徽标。

## 详情与通用标记 SVG

来源为 [Phosphor React 2.1.10](https://www.npmjs.com/package/@phosphor-icons/react/v/2.1.10)，[MIT](https://github.com/phosphor-icons/react/blob/master/LICENSE)。[prepare-detail-icons.mjs](prototype/scripts/prepare-detail-icons.mjs) 原样导出 regular 路径，共 23 个独立 SVG；不是凭截图重画图标。以下路径均位于 `prototype/public/icons/detail/`，`viewBox="0 0 256 256"`、原生宽高 64×64。

| 文件 | 原始导出 | 当前显示尺寸 / 消费位置 |
| --- | --- | --- |
| `back.svg` | ArrowLeft | 24；技能返回，DetailIcon |
| `arrow-right.svg` | ArrowRight | 20；使用示例末端 |
| `caret-right.svg` | CaretRight | 16；插件面包屑 |
| `caret-up.svg` | CaretUp | 18；介绍展开 / 收起 |
| `dots.svg` | DotsThree | 25；MoreMenu |
| `plus.svg` | Plus | 20；安装按钮 |
| `chat.svg` | ChatCircle | 20；聊天试用按钮 |
| `gear.svg` | GearSix | 20；管理按钮 |
| `link.svg` | LinkSimple | 22；复制链接菜单 |
| `trash-danger.svg` | Trash | 22；卸载菜单 |
| `external.svg` | ArrowSquareOut | 19；网站 / 隐私政策链接 |
| `file-text.svg` | FileText | 22；能力行；Brand 通用技能标记为 25 / 35 |
| `folder.svg` | Folder | 22；能力行 |
| `chat-dots.svg` | ChatDots | 22；能力行 |
| `table.svg` | Table | 22；能力行 |
| `presentation.svg` | Presentation | 22；能力行 |
| `database.svg` | Database | 22；能力行 |
| `search.svg` | MagnifyingGlass | 22；能力行 |
| `code.svg` | Code | 22；能力行 |
| `research.svg` | FileMagnifyingGlass | 58 / 手机 42；技能身份标记 |
| `edit.svg` | NotePencil | 22；个人技能编辑菜单 |
| `book.svg` | BookOpen | 25 / 35；Brand 阅读标记 |
| `plugs.svg` | PlugsConnected | 25 / 35；Brand 通用插件 / MCP 标记 |

状态映射：默认填充 `#191919`，`trash-danger.svg` 为 `#a52b25`。主按钮的 DetailIcon 使用 CSS 反色形成浅色图形（当前约 `#e6e6e6`）；展开箭头在收起时旋转 180°；禁用沿用外层按钮透明度。Brand 通用标记仍在 40 / 66 px 框中，详情身份区使用相同的 82 / 66 px 覆盖尺寸。

市场搜索、添加菜单、清除、空状态等处仍直接使用 `@phosphor-icons/react` 的 React 图标；这些是库候选，未全部抽取、冻结或接入 Flutter。23 个已导出文件也仅代表本次 HTML 有独立矢量来源，不代表正式端验收完成。

## 论文案例矢量预览

源自已确认技能方向图中的报告案例构图，在页面外重建为独立 SVG；没有嵌入原 PNG。项目内重建，未引入第三方图库素材，未另设素材许可证。

| 文件 | viewBox / 固有尺寸 | 消费组件 / 显示 |
| --- | --- | --- |
| [research-question.svg](prototype/public/previews/research-question.svg) | `0 0 220 300` / 220×300 | SkillDetail 案例与案例预览对话框 |
| [research-method.svg](prototype/public/previews/research-method.svg) | `0 0 220 300` / 220×300 | 同上 |
| [research-limits.svg](prototype/public/previews/research-limits.svg) | `0 0 220 300` / 220×300 | 同上 |

平板案例图随三列容器缩放，比例 220:300；手机为约 100×114 px 的顶部裁切预览；对话框最大宽度 270 px、保持原比例。默认与悬停复用同一 SVG，仅外层浅灰容器变色。独立预览以原生 220×300 检查，实际 UI 的裁切、文字可读性与对齐待用户验收。
