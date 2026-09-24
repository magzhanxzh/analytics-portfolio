"""Общие функции для ноутбуков: подключение DuckDB, загрузка SQL, стиль графиков."""
from __future__ import annotations

import json
import re
from pathlib import Path

import duckdb
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

TABLES = ["users", "orders", "orders_raw", "ad_spend", "mmp_events_nonorganic",
          "mmp_events_organic", "offline_events", "marketing_budget"]

# одна палитра на всё портфолио
COLORS = {
    "tiktok": "#3B5BA5", "google": "#2A9D8F", "meta": "#E76F51", "yandex": "#E9B44C", "organic": "#8D99AE",
    "ios": "#3B5BA5", "android": "#2A9D8F",
    "main": "#3B5BA5", "accent": "#E76F51", "ok": "#2A9D8F", "muted": "#8D99AE", "light": "#D9DEE7",
}


def connect() -> duckdb.DuckDBPyConnection:
    """Открывает DuckDB в памяти и вешает view на parquet файлы из data/."""
    missing = [t for t in TABLES if not (DATA / f"{t}.parquet").exists()]
    if missing:
        raise FileNotFoundError(f"нет файлов {missing}: сначала запустите python data_gen/generate.py")
    con = duckdb.connect()
    for t in TABLES:
        con.execute(f"CREATE VIEW {t} AS SELECT * FROM read_parquet('{(DATA / f'{t}.parquet').as_posix()}')")
    return con


def load_queries(path: str | Path) -> dict[str, str]:
    """Читает файл с блоками `-- name: xxx` и возвращает {имя: текст запроса}."""
    text = Path(path).read_text(encoding="utf-8")
    parts = re.split(r"^--\s*name:\s*(\w+)\s*$", text, flags=re.M)
    queries = {}
    for name, body in zip(parts[1::2], parts[2::2]):
        queries[name] = body.strip().rstrip(";")
    return queries


class Q:
    """Удобная обёртка: q('coverage') выполняет именованный запрос и отдаёт DataFrame."""

    def __init__(self, con: duckdb.DuckDBPyConnection, path: str | Path):
        self.con = con
        self.queries = load_queries(path)

    def __call__(self, name: str) -> pd.DataFrame:
        return self.con.sql(self.queries[name]).df()

    def show(self, name: str) -> None:
        print(self.queries[name])


def setup_style() -> None:
    plt.rcParams.update({
        "figure.figsize": (9, 4.8),
        "figure.dpi": 110,
        "savefig.dpi": 150,
        "savefig.bbox": "tight",
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.grid": True,
        "axes.grid.axis": "y",
        "grid.color": "#E6E9EF",
        "grid.linewidth": 0.8,
        "axes.axisbelow": True,
        "axes.titlesize": 13,
        "axes.titleweight": "bold",
        "axes.titlelocation": "left",
        "axes.labelsize": 10.5,
        "axes.labelcolor": "#333333",
        "xtick.color": "#444444",
        "ytick.color": "#444444",
        "font.family": "DejaVu Sans",
        "legend.frameon": False,
    })


def pct_axis(ax, axis: str = "y", decimals: int | None = None) -> None:
    fmt = mtick.PercentFormatter(1.0, decimals=decimals)
    (ax.yaxis if axis == "y" else ax.xaxis).set_major_formatter(fmt)


def usd_axis(ax, axis: str = "y") -> None:
    fmt = mtick.FuncFormatter(lambda v, _: f"${v:,.0f}")
    (ax.yaxis if axis == "y" else ax.xaxis).set_major_formatter(fmt)


def bar_labels(ax, fmt: str = "{:.0f}", pad: int = 3, fontsize: int = 9) -> None:
    for c in ax.containers:
        ax.bar_label(c, labels=[fmt.format(v) for v in c.datavalues], padding=pad, fontsize=fontsize)


def save(fig, name: str, folder: str | Path = "charts") -> Path:
    folder = Path(folder)
    folder.mkdir(exist_ok=True)
    path = folder / f"{name}.png"
    fig.savefig(path, facecolor="white")
    return path


def save_results(results: dict, path: str | Path = "results.json") -> None:
    """Ключевые числа кейса в json: из них собран README, по ним же сверка."""
    def conv(v):
        if hasattr(v, "item"):
            return v.item()
        return v
    clean = {k: conv(v) for k, v in results.items()}
    Path(path).write_text(json.dumps(clean, ensure_ascii=False, indent=2), encoding="utf-8")
