"""Run the real program in Lua 5.2 with a deterministic CC:Tweaked simulator."""
from pathlib import Path
import sys

try:
    from lupa.lua52 import LuaRuntime
except ImportError:
    print("Install the test dependency: python -m pip install lupa==2.6", file=sys.stderr)
    raise

root = Path(__file__).resolve().parents[1]
runtime = LuaRuntime(unpack_returned_tuples=True)
runtime.globals().PROGRAM_SOURCE = (root / "branchminer.lua").read_text(encoding="utf-8")
runtime.globals().INSTALLER_SOURCE = (root / "install.lua").read_text(encoding="utf-8")
runtime.execute((root / "tests" / "test_branchminer.lua").read_text(encoding="utf-8"))
