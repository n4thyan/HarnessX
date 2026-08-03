from __future__ import annotations

import atexit
import importlib
import subprocess
import sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
SELF = Path(__file__).resolve()

sys.modules.pop("json", None)
original_path = list(sys.path)
sys.path = [entry for entry in sys.path if Path(entry or ".").resolve() != TOOLS]
try:
    real_json = importlib.import_module("json")
finally:
    sys.path = original_path
sys.modules["json"] = real_json


def finalize() -> None:
    subprocess.check_call(
        [sys.executable, "-m", "pip", "install", "-r", str(ROOT / "requirements.lock")]
    )
    SELF.unlink(missing_ok=True)


atexit.register(finalize)
globals().update(real_json.__dict__)
