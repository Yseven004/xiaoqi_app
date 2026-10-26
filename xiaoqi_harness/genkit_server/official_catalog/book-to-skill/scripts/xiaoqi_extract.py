"""Run the unchanged upstream extractor with durable task-private outputs."""
import os
from pathlib import Path
import runpy
import sys

sys.dont_write_bytecode = True
output = Path(os.environ.get("XIAOQI_BOOK_OUTPUT_DIR", "/workspace/output"))
output.mkdir(parents=True, exist_ok=True)
os.environ["BOOK_SKILL_WORKDIR"] = str(output / "book-extraction")
os.environ["BOOK_SKILL_INSTALL_MISSING"] = "no"
# Dependencies are deployment-owned; never let document content request pip.
if any(arg == "--install-missing" or arg.startswith("--install-missing=")
       for arg in sys.argv[1:]):
    raise SystemExit("小七不支持任务运行期间安装依赖。")
sys.argv.append("--no-install-missing")
runpy.run_path(str(Path(__file__).with_name("extract.py")), run_name="__main__")
print("跨调用读取：本次输出会保存为私有任务产物；下一次沙箱请在 "
      "/workspace/materials/ 中用 *-full_text.txt 和 *-metadata.json 查找，"
      "不要读取或等待上一沙箱的 /workspace/output/book-extraction/。")
