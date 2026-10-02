---
AIGC:
    Label: "1"
    ContentProducer: 001191110102MACQD9K64018705
    ProduceID: 1787134069975015_0/project_7649282351637463296-files/docs/AI笔记分析_最终任务规格_v2.md
    ReservedCode1: ""
    ContentPropagator: 001191110102MACQD9K64028705
    PropagateID: 1787134069975015#1781172677582
    ReservedCode2: ""
---
# 小七V1.0 AI笔记分析 — 最终任务规格（v2）

> 综合产品经理/技术架构师/UI设计师/QA规划师产出 | 2026-06-11 | P0
> v2更新：DeepSeek V4 Flash + 阿里云FC代理方案

---

## 项目背景

AI笔记分析是小七V1.0最复杂的功能——首次引入外部API调用，也是用户与小七关系从"工具使用"升级为"情感依赖"的转折点。用户写了东西，小七看了、想了、回答了，这个交互的体验质量直接决定用户是否产生"我愿意和它一起成长"的意愿。

---

## 前置约束

### 引用 project-insights.md
- §1.1 笔记保存后**不自动**调用 AI 分析，需用户手动点击"✨ 让小七看看"
- §1.2 笔记类型仅 `'text'`、`'photo'`、`'ai_generated'`，AI 生成笔记须设 `parent_note_id`
- §1.4 小七表情优先级：1烦躁 > 2困倦 > 3微笑 > 4思考 > 5常驻眨眼，触发后2分钟恢复
- §2 AI分析超时：显示"小七暂时走神了，稍后再试"，不自动重试
- §3 每日AI生成笔记次数限制5次（客户端计数）

### 引用 engineering-minimums.md
- 目录结构：config/ models/ services/ pages/ widgets/ utils/
- 命名：文件snake_case，类PascalCase，变量/方法camelCase，私有_开头
- 颜色/边距/字体必须从 config/ 引用，禁止硬编码
- 字符串用单引号
- async 函数必须 try-catch + 向用户显示友好提示
- 日志：`debugPrint('[XiaoQi] 模块名: 内容')`
- V1.0 只用 StatefulWidget + setState，禁止 provider/riverpod/bloc
- 数据库用 sqflite 单例，删除用软删除 is_deleted=1
- 禁止 print，禁止自动添加依赖，禁止 UI 中直接调用 API
- UI数值由设计师自由定义，背景色需从 AppColors 引用

### 已有基础
- Note model 已支持 type='ai_generated'
- DatabaseService 已有基础 CRUD
- 文字/拍照笔记详情页已有"✨ 让小七看看"按钮入口（仅传 note_id，AI逻辑未实现）
- AppColors：accent, onAccent, hint, disabled, background, card, textPrimary, textSecondary, error

---

## 外部基础设施（v2新增）

| 资源 | 平台 | 说明 | 成本 |
|------|------|------|------|
| 阿里云函数计算 FC | 阿里云 | API代理，Key存在FC环境变量中，App永远不接触Key | 免费额度每月100万次调用 |
| DeepSeek API | DeepSeek | AI分析能力，V4 Flash模型 | 输入¥1/百万tokens，输出¥2/百万tokens |

**请求链路**：
```
App（AiService）──→ 阿里云FC（云函数）──→ DeepSeek API
                        ↑
                  Key存在FC环境变量中
                  App中永远不出现Key
```

**FC代理部署要点**（Owner需完成）：
1. 注册阿里云账号 → 开通函数计算FC
2. 创建HTTP函数（Python/Node均可，约20行代码）
3. 代理逻辑：接收POST请求 → 读取环境变量中的DeepSeek Key → 转发到DeepSeek API → 返回结果
4. 配置环境变量 `DEEPSEEK_API_KEY`
5. 获取FC的HTTP触发器地址，填入App的 `api_config.dart`

**V2.0升级路径**：后续可为FC加鉴权（App端传设备指纹/用户标识，FC验证后才转发），防止代理被滥用。

---

## 任务1：AI分析服务层（AiService）

**优先级**：P0（核心能力，其他任务都依赖它）

### 用户故事
作为用户，我想要小七帮我分析笔记内容，提炼重点并给出学习建议，以便更深入地理解记录的知识。

### 新增文件
- `lib/config/api_config.dart` — FC代理端点 + 模型名 + 超时配置（**加入 .gitignore**，**不再存储API Key**）
- `lib/models/ai_analysis_result.dart` — 分析结果数据类
- `lib/services/ai_service.dart` — DeepSeek API 调用服务（经FC代理）

### AiService 设计

