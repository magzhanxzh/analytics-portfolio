"""Прогон проверок качества из checks.sql.

    python 05_data_quality_traps/run_checks.py            # проверяет чистую витрину orders
    python 05_data_quality_traps/run_checks.py orders_raw # сырая таблица, проверки упадут

Код выхода 1, если хоть одна проверка нашла нарушения: так скрипт можно ставить в CI или в cron
перед обновлением отчёта.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.append(str(HERE.parent))
from src import pf  # noqa: E402


def run(table: str = "orders", con=None) -> list[tuple[str, int]]:
    con = con or pf.connect()
    checks = pf.load_queries(HERE / "checks.sql")
    return [(name, int(con.sql(sql.format(t=table)).fetchone()[0])) for name, sql in checks.items()]


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    table = sys.argv[1] if len(sys.argv) > 1 else "orders"
    results = run(table)
    width = max(len(n) for n, _ in results)
    for name, bad in results:
        print(f"{'OK  ' if bad == 0 else 'FAIL'} {name:<{width}} нарушений: {bad}")
    failed = [n for n, b in results if b]
    print(f"\n{table}: {len(results) - len(failed)} из {len(results)} проверок пройдено")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
