# 网上找书首批书源实测

## 接口 40 的渠道复核

原有三本技术书继续使用作者或出版项目的固定发行文件。中文维基文库新增了按作品查找的渠道，生产出口实测可访问 MediaWiki 的目录、作品修订和章节接口。检索检查公有领域标注、作品署名、目录及章节修订。导入时读取指定修订的章节、校验正文并排版生成 EPUB，书内保留逐章来源。香港生产出口访问第三方托管的 WS Export 返回 403，因此改用 MediaWiki 官方 API。当前导入范围为有明确授权及可核对目录的作品。[《吶喊》](https://zh.wikisource.org/wiki/吶喊) · [MediaWiki Action API](https://www.mediawiki.org/wiki/API:Main_page)

中文题名在 Open Library 没有匹配版次时，继续查询 Internet Archive 馆藏的原文题名，并用 ISBN 与可用的 Open Library 版次记录核对。《乔布斯的魔力演讲》命中 Carmine Gallo 的 2010 年第 1 版（9787508621050）和 2011 年第 2 版（9787508630779）。这两个结果只交付书目信息和馆藏来源。[第 1 版](https://archive.org/details/qiaobusidemoliya0001gall) · [第 2 版](https://archive.org/details/qiaobusidemoliya0000gall)

生产出口访问 Internet Archive 书目端点遇到 HTTP 429。目录没有给出正匹配时，服务复用已有的网页检索发现公开图书馆条目和 ISBN，并用 Open Library 的正式版次记录核对题名、ISBN 和语言。同一作品的其他出版版本也要用独立 ISBN 和目录记录核实。网页摘要只用于发现书目，全书文件资格仍由对应的原始授权来源认定。[Open Library Search API](https://openlibrary.org/dev/docs/api/search) · [河南开放大学图书馆馆藏](https://tscx.open.ha.cn/opac/book/1a8d783d377d450bdf21abe52ee03983)

## 接口 39 基线记录

2026-11-21，在开发机执行两轮整书下载及文件检查。三本书、六份文件共 12 次全部返回 HTTP 200。同一文件两轮 SHA-256 一致。两轮在同一次开发会话内完成。

| 书籍和作者 | 核实的电子版 | 整书结果 | 来源与使用条件 |
| --- | --- | --- | --- |
| 《Hello 算法》，靳宇栋（krahets） | 1.3.0，简体中文。实测 Python PDF、Java EPUB | PDF 348 页、16,176,086 字节。EPUB 22,195,798 字节，可解析目录和正文，ZIP 完整性检查通过 | 作者官方仓库发布。版本标记的书籍许可为 CC BY-NC-SA 4.0，保留出处与署名。 [作者](https://www.hello-algo.com/) · [发布页](https://github.com/krahets/hello-algo/releases/tag/1.3.0) · [版本许可](https://github.com/krahets/hello-algo/blob/1.3.0/README.md#license) |
| 《动手学深度学习》，Aston Zhang、Zachary C. Lipton、Mu Li、Alexander J. Smola | 中文第 2 版，封面标识 Release 2.0.0、2023-08-18。实测 PyTorch、MXNet PDF | PyTorch 797 页、30,878,156 字节。MXNet 813 页、32,671,481 字节。两份封面列出的标题、版本、作者一致 | D2L 作者官网提供两个全文文件。中文源项目为 Apache-2.0。线上文件采用自己的版本和日期。 [作者官网](https://zh-v2.d2l.ai/) · [PDF 下载配置](https://github.com/d2l-ai/d2l-zh/blob/master/config.ini) · [中文源项目许可](https://github.com/d2l-ai/d2l-zh/blob/master/LICENSE) |
| 《Pro Git》，Scott Chacon、Ben Straub | 简体中文第 2 版，发布 2.1.80 | PDF 501 页、20,131,502 字节。EPUB 13,946,288 字节，可解析目录和正文，ZIP 完整性检查通过 | Git 官网指向官方中文仓库。PDF 确认 CC BY-NC-SA 3.0。保留出处与署名。 [Git 官网](https://git-scm.com/book/zh/v2) · [发布页](https://github.com/progit/progit2-zh/releases/tag/2.1.80) · [许可](https://creativecommons.org/licenses/by-nc-sa/3.0/) |

《Hello 算法》简体 Java EPUB 的内部语言字段标成 `en`，文件名、官方发布附件以及实际目录和正文显示为简体中文。插件按正式发行文件对应的语言与示例版本展示。Pro Git EPUB 的内部工具元数据同时包含 Asciidoctor 等标签，作者仍按 Git 官网与 PDF 署名显示。

## 渠道判断

1. **GitHub Releases 可提供整书。** 两个官方仓库出站均只有一次跳转，落到 `release-assets.githubusercontent.com` 的原仓库附件目录。入口使用固定版本的 HTTPS 发布链接。开发机无认证 REST API 已遇到限流，文件探测与导入使用发布附件地址。
2. **D2L 作者官网可提供整书。** 两个中文 PDF 都由 `zh-v2.d2l.ai` 直接返回，无跳转。书卡保留所选框架和版本。用户确认后从原始来源下载到个人书库。
3. **Open Library 可补充书目。** 《活着》检索给出了余华、作家出版社 2012 版与南海出版公司 1998-5 版及独立 ISBN。此渠道只显示「仅书目 · 暂无可验证整本」。检索按作品对应版的标题、作者及出版社读取。不直接使用目录中的借阅、预览或所谓全文链接。《三体》目录混录译者等多位责任者，这种数据不直接用于作者字段。 [Search API](https://openlibrary.org/dev/docs/api/search) · [使用与限流](https://openlibrary.org/developers/api) · [《活着》2012 年版](https://openlibrary.org/books/OL33426721M)
4. **OAPEN 与 Project Gutenberg 暂缓接入整书。** OAPEN 的公开 OAI 元数据端点可达，此次没有核实可直接导入的中文整书样本。Project Gutenberg 主站条款限制自动访问及大规模文件直链，目录检索与许可镜像还需验证。 [OAPEN 元数据](https://oapen.org/librarians/metadata) · [Gutenberg 网站条款](https://www.gutenberg.org/policy/terms_of_use.html)

当前三本作品的官方电子版下载允许范围在服务端集中配置，实际生成的候选逐份检查来源重定向、大小与文件头。未知作品优先使用既有网页搜索识别已核准的官方作品，再查询 Open Library 的相关书目。确认证据来自受审核的官方发行版及原始文件。打开任意网页或扫描未知下载站均无法把其文件变成导入候选。

## 验收范围

Dart 后台实测通过 6 项，覆盖《Hello 算法》Python PDF 与 Java EPUB、《动手学深度学习》PyTorch PDF、《Pro Git》中文 EPUB、《活着》仅书目及不同版本误匹配。每份可导入候选同时通过点击导入前的第二次文件探测。运行方式为 `XIAOQI_BOOK_SEARCH_LIVE=1 dart test test/book_search_sources_live_test.dart`。

整书下载和后台实测都在开发机进行。开发机 DNS 一度返回 `28.0.0.*` 虚拟地址，且后续直连超时。Dart 实测通过 `XIAOQI_BOOK_SEARCH_TEST_PROXY` 使用既有本机代理。部署进程采用直连并固定到已核验的公网地址，目标环境联网和 Android 入库仍需独立验收。
