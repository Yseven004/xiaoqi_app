# 输入焦点修正

用户确认：空输入收起软键盘时失焦；点击其他按钮或空白时失焦；点击另一个输入框时正常转移焦点，按钮第一次点击即执行。仅收起键盘时保留已有内容输入框的焦点。

实现：`MarketInputFocusScope` 通过 Flutter 的输入框外部点击 Action 和键盘指标监听统一执行。键盘关闭后只处理本作用域内仍为空的当前输入，不修改文本，不清除已转移到其他输入框的焦点。作用范围为创建技能／插件的三步与编辑画布，以及共用 `MarketDialog` 表单；嵌入式导入区继承父作用域，避免重复监听。

永久规则已同步至项目根 `DESIGN.md` 和全局 `C:/Users/20833/.codex/AGENTS.md`（该目录映射至 `D:/.codex`）。后续前端设计、实现和验收默认遵守。

验证：`flutter test --no-pub test/market_input_focus_test.dart --reporter expanded`，3 项通过：按钮首击执行且保留内容、输入框焦点转移及空白点击、空输入／有内容输入在键盘收起时的差异。格式和 `git diff --check` 完成；相关源码静态分析无 error，仍有此前的未引用 AI 方法警告及风格提示。

未执行真机验证，待用户真机验证。server deployment not needed：仅修改 Flutter 焦点处理和设计规范。