```
class AiService {
  static final AiService _instance = AiService._();
  factory AiService() => _instance;
  AiService._();

  final http.Client _client = http.Client();  // 复用连接

  /// 分析笔记内容，返回结构化分析结果
  Future<AiAnalysisResult> analyzeNote(Note note) async { ... }

  /// 获取今日已使用次数（委托 DatabaseService）
  Future<int> getTodayUsageCount() async { ... }

  /// 检查是否还有剩余次数
  Future<bool> canUseToday() async { ... }
}
```

### DeepSeek API 调用规范（v2更新）

**请求配置**：
- 端点：阿里云FC代理地址（从 `api_config.dart` 读取），**不再直连DeepSeek**
- 模型：`deepseek-v4-flash`（~~deepseek-chat~~）
- 超时：connectTimeout 10秒，readTimeout **15秒**（技术架构师建议，30秒用户体验太差）
- 温度：0.7（平衡创造力和准确性）
- API Key：**不存在客户端**，Key存在阿里云FC环境变量中

**api_config.dart 内容**（v2更新）：
```
// lib/config/api_config.dart
class ApiConfig {
  static const String baseUrl = 'https://你的FC触发器地址/api/chat';  // FC代理地址
  static const String model = 'deepseek-v4-flash';
  static const int connectTimeout = 10;  // 秒
  static const int readTimeout = 15;     // 秒
}
```

**Prompt 模板**：
```
你是一位学习助手"小七"，请分析以下学习笔记，输出结构化的分析结果。

笔记内容：
{note.content}

请按以下格式输出：
【知识提炼】
用3-5个要点总结笔记核心内容

【理解建议】
给出1-2条深入理解该知识的建议

【延伸方向】
推荐1-2个相关的延伸学习方向

要求：
- 语言简洁亲切，像一个聪明的朋友在跟你聊天
- 如果笔记内容很少或为空，温和地鼓励用户多记录
- 不要使用markdown格式，直接用纯文本
- 如果笔记内容是外语文本，先翻译再分析
- 每个板块内容控制在200字以内
```

### AiAnalysisResult 数据结构

```
class AiAnalysisResult {
  final String summary;      // 知识提炼
  final String suggestion;   // 理解建议
  final String extension;    // 延伸方向
  final String rawResponse;  // 原始响应（降级备用）
}
```

### 响应解析与降级策略

**一级解析**：从 `choices[0].message.content` 提取文本，按【知识提炼】【理解建议】【延伸方向】三个标记分割
**二级降级**：分割失败（AI输出格式不符），将 rawResponse 整体放入"知识提炼"板块，其他板块置空
**三级降级**：三个板块全空，返回特殊标记，UI显示"小七想了想，但没什么想说的..."

### 每日次数追踪

**新增数据库表 ai_usage**：

```sql
CREATE TABLE ai_usage (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id INTEGER NOT NULL,
  used_at TEXT NOT NULL,
  FOREIGN KEY (note_id) REFERENCES notes(id)
);
```

**DatabaseService 新增方法**：

| 方法 | 说明 |
|------|------|
| `insertAiUsage(int noteId)` | 记录一次 AI 使用 |
| `getTodayAiUsageCount()` | 获取今日已用次数 |

**计次时机**：AI调用**成功返回时**立即插入 ai_usage 记录（技术架构师确认：保存笔记失败不回退计次，因为AI调用已发生）

**计数SQL**：
```sql
SELECT COUNT(*) FROM ai_usage 
WHERE date(used_at) = date('now', 'localtime')
```
- 备选方案（如 sqflite 不支持 localtime）：Dart端计算今日0点的ISO字符串，传入SQL做字符串比较

### 内容截断
- 超过 4000 字符截断，截断位置在最后一个完整句号/问号/感叹号处
- 无标点的长文本，按 4000 字符硬截断

### 错误处理

| 场景 | 处理 |
|------|------|
| 网络超时（15s） | 抛出 TimeoutException，上层显示"小七暂时走神了，稍后再试" |
| API 返回错误（4xx/5xx） | 抛出 AiException，上层显示"小七暂时走神了，稍后再试" |
| FC代理不可用 | 同网络超时处理，显示"小七暂时走神了，稍后再试" |
| 响应解析失败 | 使用 rawResponse 降级显示 |
| 内容为空/null | 不调用 API，直接返回提示文案 |
| 内容全空格/换行 | 视为空内容，不调 API |

### 验收标准
- [ ] 通过FC代理调用DeepSeek API可正常返回分析结果
- [ ] 超时15秒后抛出异常，不卡死
- [ ] 返回结果解析为 AiAnalysisResult 结构
- [ ] 三级降级策略正常工作
- [ ] photo 笔记 OCR 为空时不调用 API，返回提示文案
- [ ] 内容为空/null/全空格时不调 API
- [ ] 超长内容截断至4000字符（在完整句子处）
- [ ] 每日使用次数正确计数和查询
- [ ] AI成功返回时计次，失败不计次
- [ ] 所有异常均 try-catch，无裸抛
- [ ] 客户端无API Key，Key仅存在FC环境变量
- [ ] api_config.dart 只存代理端点+模型名，不存Key
- [ ] 日志 `debugPrint('[XiaoQi] AiService: ...')`

