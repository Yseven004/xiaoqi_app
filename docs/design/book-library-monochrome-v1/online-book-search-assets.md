# 网上找书图标

用户选中第三版「书架拾书」，并确认采用去掉红色书签带的版本。初稿来自本轮 Product Design 生成的第三张方案图，产物编号 `exec-265a07f3-ca38-45bc-bb1c-805dc0ede6c0`。设计用图由小七项目生成并确认。[确认稿](confirmed/online-book-search-icon-2026-11-21.png)

| 项目 | 规格 |
| --- | --- |
| 固定资产 | [online_book_search.svg](../../../assets/images/online_book_search.svg) |
| SVG 画布 | `viewBox="0 0 64 64"`，透明背景，无描边 |
| 图形 | 双藏蓝直立书脊与一册倾斜 15° 的金色书脊，米白标签和饰线 |
| 颜色 | 藏蓝 `#203158`，金色 `#C78E25`，米白 `#FDF1D4`，取样后以纯色表达 |
| 显示 | 内置插件列表图标槽 40 × 40 dp，SVG 34 × 34 dp |
| 状态 | 启用、禁用共用彩色图标，由右侧开关表达状态 |
| 消费组件 | 「我的 → 内置插件 → 网上找书」的列表项 |

2026-11-21 独立预览按 128 px 并排核对确认稿的轮廓、比例、倾斜、颜色和透明边界。在 34 px 小图标预览核对三册书脊可辨识。Flutter 实际页面视觉核验见本功能交付记录。

### 合并弹窗的现有图标

| 来源 | viewBox | 显示及状态 | 消费组件 |
| --- | --- | --- | --- |
| 主界面 [home_send_idle.svg](../../../assets/images/home_send_idle.svg) 和 [home_send_active.svg](../../../assets/images/home_send_active.svg) | `0 0 40 40` | 38 dp，灰色空输入／深色可发送 | 网上找书输入框 |
| 笔记编辑器 [sparkle.svg](../../../assets/icons/chat_note_editor/sparkle.svg) | `0 0 256 256` | 标题 27 dp，助手消息 20 dp，统一墨色 | 网上找书引导和助手气泡 |

主界面发送图标用已有实机图的 176 px 局部核对方向和轮廓，空输入和可发送 SVG 路径一致。星光使用现有线描资产。两处均引用原有 SVG，合并弹窗的实际页面视觉对照待验收。
