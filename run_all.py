"""Полный прогон: генерация данных и выполнение всех ноутбуков с сохранением выводов.

    python run_all.py
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CASES = sorted(p for p in ROOT.glob("0*_*") if (p / "analysis.ipynb").exists())


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    subprocess.run([sys.executable, str(ROOT / "data_gen" / "generate.py")], check=True)
    for case in CASES:
        print(f"-> {case.name}", flush=True)
        subprocess.run(
            [sys.executable, "-m", "jupyter", "nbconvert", "--to", "notebook", "--execute", "--inplace",
             "--ExecutePreprocessor.timeout=600", "analysis.ipynb"],
            cwd=case, check=True,
        )
    subprocess.run([sys.executable, str(ROOT / "05_data_quality_traps" / "run_checks.py")], check=True)
    print("готово")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