### 边界条件与异常
- 笔记 content 为空 → 不调 API，返回"这条笔记还没有文字内容，小七看不了哦～"
- 笔记 content 全空格/换行 → 同上
- content 极长（5000+字）→ 截断至 4000 字
- API 返回格式不符 → 降级策略
- API 返回某板块为空 → 对应字段为空字符串，UI 层隐藏
- API 返回三个板块全空 → 特殊标记
- 并发调用（极端）→ 每次调用独立
- 跨日计数 → 查询按当天日期过滤
- FC代理不可用 → 同网络超时处理
- FC冷启动延迟 → 首次请求可能多1-2秒，在15秒超时内可接受

### 技术约束
- 只用 StatefulWidget + setState
- HTTP 调用封装在 service 层，UI 层不直接调 API
- API Key 不存在客户端，经阿里云FC代理转发
- api_config.dart 只存代理端点+模型名+超时，加入 .gitignore
- 新增依赖 `http ^1.2.0`（需先确认项目是否已有 dio，有则复用 dio）
- 日志 `debugPrint('[XiaoQi] AiService: ...')`
- async 必须 try-catch

### 不做什么
- 不做流式响应（V1.0 一次性返回）
- 不做多轮对话式分析
- 不做分析结果缓存（每次点击都重新分析）
- 不做自定义 Prompt

---

## 任务2："让小七看看"按钮完整交互流程

**优先级**：P0（连接用户操作和AI服务的核心交互）

### 用户故事
作为用户，我想要在查看笔记时点击"让小七看看"按钮，看到分析过程和结果，以便获得学习洞察。

### 新增文件
- `lib/widgets/ai_analyze_button.dart` — 可复用的AI分析按钮组件

### 用户交互流程

```
点击"✨ 让小七看看"
    │
    ├─ 检查笔记内容 ──→ 内容为空 → toast "这条笔记还没有文字内容，小七看不了哦～"
    │                                     按钮不禁用（外观仍可用）
    │
    ├─ 检查每日次数 ──→ 超限(≥5) → 按钮变超限态
    │                              "✨ 小七看累了" + disabled色
    │
    └─ 进入分析流程
        │
        ├─ 按钮变为 loading 态（disabled色 + 转圈 + 动态文案）
        │   0-2s: "小七正在看..." + 小七微笑表情
        │   2-6s: "小七正在想..." + 小七思考表情
        │   6s+:  "快好了..."     + 小七思考表情
        │
        ├─ 调用 AiService.analyzeNote()
        │
        ├─ 成功 → 按钮微闪(200ms) → "✓ 小七看完了"(400ms) → 右滑进入结果展示页
        │         + 计次+1 + onAnalysisComplete回调
        │
        └─ 失败 → 按钮恢复可用态(300ms) → 小七切困倦表情 → toast "小七暂时走神了，稍后再试"
                  按钮可再次点击（不计数）
```

### AiAnalyzeButton 组件规格

```dart
class AiAnalyzeButton extends StatefulWidget {
  final Note note;
  final VoidCallback onAnalysisComplete;
  const AiAnalyzeButton({
    required this.note,
    required this.onAnalysisComplete,
  });
}
```

**按钮状态**：

| 状态 | 背景色 | 文案 | 文字色 | 可点击 |
|------|--------|------|--------|--------|
| 可用态 | AppColors.accent | "✨ 让小七看看" | AppColors.onAccent, 16sp | ✅ |
| 加载态 | AppColors.disabled | 动态文案 | AppColors.hint, 14sp | ❌ |
| 超限态 | AppColors.disabled | "✨ 小七看累了" | AppColors.hint, 14sp | ❌ |

**按钮通用属性**：高48px, 圆角24px

**动效规格**：

| 动效 | 时长 | 曲线 | 说明 |
|------|------|------|------|
| 首次出现发光 | 800ms | easeInOut | boxShadow blurRadius: 8→16→8，仅执行一次 |
| 按下缩放 | 100ms | easeIn | scale: 1.0→0.95 |
| 加载文案切换 | 300ms | easeOut | opacity渐变，不硬切 |
| 成功微闪 | 200ms | easeInOut | accent色亮度脉冲 |
| "小七看完了"提示 | 400ms | easeOut | opacity: 0→1→0 |

**加载态文字动态变化**：
- 0-2s："小七正在看..." + CircularProgressIndicator(strokeWidth: 2) + 小七微笑表情
- 2-6s："小七正在想..." + 小七思考表情（文案切换用 opacity 渐变，不硬切）
- 6s+："快好了..." + 小七思考表情

