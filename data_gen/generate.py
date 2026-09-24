"""Генератор синтетических данных для портфолио.

Все таблицы выдуманы. Структура и закономерности повторяют реальные рабочие
кейсы (сервис доставки посылок с маркетплейсов, приложение iOS/Android),
но числа изменены. Запуск:

    python data_gen/generate.py          # parquet в data/
    python data_gen/generate.py --csv    # плюс CSV копии для Power BI

Сид фиксирован, поэтому повторный запуск даёт те же файлы.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

SEED = 42
ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

START = pd.Timestamp("2023-01-01")
SNAPSHOT = pd.Timestamp("2026-09-14")  # последний день выгрузки, включительно
PRICE_CHANGE = pd.Timestamp("2026-05-01")  # с этой даты у marketplace_b поле price меняет смысл

SOURCES = ["tiktok", "google", "meta", "yandex", "organic"]
SOURCE_SHARE = [0.30, 0.24, 0.20, 0.08, 0.18]
IOS_SHARE = {"tiktok": 0.30, "google": 0.35, "meta": 0.40, "yandex": 0.25, "organic": 0.40, "offline": 0.35}
# вероятность когда-либо купить (до поправок на ОС и страну)
BUY_BASE = {"tiktok": 0.21, "google": 0.30, "meta": 0.02, "yandex": 0.15, "organic": 0.26, "offline": 0.09}
OS_MULT = {"ios": 1.50, "android": 0.72}
COUNTRY_MULT = {"KZ": 1.0, "UZ": 0.8, "KG": 0.8}
COUNTRIES = ["KZ", "UZ", "KG"]
COUNTRY_SHARE = [0.80, 0.12, 0.08]
KZ_CITIES = ["Almaty", "Astana", "Shymkent", "Karaganda", "Other KZ"]
KZ_CITY_SHARE = [0.40, 0.25, 0.10, 0.07, 0.18]
OTHER_CITY = {"UZ": "Tashkent", "KG": "Bishkek"}

CHANNELS = ["marketplace_a", "marketplace_b", "domestic"]
CHANNEL_SHARE = [0.55, 0.30, 0.15]
TARIFF = {"marketplace_a": 8.5, "marketplace_b": 7.5, "domestic": 2.5}  # USD за кг

# офлайн-ивенты: даты, бюджет и сколько лишних регистраций они реально дали
OFFLINE_EVENTS = [
    # event_id, name, city, start, end, cost_usd, extra regs per day (event days + 2 tail days)
    (1, "Ярмарка в ТРЦ", "Almaty", "2025-10-18", "2025-10-19", 6000, [70, 65, 25, 10]),
    (2, "Стенд на фестивале", "Astana", "2026-02-21", "2026-02-22", 4500, [45, 40, 15, 5]),
    (3, "Городской маркет", "Almaty", "2026-05-09", "2026-05-11", 8000, [60, 70, 55, 30, 15]),
    (4, "Промо в университете", "Shymkent", "2026-07-04", "2026-07-04", 3500, [55, 20, 10]),
]

# часы регистрации/заказа по местному времени (UTC+5); ночью мало, но не ноль
HOUR_W = np.array([3, 2, 1.5, 1, 1, 1.5, 3, 5, 7, 8, 8, 8, 8, 8, 8, 8, 8, 9, 10, 11, 11, 10, 8, 5], dtype=float)
HOUR_W /= HOUR_W.sum()


def daily_registrations(rng: np.random.Generator) -> pd.DataFrame:
    days = pd.date_range(START, SNAPSHOT, freq="D")
    t = np.arange(len(days)) / (len(days) - 1)
    base = 22 * np.exp(np.log(150 / 22) * t)  # рост с ~22 до ~150 в день
    weekly = np.where(days.dayofweek >= 5, 1.12, 0.96)
    season = 1 + 0.08 * np.sin(2 * np.pi * (days.dayofyear - 300) / 365)  # пик к ноябрю
    lam = base * weekly * season
    n = rng.poisson(lam)
    return pd.DataFrame({"day": days, "n": n})


def make_users(rng: np.random.Generator) -> pd.DataFrame:
    reg = daily_registrations(rng)
    day = np.repeat(reg["day"].values, reg["n"].values)
    n = len(day)
    source = rng.choice(SOURCES, size=n, p=SOURCE_SHARE)
    country = rng.choice(COUNTRIES, size=n, p=COUNTRY_SHARE)
    offline_event = np.zeros(n, dtype=int)

    # дополнительные регистрации от офлайн-ивентов: для базы они "organic"
    extra_days, extra_event, extra_city = [], [], []
    for ev_id, _, city, start, _end, _cost, per_day in OFFLINE_EVENTS:
        for i, lam in enumerate(per_day):
            k = rng.poisson(lam)
            extra_days += [pd.Timestamp(start) + pd.Timedelta(days=i)] * k
            extra_event += [ev_id] * k
            extra_city += [city] * k
    m = len(extra_days)
    day = np.concatenate([day, np.array(extra_days, dtype="datetime64[ns]")])
    source = np.concatenate([source, np.array(["organic"] * m)])
    country = np.concatenate([country, np.array(["KZ"] * m)])
    offline_event = np.concatenate([offline_event, np.array(extra_event, dtype=int)])
    n = len(day)

    city = np.empty(n, dtype=object)
    kz = country == "KZ"
    city[kz] = rng.choice(KZ_CITIES, size=kz.sum(), p=KZ_CITY_SHARE)
    for c, name in OTHER_CITY.items():
        city[country == c] = name
    city[n - m:] = extra_city

    beh = np.where(offline_event > 0, "offline", source)  # скрытый тип поведения
    ios_p = np.array([IOS_SHARE[b] for b in beh])
    os_ = np.where(rng.random(n) < ios_p, "ios", "android")

    hours = rng.choice(24, size=n, p=HOUR_W)
    secs = rng.integers(0, 3600, size=n)
    registered_at = pd.to_datetime(day) + pd.to_timedelta(hours * 3600 + secs, unit="s")

    df = pd.DataFrame({
        "registered_at": registered_at,
        "country": country,
        "city": city,
        "os": os_,
        "media_source": source,
        "_beh": beh,
        "_offline_event": offline_event,
    }).sort_values("registered_at", kind="stable").reset_index(drop=True)
    df.insert(0, "user_id", np.arange(100001, 100001 + len(df)))
    return df


def make_purchases(users: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    """Покупка = один день заказа. Потом каждая покупка раскладывается на посылки."""
    p = (users["_beh"].map(BUY_BASE) * users["os"].map(OS_MULT) * users["country"].map(COUNTRY_MULT)).clip(upper=0.95)
    buyer = rng.random(len(users)) < p.values
    b = users.loc[buyer, ["user_id", "registered_at", "_beh"]].reset_index(drop=True)

    rows_user, rows_day, rows_reg = [], [], []
    snap = SNAPSHOT.normalize()
    reg_days = b["registered_at"].dt.normalize().values
    loyal = rng.beta(6.2, 3.8, size=len(b))  # вероятность сделать следующую покупку
    for i in range(len(b)):
        u = rng.random()
        if u < 0.55:
            delay = rng.exponential(2.0)
        elif u < 0.80:
            delay = rng.uniform(3, 30)
        else:
            delay = 30 + rng.exponential(120)
        d = pd.Timestamp(reg_days[i]) + pd.Timedelta(days=int(delay))
        q = loyal[i] * (0.8 if b.at[i, "_beh"] == "offline" else 1.0)
        while d <= snap:
            rows_user.append(b.at[i, "user_id"])
            rows_day.append(d)
            rows_reg.append(b.at[i, "registered_at"])
            if rng.random() > q:
                break
            if rng.random() < 0.78:
                gap = rng.gamma(2.0, 14.0)
            else:
                gap = rng.uniform(150, 450)
            d = d + pd.Timedelta(days=max(1, int(gap)))
    return pd.DataFrame({"user_id": rows_user, "order_day": rows_day, "registered_at": rows_reg})


def make_orders(purchases: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    parcels = 1 + np.minimum(rng.poisson(0.9, size=len(purchases)), 5)
    o = purchases.loc[purchases.index.repeat(parcels)].reset_index(drop=True)
    n = len(o)
    hours = rng.choice(24, size=len(purchases), p=HOUR_W)
    first_time = np.repeat(hours * 3600 + rng.integers(0, 3600, size=len(purchases)), parcels)
    offset = rng.integers(0, 90 * 60, size=n)
    secs = np.minimum(first_time + offset, 24 * 3600 - 1)
    o["created_at"] = o["order_day"] + pd.to_timedelta(secs, unit="s")
    # заказ не может быть раньше регистрации
    min_ts = o["registered_at"] + pd.to_timedelta(rng.integers(300, 3600, size=n), unit="s")
    o["created_at"] = o["created_at"].where(o["created_at"] > o["registered_at"], min_ts)
    o["channel"] = rng.choice(CHANNELS, size=n, p=CHANNEL_SHARE)
    o["weight_kg"] = np.round(np.exp(rng.normal(0.0, 0.6, size=n)), 2).clip(0.1, 30)
    tariff = o["channel"].map(TARIFF).values
    o["price"] = np.round(np.maximum(2.0, o["weight_kg"].values * tariff * rng.uniform(0.9, 1.1, size=n)), 2)

    # статус оплаты на дату выгрузки: 2 = оплачен, 1 = ждёт оплаты при получении, 0 = отмена/тест
    age = (SNAPSHOT.normalize() + pd.Timedelta(days=1) - o["created_at"]).dt.total_seconds().values / 86400
    p_unpaid = 0.92 * np.exp(-age / 9.0) + 0.004
    r = rng.random(n)
    status = np.where(r < 0.025, 0, np.where(rng.random(n) < p_unpaid, 1, 2))
    o["payment_status"] = status
    o = o.sort_values("created_at", kind="stable").reset_index(drop=True)

    # id: у маркетплейсов общий счётчик, у domestic свой, заведённый позже с неудачного стартового
    # номера. Первые 1500 номеров domestic совпадают с последними номерами маркетплейсов.
    o["order_id"] = 0
    dom = o["channel"] == "domestic"
    n_mp = int((~dom).sum())
    o.loc[~dom, "order_id"] = np.arange(5_000_001, 5_000_001 + n_mp)
    dom_start = 5_000_001 + n_mp - 1500
    o.loc[dom, "order_id"] = np.arange(dom_start, dom_start + int(dom.sum()))
    o["updated_at"] = o["created_at"] + pd.to_timedelta(rng.integers(3600, 5 * 86400, size=n), unit="s")
    snap_end = SNAPSHOT + pd.Timedelta(hours=23, minutes=59, seconds=59)
    o["updated_at"] = o["updated_at"].clip(upper=snap_end)
    o = o[o["created_at"] <= snap_end]  # заказ, сдвинутый за дату выгрузки, ещё не существует
    cols = ["order_id", "user_id", "created_at", "updated_at", "channel", "weight_kg", "price", "payment_status"]
    return o[cols]


def make_orders_raw(orders: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    """Сырая таблица как в хранилище: версии строк и сменившийся смысл price."""
    raw = orders.copy()
    # 1) с мая 2026 marketplace_b пишет в price сумму товара + доставку
    mb = (raw["channel"] == "marketplace_b") & (raw["created_at"] >= PRICE_CHANGE)
    goods = np.round(np.exp(rng.normal(np.log(38), 0.5, size=mb.sum())), 2)
    raw.loc[mb, "price"] = raw.loc[mb, "price"].values + goods

    # 2) версии строк: у ~9% заказов лежат 1-2 старые версии (статус "не оплачен")
    dup_mask = rng.random(len(raw)) < 0.09
    dups = raw.loc[dup_mask].copy()
    k = rng.integers(1, 3, size=len(dups))
    dups = dups.loc[dups.index.repeat(k)].copy()
    back = pd.to_timedelta(rng.integers(600, 86400, size=len(dups)), unit="s")
    dups["updated_at"] = (dups["updated_at"] - back).clip(lower=dups["created_at"])
    dups["payment_status"] = np.where(dups["payment_status"] == 0, 0, 1)
    raw = pd.concat([raw, dups], ignore_index=True)
    raw = raw.sample(frac=1.0, random_state=SEED).reset_index(drop=True)
    return raw


def make_ad_spend(users: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    """Расходы по дням за июль-август 2026. Установки чуть больше регистраций."""
    cpr = {"tiktok": 3.2, "google": 2.2, "meta": 3.0, "yandex": 3.5}  # целевая цена регистрации
    reg_rate = {"tiktok": 0.55, "google": 0.62, "meta": 0.58, "yandex": 0.50}  # установка -> регистрация
    ctr = {"tiktok": 0.012, "google": 0.035, "meta": 0.010, "yandex": 0.020}
    click_to_install = {"tiktok": 0.10, "google": 0.14, "meta": 0.09, "yandex": 0.07}
    u = users[(users["registered_at"] >= "2026-07-01") & (users["registered_at"] < "2026-09-01")
              & (users["media_source"] != "organic")].copy()
    u["date"] = u["registered_at"].dt.normalize()
    g = u.groupby(["date", "media_source", "os"]).size().rename("regs").reset_index()
    rows = []
    for r in g.itertuples(index=False):
        src = r.media_source
        os_k = 1.25 if r.os == "ios" else 0.92  # iOS трафик дороже
        spend = r.regs * cpr[src] * os_k * rng.uniform(0.85, 1.15)
        installs = int(round(r.regs / reg_rate[src] * rng.uniform(0.92, 1.08)))
        clicks = int(round(installs / click_to_install[src]))
        impressions = int(round(clicks / ctr[src]))
        rows.append((r.date, src, r.os, round(spend, 2), impressions, clicks, installs))
    return pd.DataFrame(rows, columns=["date", "platform", "os", "spend_usd", "impressions", "clicks", "installs"])


MMP_SOURCE = {"tiktok": "tiktokglobal_int", "google": "googleadwords_int", "meta": "Facebook Ads",
              "yandex": "yandexdirect_int", "organic": "organic"}


def make_mmp_events(users: pd.DataFrame, orders: pd.DataFrame, rng: np.random.Generator):
    """Выгрузка событий из MMP за 31.07-01.09 (UTC). Два отчёта: неорганика и органика."""
    lo, hi = pd.Timestamp("2026-07-31"), pd.Timestamp("2026-09-02")
    u = users[(users["registered_at"] >= lo) & (users["registered_at"] < hi)].copy()
    reg = pd.DataFrame({
        "event_name": "af_complete_registration",
        "user_id": u["user_id"].values,
        "event_time": u["registered_at"].values - np.timedelta64(5, "h"),
        "order_id": pd.array([pd.NA] * len(u), dtype="Int64"),
        "os": u["os"].values,
        "country": u["country"].values,
        "media_source": u["media_source"].map(MMP_SOURCE).values,
    })
    reg = reg[rng.random(len(reg)) > 0.02]  # SDK не отправил событие

    o = orders[(orders["created_at"] >= lo) & (orders["created_at"] < hi)].merge(
        users[["user_id", "os", "country", "media_source"]], on="user_id")
    pur = pd.DataFrame({
        "event_name": "af_purchase",
        "user_id": o["user_id"].values,
        "event_time": o["created_at"].values - np.timedelta64(5, "h"),
        "order_id": pd.array(o["order_id"].values, dtype="Int64"),
        "os": o["os"].values,
        "country": o["country"].values,
        "media_source": o["media_source"].map(MMP_SOURCE).values,
        "event_revenue_usd": o["price"].values,
    })
    ios = pur["os"] == "ios"
    pur = pur[~(ios & (rng.random(len(pur)) < 0.03))]  # iOS теряет часть событий
    and_dup = pur[(pur["os"] == "android") & (rng.random(len(pur)) < 0.11)].copy()  # повтор отправки на Android
    and_dup["event_time"] = and_dup["event_time"] + pd.to_timedelta(rng.integers(1, 20, size=len(and_dup)), unit="s")
    ev = pd.concat([reg, pur, and_dup], ignore_index=True)

    # страна по IP: поездки и VPN. У UZ/KG заметно чаще
    p_foreign = np.where(ev["country"] == "KZ", 0.015, 0.09)
    foreign = rng.random(len(ev)) < p_foreign
    ev["country_code"] = ev["country"]
    ev.loc[foreign, "country_code"] = rng.choice(["TR", "RU", "AE", "DE", "PL"], size=foreign.sum(),
                                                 p=[0.35, 0.25, 0.15, 0.15, 0.10])
    # одна и та же страна у одного пользователя внутри дня: берём первую по пользователю
    ev["country_code"] = ev.groupby("user_id")["country_code"].transform("first")

    # customer_user_id: строка, иногда пустая (событие до логина) или с мусором в формате
    cuid = ev["user_id"].astype(str)
    r = rng.random(len(ev))
    cuid = np.where(r < 0.012, "", cuid)
    cuid = np.where((r >= 0.012) & (r < 0.022), "00" + ev["user_id"].astype(str), cuid)
    cuid = np.where((r >= 0.022) & (r < 0.028), ev["user_id"].astype(str) + " ", cuid)
    ev["customer_user_id"] = cuid
    ev["platform"] = ev["os"]
    ev["event_time"] = pd.to_datetime(ev["event_time"]).dt.floor("s")
    ev = ev[(ev["event_time"] >= lo) & (ev["event_time"] < pd.Timestamp("2026-09-01 20:00"))]
    ev = ev.sort_values("event_time", kind="stable").reset_index(drop=True)
    cols = ["event_time", "event_name", "customer_user_id", "platform", "country_code",
            "media_source", "order_id", "event_revenue_usd"]
    organic = ev["media_source"] == "organic"
    return ev.loc[~organic, cols].reset_index(drop=True), ev.loc[organic, cols].reset_index(drop=True)


def make_offline_events() -> pd.DataFrame:
    return pd.DataFrame(
        [(e[0], e[1], e[2], pd.Timestamp(e[3]), pd.Timestamp(e[4]), e[5]) for e in OFFLINE_EVENTS],
        columns=["event_id", "event_name", "city", "start_date", "end_date", "cost_usd"])


def make_marketing_budget(rng: np.random.Generator) -> pd.DataFrame:
    months = pd.date_range("2025-09-01", "2026-08-01", freq="MS")
    rows = []
    for m in months:
        rows.append((m, "paid_digital", round(float(rng.uniform(9000, 12500)), 2)))
    for e in OFFLINE_EVENTS:
        rows.append((pd.Timestamp(e[3]).to_period("M").to_timestamp(), "offline_event", float(e[5])))
    df = pd.DataFrame(rows, columns=["month", "item", "amount_usd"])
    return df.groupby(["month", "item"], as_index=False)["amount_usd"].sum()


def write(con: duckdb.DuckDBPyConnection, df: pd.DataFrame, name: str, csv: bool) -> None:
    con.register("tmp_df", df)
    con.execute(f"COPY tmp_df TO '{(DATA / f'{name}.parquet').as_posix()}' (FORMAT parquet, COMPRESSION zstd)")
    if csv:
        (DATA / "csv").mkdir(exist_ok=True)
        con.execute(f"COPY tmp_df TO '{(DATA / 'csv' / f'{name}.csv').as_posix()}' (HEADER, DELIMITER ',')")
    con.unregister("tmp_df")
    print(f"{name:<22} {len(df):>9,} строк")


def main() -> None:
    import sys
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", action="store_true", help="дополнительно сохранить CSV в data/csv/")
    args = ap.parse_args()
    DATA.mkdir(exist_ok=True)
    rng = np.random.default_rng(SEED)

    users = make_users(rng)
    purchases = make_purchases(users, rng)
    orders = make_orders(purchases, rng)
    orders_raw = make_orders_raw(orders, rng)
    ad_spend = make_ad_spend(users, rng)
    mmp_nonorg, mmp_org = make_mmp_events(users, orders, rng)

    con = duckdb.connect()
    write(con, users.drop(columns=["_beh", "_offline_event"]), "users", args.csv)
    write(con, orders, "orders", args.csv)
    write(con, orders_raw, "orders_raw", args.csv)
    write(con, ad_spend, "ad_spend", args.csv)
    write(con, mmp_nonorg, "mmp_events_nonorganic", args.csv)
    write(con, mmp_org, "mmp_events_organic", args.csv)
    write(con, make_offline_events(), "offline_events", args.csv)
    write(con, make_marketing_budget(rng), "marketing_budget", args.csv)
    size = sum(f.stat().st_size for f in DATA.glob("*.parquet")) / 1e6
    print(f"готово: {DATA} ({size:.1f} МБ parquet)")


if __name__ == "__main__":
    main()
