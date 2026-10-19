# 小栖附件处理：成熟开源工作流复用方案

调研日期：2026-10-18。范围：原始附件解析、OCR、异步处理、结果存储与技能读取。

## 建议与最终取舍

最初按功能完整度推荐 **Docling + 官方 docling-serve + 中文 RapidOCR**。后续核查了实际 ECS：2 vCPU、2 GiB 主机，服务容器限制为 1.5 CPU / 768 MiB，容器 `/tmp` 只有 128 MiB。Docling 的模型服务在这组限制下不适合作为当前接入方案；应等到有专用 OCR 资源后再评估。

最终实现复用 **Poppler + Tesseract `chi_sim+eng`** 做逐页提取和按需 OCR，不重建整本可搜索 PDF。通过 `pdftotext` 先收集原生文字；只有读取范围内的页面没有文字时，才用 `pdftoppm` 渲染该页并让 Tesseract 直接输出文字。Tesseract 命令行支持将 OCR 结果直接输出到标准输出，许可为 Apache-2.0；部署镜像使用 Debian Bookworm 的 Poppler 与简体中文/英文语言包。[Tesseract 命令行用法](https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html)、[Tesseract 官方仓库](https://github.com/tesseract-ocr/tesseract)、[Poppler 工具](https://packages.debian.org/bookworm/poppler-utils)、[简体中文语言包](https://packages.debian.org/bookworm/tesseract-ocr-chi-sim)。OCRmyPDF 留在历史方案对照中，不参与在线附件读取链路。

这是资源约束下的取舍，不代表已测出两本书的识别准确率。OCRmyPDF 会加文字层，但不做 Docling/PaddleOCR 那类版面、表格结构化解析；识别文字中的图表布局仍需后续方案支持。

## 已核实的候选项目

版本为调研时 GitHub latest release 页面实际返回值，不以搜索摘要中的旧版本为准；发布日未取得可靠值，不推断。

| 项目 | 查得版本 | 代码许可 | 适用点与复用决策 |
|---|---|---|---|
| [Tesseract](https://github.com/tesseract-ocr/tesseract) | Debian Bookworm 软件包；运行版本由部署镜像固定 | Apache-2.0 | CLI 可直接将逐页 OCR 文字写到标准输出；当前实现按页调用 |
| [Poppler](https://packages.debian.org/bookworm/poppler-utils) | Debian Bookworm 软件包；运行版本由部署镜像固定 | GPL-2.0-or-later 等上游组件许可 | `pdfinfo`、`pdftotext`、`pdftoppm` 负责页数、原生文字提取和受限单页渲染 |
| [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF) | Debian Bookworm `14.0.1+dfsg1-1` | MPL-2.0 | 作为备选整本 OCR 工作流研究；当前在线读取不再运行它或生成整本 OCR PDF |
| [Docling](https://github.com/docling-project/docling) | [v2.140.0](https://github.com/docling-project/docling/releases/tag/v2.140.0) | MIT；模型另计 | 多格式解析，OCR，版面与阅读顺序，表格、图片、结构化 JSON；资源充足后优先评估 |
| [docling-serve](https://github.com/docling-project/docling-serve) | [v1.37.0](https://github.com/docling-project/docling-serve/releases/tag/v1.37.0) | MIT | 官方 API 服务、异步任务、CPU/GPU 容器；当前 ECS 内存不适用，资源升级后再直接复用 |
| [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) | [v3.7.0](https://github.com/PaddlePaddle/PaddleOCR/releases/tag/v3.7.0) | Apache-2.0 | PP-StructureV3 已组合 OCR、版面、表格、阅读顺序与 Markdown；中文复杂页质量对照候选 |
| [MinerU](https://github.com/opendatalab/MinerU) | [4.0.12](https://github.com/opendatalab/MinerU/releases/tag/mineru-4.0.12-released) | MinerU Open Source License：Apache-2.0 加附加条款 | 已提供解析、缓存、文档库、页/块定位与 API；完整候选，但需评估现有资料系统重叠及版本对应许可证 |

不根据项目宣传判定中文识别准确率排名。也不把 MinerU 当前许可描述成旧版本 AGPL 或无附加条款的 Apache-2.0。

## 接入流程

1. 文件选中后，客户端立即建立附件卡片并启动统一准备器；发送可以与准备并行。非 PDF 使用现有解析器在 isolate 提取文字并按片段上传；PDF 和图片上传到认证后的附件资源 API。
2. 服务端限制文件 50 MB、PDF 500 页、文字 10 MiB；文件按租户、内容哈希和解析配置生成缓存键，资源及片段保留 24 小时。阶段、完成页、覆盖范围、错误和分阶段耗时都由资源状态返回。
3. PDF 先用 `pdfinfo`/`pdftotext -layout` 得到页数与原生文字页。概览最多先处理 3 张可读代表页；空白页继续寻找代表页但最多尝试 8 页。查询未命中时再扩展未读页，明确要求全文时才按批次读全本。页码始终使用原始 PDF 页码。
4. 需要扫描页时，仅将请求范围内的单页用 Poppler 渲染为限尺寸灰度图，再用 Tesseract 输出该页文字。OCR 以单工作进程、每轮一页公平调度；不等待全书 OCR，不合成 OCR PDF，也不把整本扫描图一起发给视觉模型。
5. 资源取消只停止当前读取工作，保留已完成片段；上传或轮询中断可以从缓存恢复。API 以租户隔离资源，并在客户端、服务端执行共享发布号和接口契约版本校验。附件文字仍按不可信数据处理。

这些是结合项目场景提出的接入要求，不表示一个上游组件默认实现全部要求。

## 可以直接使用的上游能力

- [Docling Serve 异步接口](https://github.com/docling-project/docling-serve/blob/main/docs/usage.md)：`POST /v1/convert/file/async` 接收 multipart 文件并返回任务 ID；已有状态查询、结果获取与 WebSocket 更新。适合长书，避免手机等待一个长 HTTP 请求。
- [部署说明](https://docling-project.github.io/docling/usage/api_server/deployment/)：支持本地执行及 RQ/Redis worker 方式。选用持久队列时采用上游部署方案；不要凭“异步”二字承诺服务重启后自动断点续跑。
- [中文 OCR 配置](https://docling-project.github.io/docling/concepts/OCR/)：RapidOCR 基于 PP-OCR 模型，文档列出中文语言映射。应显式配置并锁定对应权重，不能沿用英文默认值假设能正确处理中文。
- [服务配置](https://github.com/docling-project/docling-serve/blob/main/docs/configuration.md)：有文件大小、页数、处理超时、结果保留期等参数。应与小栖 API 的限制统一，并验证原始文件上传路径。
- [Tesseract 命令行用法](https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html)：`stdout` 可直接接收 OCR 文字；当前流程逐页调用，不需要把识别结果写回整本 PDF。

当前容器直接调用 Poppler 与 Tesseract，不使用 OCRmyPDF 的整本处理路径。渲染尺寸和上传、页数限制受服务端校验；超限明确失败，不默默跳过页面。最终运行版本、权限和依赖完整性仍由 Docker 构建及 ECS 部署检查确认。

## 通用验收矩阵与 PDF 回归样本

| 回归文件 | 实测特征 | 额外回归关注点 |
|---|---|---|
| 健身健美运动系统训练.pdf | 240 页，文字层为 0 页，全部有图片 | 生成逐页中文 OCR 文本；图中动作示范不做视觉理解，需对实际识别率做真机/服务端验收 |
| book.pdf | 309 页；304 页可提取文字；第 1/4/5/58/255 页无文字层 | 原生正文与扫描页 OCR 合并、保留页码；第 4 页允许为空白；对扫描页表格/插图的语义理解留待后续 |

两份原 PDF 只补充为回归样本；实现和测试不按文件名、书籍内容或固定页码分支。另有通用合成夹具生成器覆盖原生文字、扫描、混合、空白、加密、损坏、超页数 PDF、PNG 和 Unicode 文本片段。验收还需用独立真实文件覆盖当前客户端支持的 DOCX、PPTX、XLSX、EPUB、文本和图片格式；合成样本不能代替真实 OCR 质量检查。

PaddleOCR 的 [PP-StructureV3 服务文档](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/pipeline_usage/PP-StructureV3.en.md)明确提示其服务默认可能只处理前 10 页；若使用该服务，必须配置分页或解除默认限制并验收全书覆盖。这是直接复用时需要核查的配置，不是选择该项目就自动解决。

## 小栖接入边界

直接复用上游：Poppler 的 PDF 页数、原生文字提取和页面渲染；Tesseract 的简体中文/英文逐页识别与标准输出。

小栖负责：登录与租户隔离、资源/片段 API、上传与 OCR 队列、24 小时缓存、恢复/取消、版本契约、耗时记录和 Agent 按需读取。客户端显示真实上传/解析状态；发送后立即显示“正在阅读”。普通概览只用一轮无工具模型调用概括已读范围；只有明确要求时才全文读取。

不再把 Docling 的异步服务直接塞进现有 ECS；资源允许时再评估结构化表格、版面和视觉图表解析。

已完成：根因定位、开源复用与许可证记录、通用附件资源 API、渐进 PDF/OCR、客户端解析隔离与恢复、Agent 概览/按需读取、上传/排队/提取/OCR/模型首字耗时记录、当前共享契约校验、通用合成夹具和定向测试。原 PDF 不发送给外部解析服务。

待交付状态在本次实现的部署检查后更新：真实 ECS OCR 与耗时、部署后的健康和数据核对、目标 Android 设备闭环，以及扫描页中文质量评估。代码与合成测试不等同于线上性能或识别质量已通过。