### 页面退出处理
- http 包无原生 CancelToken，页面 dispose 时检查 `mounted` 状态
- 回调中 `if (!mounted) return;` 防止 setState 报错

### 涉及页面
- `text_note_detail_page.dart` — 文字笔记详情页
- `photo_note_detail_page.dart` — 拍照笔记详情页
- 两个详情页共用 AiAnalyzeButton 组件

### 验收标准
- [ ] 4种按钮状态视觉正确（可用/加载/超限/内容为空）
- [ ] Loading 态显示动态文案+转圈，按钮不可重复点击
- [ ] 加载文案按时段切换（看→想→快好了），opacity渐变
- [ ] 分析成功→微闪→"看完了"→右滑进入结果页
- [ ] 分析超时(15s)→按钮恢复可用→困倦表情→toast"走神了"
- [ ] 其他错误→按钮恢复可用→toast"走神了"
- [ ] 内容为空时点击→toast提示，按钮不禁用
- [ ] 每日5次超限后按钮变超限态
- [ ] 第5次分析成功后按钮立即变超限态
- [ ] 文字/拍照笔记详情页共用同一组件，交互一致
- [ ] 分析成功触发 onAnalysisComplete 回调
- [ ] 分析中退出页面→检查mounted→不崩溃

### 边界条件与异常
- 快速连续点击 → loading 态防重复
- 分析过程中退出页面 → mounted 检查，不崩溃
- 从结果页返回 → 详情页状态正常
- 第5次分析成功后 → 按钮立即变超限态
- 次日零点后 → 按钮恢复可用态

### 技术约束
- StatefulWidget 自管理 loading/disabled/normal/exhausted 状态
- API 调用走 AiService → FC代理 → DeepSeek，UI 不直接调
- http 包回调中检查 mounted
- async 必须 try-catch
- 日志 `debugPrint('[XiaoQi] AiAnalyzeBtn: ...')`

### 不做什么
- 不做分析进度百分比
- 不做取消分析功能（V1.0 15秒超时自动结束）

---

## 任务3：AI分析结果展示页

**优先级**：P0（AI分析的核心交付体验）

### 用户故事
作为用户，我想要看到小七对我笔记的分析结果，包括知识提炼、理解建议和延伸方向，以便获得学习洞察。

### 新增文件
- `lib/pages/ai_analysis_result_page.dart` — 分析结果展示页

### 页面布局

```
页面背景：AppColors.background

┌─────────────────────────────────────┐
│  ← 小七的分析                  ···  │  AppBar, elevation=0
├─────────────────────────────────────┤
│                                     │
│         ✨ (32sp)                    │  进入时旋转2π
│   "小七看了你的笔记"                 │  18sp, w500, AppColors.textSecondary
│                                     │
│  🧠 知识提炼                        │  18sp, w600, AppColors.textPrimary
│  ─────────────────────────────      │
│  提炼内容...                        │  15sp, w400, AppColors.textSecondary
│                                     │
│  💡 理解建议                        │  18sp, w600, AppColors.textPrimary
│  ─────────────────────────────      │
│  建议内容...                        │  15sp, w400, AppColors.textSecondary
│                                     │
│  🔗 延伸方向                        │  18sp, w600, AppColors.textPrimary
│  ─────────────────────────────      │
│  方向内容...                        │  15sp, w400, AppColors.textSecondary
│                                     │
├─────────────────────────────────────┤
│  [  保存为笔记  ]                   │  高48px, 圆角24px
│                                     16sp, AppColors.onAccent
│                                     AppColors.accent背景
│                                     左右边距20px, 底部24px
└─────────────────────────────────────┘
```

### 进入动画序列

```
0ms → 200ms → 400ms → 550ms → 700ms → 900ms
│       │       │       │       │       │
页面    ✨出现  板块1   板块2   板块3   保存按钮
滑入    旋转2π  渐现    +150ms  +150ms  +200ms
        600ms   400ms   stagger stagger
```

- 页面进入后200ms，顶部出现大号 ✨ emoji（32sp），做一次旋转动画（0→2π, 600ms, easeInOut）
- 三个板块依次渐现（opacity 0→1, 400ms each, stagger 150ms）
- 保存按钮在最后一个板块出现后200ms渐现

### 板块间距
- 板块之间 24px
- 板块内标题与内容 12px
- 分割线 1px, AppColors.disabled

### 板块降级逻辑
- AI返回某板块为空字符串 → 该板块整个隐藏（含标题+分割线+内容），不留空白
- 三个板块全空 → 中央显示"小七想了想，但没什么想说的..."，14sp, AppColors.hint

### "保存为笔记"操作

```
点击"保存为笔记"
    │
    ├─ 构建 Note 对象
    │   type = 'ai_generated'
    │   title = '小七的分析：{原笔记标题 或 "未命名笔记"}'
    │   content = 格式化后的分析全文
    │   parent_note_id = 原笔记 id
    │   book_name = 继承原笔记的 book_name
    │   book_page = 继承原笔记的 book_page
    │   photo_path = null
    │
    ├─ DatabaseService.insert()
    │
    └─ 保存成功 → "✓ 已保存"(400ms) → toast"已保存为笔记" → 返回原笔记详情页
    保存失败 → toast"保存失败，请重试"，留在结果页
```

**分析全文格式化规则**：
```
🧠 知识提炼
{summary}

💡 理解建议
{suggestion}

🔗 延伸方向
{extension}
```

### 验收标准
- [ ] 三个板块正确展示，内容与AI返回一致
- [ ] 进入动画序列流畅（✨旋转→三板块stagger渐现→保存按钮）
- [ ] 某板块为空时隐藏，不留空白
- [ ] 三板块全空时显示"小七想了想，但没什么想说的..."
- [ ] 内容可滚动查看
- [ ] "保存为笔记"按钮可点击
- [ ] 保存成功 → type='ai_generated'，parent_note_id 正确
- [ ] 保存成功 → title 格式为"小七的分析：{原标题}"
- [ ] 保存成功 → book_name/book_page 继承原笔记
- [ ] 保存成功 → "✓ 已保存"反馈 → 返回原笔记详情页
- [ ] 保存失败 → toast + 留在结果页
- [ ] 按返回键 → 返回原笔记详情页，不自动保存

### 边界条件与异常
- 分析结果某板块为空 → 该板块隐藏
- 三板块全空 → 兜底文案
- 分析结果极长 → 页面可滚动
- 保存时原笔记已被删除 → 仍保存，parent_note_id 保留
- 重复保存 → 允许，每次生成新的 ai_generated 笔记
- 原笔记标题为空 → title 为"小七的分析：未命名笔记"

### 技术约束
- 接收 `AiAnalysisResult` + `Note originalNote` 作为参数
- 颜色从 AppColors 引用
- async 必须 try-catch
- 日志 `debugPrint('[XiaoQi] AiResult: ...')`

### 不做什么
- 不做分析结果编辑
- 不做分析结果分享
- 不做多个历史分析结果对比

---

## 任务4：AI生成笔记列表展示与详情

**优先级**：P0（补全笔记类型的完整展示闭环）

### 用户故事
作为用户，我想要在笔记列表中看到AI分析生成的笔记，并能查看其内容和它关联的原笔记，以便回顾小七的分析。

### 新增文件
- `lib/widgets/ai_note_card.dart` — ai_generated 类型卡片组件
- `lib/pages/ai_note_detail_page.dart` — AI生成笔记详情页

### AI笔记卡片设计

```
┌─┬──────────────────────────────────┐
│ │  ✨ 小七的分析：笔记标题          │  16sp, w600, AppColors.textPrimary, 1行截断
│ │  知识提炼摘要知识提炼摘要...      │  14sp, w400, AppColors.textSecondary, 2行截断
│ │  摘要第二行...                   │
│ │  🕐 2分钟前                      │  12sp, AppColors.hint
└─┴──────────────────────────────────┘
  ↑
  4px宽, AppColors.accent, 左侧圆角16px, 右侧0

卡片: AppColors.card, 圆角16px, 内边距16px, 最小高度72px
```

- 卡片左边缘 4px accent 色条，标识AI生成（Container方案：外层Row，左侧Container(width:4, color:accent)，右侧内容Column）
- 标题前缀"✨ 小七的分析："，加粗
- 内容取分析全文前2行截断
- 按下效果：scale(1.0→0.98, 100ms) → scale(0.98→1.0, 150ms)

### AI笔记详情页

```
页面背景：AppColors.background

┌─────────────────────────────────────┐
│  ← 小七的分析              ···      │  AppBar, elevation=0
├─────────────────────────────────────┤
│                                     │
│  分析内容全文                       │  16sp, w400, 行高1.6
│  保留换行的完整文本                 │  AppColors.textPrimary
│  ...                                │  左右边距20px
│                                     │
│  ─────────────────────────────      │  分割线, 1px, AppColors.disabled
│                                     │
│  📎 关联原笔记                      │  13sp
│     原笔记标题                      │  AppColors.accent色，可点击跳转
│                                     │
│  🕐 分析时间                        │  13sp, AppColors.hint
│                                     │
├─────────────────────────────────────┤
│  [  重新分析  ]                     │  高48px, 圆角24px
│                                     16sp, AppColors.accent
│                                     描边1.5px AppColors.accent
│                                     背景透明
│                                     左右边距20px, 底部24px
└─────────────────────────────────────┘
```

### 关联原笔记

| 状态 | 视觉 | 交互 |
|------|------|------|
| 原笔记存在 | 📎 + 原笔记标题，AppColors.accent色 | 可点击，跳转原笔记详情页 |
| 原笔记已软删除 | 📎 + "原笔记已删除"，AppColors.hint色 | 不可点击 |
| parent_note_id 为空 | 整个关联区域隐藏 | — |

查询逻辑：initState 时根据 parent_note_id 查询，加 `is_deleted = 0` 条件判断原笔记是否存在。

### "重新分析"按钮

- **描边而非填充**——与"让小七看看"填充按钮区分：填充=首次（主行动），描边=再次（次要行动）
- 点击后对原笔记重新调用 AI 分析
- 复用 AiService.analyzeNote() 逻辑（技术架构师建议：抽取为公开方法）
- 重新分析会生成新的 ai_generated 笔记，不覆盖旧的
- 受每日5次限制

### 更多操作菜单（···）
- 仅"🗑️ 删除"，无"编辑"（AI生成笔记不可编辑）
- 删除确认弹窗："确定删除这条分析吗？删除后无法恢复"
- 确认按钮 AppColors.error 色
- 执行软删除 is_deleted=1

### 统一分发逻辑
复用/扩展 `NoteCard` Widget，内部按 `note.type` 分发：
- type='text' → TextNoteCard
- type='photo' → PhotoNoteCard（已有）
- type='ai_generated' → AiNoteCard

三种卡片统一最小高度 72px。

### 验收标准
- [ ] AI笔记在列表中显示为带左侧4px accent色条的卡片
- [ ] 卡片标题前缀"✨ 小七的分析："，1行截断
- [ ] 卡片内容2行截断，14sp
- [ ] 点击卡片跳转AI笔记详情页
- [ ] 详情页完整展示分析内容全文，保留换行
- [ ] 关联原笔记可点击跳转（accent色）
- [ ] 原笔记已删除时显示"原笔记已删除"（hint色），不可点击
- [ ] 无parent_note_id时不显示关联区域
- [ ] "重新分析"描边按钮功能正常，受每日5次限制
- [ ] 重新分析生成新笔记，不覆盖旧的
- [ ] 删除菜单→确认弹窗→软删除→返回列表
- [ ] 三种笔记类型在列表中共存，各自卡片样式正确

### 边界条件与异常
- 原笔记被删除 → 关联区域灰显"原笔记已删除"
- parent_note_id 为空 → 不显示关联区域
- 重新分析超限 → 同每日5次限制规则
- 同一原笔记多次分析 → 多条 ai_generated 笔记独立存在
- AI笔记卡片内容极长 → 摘要2行截断

### 技术约束
- 卡片左侧色条用 Container(width:4, color:AppColors.accent) 方案
- 关联原笔记查询加 is_deleted=0 条件
- ListView.builder 懒加载
- 颜色从 AppColors 引用
- 软删除 is_deleted=1
- 日志 `debugPrint('[XiaoQi] AiNote: ...')`

### 不做什么
- 不做 AI 笔记编辑
- 不做分析历史对比
- 不做分析结果导出

---

## 任务5：每日AI使用次数管理

**优先级**：P0（资源管控，防止滥用和超额成本）

### 用户故事
作为用户，我想要知道今天还能让小七分析几次笔记，以便合理安排使用。

### 新增文件
- `lib/widgets/ai_usage_indicator.dart` — 轻量次数指示器（StatelessWidget，数据来自父组件）

### 次数指示器规格

位置：AiAnalyzeButton 下方，距按钮底部 8px，居中对齐

| 状态 | 文案 | 颜色 | 字号 |
|------|------|------|------|
| 正常（剩余≥2） | "已用 X/5 次" | AppColors.hint | 12sp |
| 最后1次 | "还剩 1 次" | AppColors.error（红色） | 12sp |
| 用完 | "今日已用完" | AppColors.hint | 12sp |

### 次数变化动画

| 动效 | 时长 | 曲线 | 说明 |
|------|------|------|------|
| 次数+1 bounce | 200ms | easeInOut | scale: 1.0→1.1→1.0 |
| 最后1次变色 | 300ms | easeOut | hint→error 渐变 |
| 最后1次闪烁 | 400ms | easeInOut | opacity: 1→0.6→1 |

### 次数管理逻辑

| 场景 | 行为 |
|------|------|
| 当天第1-4次 | 正常分析，按钮可用 |
| 当天第5次 | 正常分析，分析完成后按钮变为超限态 |
| 当天第6次尝试 | 按钮置灰，不可点击 |
| 分析失败 | 不计数，指示器不变 |
| 保存失败 | 计数不回退（AI调用已发生） |
| 次日零点 | 计数自动重置（查询按日期过滤，无需清表） |

### 与AiAnalyzeButton的集成
- 按钮组件初始化时从数据库查询今日已用次数
- 每次分析成功后本地 +1（setState），不每次查库
- 每次进入详情页重新从数据库查询初始值

### 验收标准
- [ ] 按钮下方显示次数指示器
- [ ] 正常态显示"已用 X/5 次"
- [ ] 剩余1次时变为"还剩 1 次"，error色
- [ ] 用完后显示"今日已用完"，hint色
- [ ] 次数+1时做 scale bounce 动画
- [ ] 最后1次变色+闪烁动画
- [ ] 第5次分析成功后按钮立即变超限态
- [ ] 次日零点后计数自动重置
- [ ] 重新进入详情页从数据库重新查询
- [ ] 分析失败不计数
- [ ] 文字/拍照笔记详情页均显示

### 边界条件与异常
- 跨午夜使用 → 查询自动按新日期过滤
- 分析失败（未成功）→ 不计数
- 保存为笔记失败 → 不回退计数
- 本地计数与数据库不一致 → 每次进入详情页从数据库重新查询
- ai_usage 表数据堆积 → V1.0不清理，后续版本处理

### 技术约束
- AiUsageIndicator 为 StatelessWidget（数据来自父组件 setState）
- 计数存储在 ai_usage 表
- 查询按日期过滤，无需定时任务清表
- 颜色从 AppColors 引用
- 日志 `debugPrint('[XiaoQi] AiUsage: ...')`

### 不做什么
- 不做付费解锁更多次数
- 不做次数购买
- 不做历史用量统计面板
- 不做定期清理历史数据

---

## 执行顺序

```
任务1（AiService + 数据库）─→ 任务2（AiAnalyzeButton）─→ 任务3（结果展示页）─→ 任务4（列表+详情）
                                                             │
                                        任务5（次数指示器）───┘（可在任务2-4期间并行）
```

---

## 目录结构新增汇总

```
lib/
├── config/
│   ├── colors.dart              （已有，无需新增色值）
│   └── api_config.dart          （新增：任务1，FC代理端点+模型名+超时配置，加入 .gitignore）
├── models/
│   ├── note.dart                （已有，确认 ai_generated 类型支持完整）
│   └── ai_analysis_result.dart  （新增：任务1，分析结果数据类）
├── services/
│   ├── ai_service.dart          （新增：任务1+5，DeepSeek API（经FC代理）+ 次数查询）
│   └── database_service.dart    （修改：新增 ai_usage 表 + 2个方法）
├── pages/
│   ├── ai_analysis_result_page.dart  （新增：任务3）
│   └── ai_note_detail_page.dart      （新增：任务4）
├── widgets/
│   ├── ai_analyze_button.dart        （新增：任务2，公用分析按钮）
│   ├── ai_note_card.dart             （新增：任务4）
│   └── ai_usage_indicator.dart       （新增：任务5）
└── utils/
```

## 新增依赖

| 依赖 | 用途 | 版本建议 | 说明 |
|------|------|---------|------|
| http | 调用FC代理 → DeepSeek API | ^1.2.0 | 需先确认项目是否已有 dio，有则复用 dio |

## 新增数据库表

```sql
CREATE TABLE ai_usage (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id INTEGER NOT NULL,
  used_at TEXT NOT NULL,
  FOREIGN KEY (note_id) REFERENCES notes(id)
);
```

数据库版本号 +1，在 onCreate/onUpgrade 中创建。

## 外部基础设施（v2新增）

| 资源 | 平台 | 说明 | 成本 |
|------|------|------|------|
| 阿里云函数计算 FC | 阿里云 | API代理，Key存在FC环境变量中 | 免费额度每月100万次调用 |
| DeepSeek API | DeepSeek | AI分析能力，V4 Flash模型 | 输入¥1/百万tokens，输出¥2/百万tokens |

## AppColors 引用清单

**本次无新增色值**，全部复用已有和建议新增的：

| 命名 | 用途 |
|------|------|
| AppColors.accent | 按钮/色条/关联原笔记/描边按钮 |
| AppColors.onAccent | 按钮文字 |
| AppColors.background | 页面背景 |
| AppColors.card | 卡片背景 |
| AppColors.hint | 加载文字/超限文字/次数指示/时间/原笔记已删除 |
| AppColors.disabled | 加载态按钮背景/分割线 |
| AppColors.textPrimary | 板块标题/分析内容/卡片标题 |
| AppColors.textSecondary | 板块内容/卡片摘要 |
| AppColors.error | 最后1次次数指示/删除确认按钮 |

## 关键文案清单

| 场景 | 文案 | 来源 |
|------|------|------|
| 按钮可用态 | "✨ 让小七看看" | 产品经理 |
| 按钮加载态-0~2s | "小七正在看..." | UI设计师 |
| 按钮加载态-2~6s | "小七正在想..." | UI设计师 |
| 按钮加载态-6s+ | "快好了..." | UI设计师 |
| 按钮超限态 | "✨ 小七看累了" | 产品经理 |
| AI超时 | "小七暂时走神了，稍后再试" | project-insights §2 |
| AI其他错误 | "小七暂时走神了，稍后再试" | project-insights §2 |
| 内容为空 | "这条笔记还没有文字内容，小七看不了哦～" | 产品经理 |
| 分析成功确认 | "✓ 小七看完了" | UI设计师 |
| 保存成功 | "✓ 已保存" → toast"已保存为笔记" | UI设计师 |
| 保存失败 | "保存失败，请重试" | 产品经理 |
| AI笔记标题前缀 | "小七的分析：" | 产品经理 |
| 关联原笔记 | "📎 关联原笔记" | 产品经理 |
| 原笔记已删除 | "📎 原笔记已删除" | 产品经理 |
| 结果页全空 | "小七想了想，但没什么想说的..." | UI设计师 |
| 板块标题 | "🧠 知识提炼" / "💡 理解建议" / "🔗 延伸方向" | 产品经理 |
| 重新分析按钮 | "重新分析" | 产品经理 |
| 删除确认 | "确定删除这条分析吗？删除后无法恢复" | 产品经理 |
| 次数指示-正常 | "已用 X/5 次" | 产品经理 |
| 次数指示-最后1次 | "还剩 1 次" | 产品经理 |
| 次数指示-用完 | "今日已用完" | 产品经理 |

## 动效规格汇总

| 动效 | 时长 | 曲线 | 属性变化 | 应用场景 |
|------|------|------|---------|---------|
| 按钮首次发光 | 800ms | easeInOut | boxShadow blurRadius: 8→16→8 | 详情页首次加载 |
| 按钮按下 | 100ms | easeIn | scale: 1.0→0.95 | 点击 |
| 加载文案切换 | 300ms | easeOut | opacity: 0→1 | 文案变化 |
| 成功微闪 | 200ms | easeInOut | accent亮度脉冲 | 分析成功 |
| "小七看完了"提示 | 400ms | easeOut | opacity: 0→1→0 | 成功确认 |
| ✨ 旋转进入 | 600ms | easeInOut | rotation: 0→2π | 结果页进入 |
| 板块渐现 | 400ms each | easeOut | opacity: 0→1, stagger 150ms | 三板块依次出现 |
| 保存按钮渐现 | 400ms | easeOut | opacity: 0→1 | 最后出现 |
| 卡片按下 | 100ms | easeIn | scale: 1.0→0.98 | 列表卡片 |
| 卡片回弹 | 150ms | easeOut | scale: 0.98→1.0 | 列表卡片 |
| 次数bounce | 200ms | easeInOut | scale: 1.0→1.1→1.0 | 次数+1 |
| 次数闪烁 | 400ms | easeInOut | opacity: 1→0.6→1 | 最后1次警告 |
| 次数变色 | 300ms | easeOut | hint→error | 最后1次 |

## 技术约束校验清单

| 约束 | 校验 |
|------|------|
| 只用 StatefulWidget + setState | ✅ |
| 数据库操作在 DatabaseService 单例 | ✅ ai_usage 表操作在单例中 |
| 软删除 is_deleted=1 | ✅ AI笔记删除走软删除 |
| 颜色从 config/ 引用 | ✅ 全部 AppColors.xxx |
| async 必须 try-catch | ✅ AiService 所有方法均有try-catch |
| 日志 debugPrint('[XiaoQi] 模块名: 内容') | ✅ |
| 不自动触发AI分析 | ✅ 仅手动点击"让小七看看" |
| 笔记类型仅三种 | ✅ ai_generated 类型 |
| 禁止 print | ✅ 全部使用 debugPrint |
| 禁止UI直接调API | ✅ 通过 AiService → FC代理 → DeepSeek |
| 禁止自动添加依赖 | ⚠️ 需先确认 http/dio 是否已有 |
| API Key 禁止硬编码 | ✅ Key存在FC环境变量，App中无Key |
| 字符串用单引号 | ✅ |
| 文件名snake_case | ✅ |

## v1→v2 变更记录

| 变更项 | v1 | v2 |
|--------|----|----|
| AI模型 | deepseek-chat | deepseek-v4-flash |
| API端点 | 直连 api.deepseek.com | 阿里云FC代理地址 |
| API Key存储 | api_config.dart（加入.gitignore） | **不存在客户端**，存在FC环境变量 |
| api_config.dart内容 | API Key常量 | FC代理端点URL + 模型名 + 超时配置 |
| 新增基础设施 | 无 | 阿里云函数计算FC |
| 错误处理 | 无FC相关 | 新增FC不可用/冷启动场景 |

---

> 本内容由 Coze AI 生成，请遵循相关法律法规及《人工智能生成合成内容标识办法》使用与传播。
