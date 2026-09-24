# Портфолио аналитика данных: маркетинг и продукт

Пять кейсов из работы продуктового и маркетингового аналитика в сервисе доставки посылок с маркетплейсов (мобильное приложение iOS/Android, Казахстан, Узбекистан, Кыргызстан). Каждый кейс повторяет реальную задачу: SQL, ноутбук с расчётом и графиками, README с выводами и рекомендациями.

> **Данные синтетические.** Все таблицы генерирует [data_gen/generate.py](data_gen/generate.py) с фиксированным сидом. Структура таблиц и закономерности повторяют рабочие кейсы, числа изменены. Названия компании, партнёров и внутренних таблиц заменены.

## Кейсы

| # | Кейс | Главный результат |
|---|---|---|
| 01 | [Юнит-экономика рекламных каналов](01_unit_economics_channels) | Meta берёт 26% бюджета и 25% регистраций, но даёт 3% покупателей (CAC $236 против $12 у Google). Перенос 80% бюджета Meta в Google и TikTok даёт +26% покупателей на тот же бюджет. iOS конвертирует в 2.0 раза лучше Android. |
| 02 | [Аудит атрибуции: MMP против базы](02_attribution_audit) | Разница "в MMP на 19% меньше регистраций" объясняется выгрузкой, а не трекингом: после добавления органики, очистки id и перевода UTC -> UTC+5 покрытие по id 97.3%. Android дублирует 12% покупок, страна по IP занижает UZ и KG примерно на 10%. |
| 03 | [Когорты, повторные покупки, реактивация](03_cohorts_retention_reactivation) | Подсчёт по посылкам вместо дней заказа завышает долю повторных покупателей на 24 п.п. (83% против 59%). При истории заказов с 01.01.2025 реактивация 180+ дней полгода равна нулю и недосчитана на 58% во втором полугодии. |
| 04 | [ROMI офлайн-ивентов без трекинга](04_offline_events_romi) | 4 ивента на $22 000 дали +623 инкрементальных регистрации: $35 за регистрацию против $3 в таргете, ROMI от -78% до -95%. Распределение выручки по доле бюджета рисует +25...+89% и даёт +56% даже ивенту с нулевым эффектом. |
| 05 | [Ловушки качества данных](05_data_quality_traps) | Версии строк завышают выручку на 13.6%, смена смысла поля `price` в одном канале завышает выручку с мая на 148%, фильтр по статусу до дедупа завышает неоплаченные в 6 раз. 8 SQL-проверок ловят все три проблемы. |

## Что показано

- **SQL**: CTE, оконные функции (`ROW_NUMBER`, `LAG`, скользящая медиана), `QUALIFY`, `GROUPING SETS`, `ROLLUP`, `FILTER`, антиджойны и сверки двух источников. Диалект DuckDB, в кейсах 01, 03 и 05 есть варианты ключевых запросов для ClickHouse (`countIf`/`sumIf`, `argMax`, `FINAL`, `lagInFrame`).
- **Маркетинговая аналитика**: CPI, CPR, CR, CAC, ROAS, прогноз LTV/CAC, сценарий перераспределения бюджета, инкрементальность без трекинга, плацебо-проверка.
- **Продуктовая аналитика**: когорты, удержание, конверсия в разных окнах, повторные покупки, реактивация.
- **Качество данных**: дедупликация версий, сверка MMP и базы, часовые пояса, смена смысла полей, проверки в стиле тестов с кодом выхода.
- **Python**: pandas, DuckDB, matplotlib, воспроизводимая генерация данных, исполняемые ноутбуки.
- **Power BI**: модель данных и меры DAX для дашборда по тем же данным, [powerbi/README.md](powerbi/README.md).

## Как запустить

Нужен Python 3.10+.

```bash
pip install -r requirements.txt
python data_gen/generate.py          # ~5 секунд, 4 МБ parquet в data/
python run_all.py                    # генерация + выполнение всех ноутбуков + проверки качества
```

Или по шагам: после `generate.py` открыть любой `analysis.ipynb` в Jupyter или VS Code. Для Power BI: `python data_gen/generate.py --csv` дополнительно пишет CSV в `data/csv/`.

Папка `data/` в `.gitignore`: данные генерируются за секунды, а в git лежат только код и выполненные ноутбуки с выводами. Все числа в README взяты из выполненных ноутбуков (файлы `results.json` в папках кейсов). Генератор детерминированный: при тех же версиях библиотек получаются те же числа до цента.

## Структура

```
analytics-portfolio/
├── data_gen/generate.py        генератор синтетических данных
├── src/pf.py                   общие функции: DuckDB, загрузка SQL по имени, стиль графиков
├── 01_unit_economics_channels/
│   ├── README.md               задача, метод, результат, рекомендации
│   ├── queries.sql             SQL, блоки "-- name: ..." вызываются из ноутбука
│   ├── analysis.ipynb          выполненный ноутбук
│   ├── results.json            ключевые числа
│   └── charts/*.png
├── 02_attribution_audit/
├── 03_cohorts_retention_reactivation/
├── 04_offline_events_romi/
├── 05_data_quality_traps/      + checks.sql и run_checks.py
├── powerbi/README.md           как собрать дашборд, меры DAX
├── run_all.py
└── requirements.txt
```

## Таблицы

| Таблица | Строк | Что внутри |
|---|---:|---|
| `users` | 90 620 | регистрации 2023-2026: дата, страна, город, ОС, источник |
| `orders` | 72 240 | чистая витрина заказов (посылок): цена доставки, вес, канал, статус оплаты |
| `orders_raw` | 81 915 | та же таблица "как в хранилище": версии строк, сменившийся смысл `price` |
| `ad_spend` | 492 | расход, показы, клики, установки по дням, платформе и ОС, 07-08.2026 |
| `mmp_events_nonorganic`, `mmp_events_organic` | 6 473 и 1 700 | сырые события MMP за август 2026 |
| `offline_events`, `marketing_budget` | 4 и 16 | офлайн-ивенты и маркетинговый бюджет по месяцам |

---

## English summary

A data analyst portfolio with five cases from marketing and product analytics at a parcel delivery app (iOS/Android, Central Asia). All data is synthetic, generated by a seeded script; the cases mirror real work tasks with changed numbers.

1. **Channel unit economics**: CPI, CAC, ROAS and projected LTV/CAC by ad platform and OS. One platform brings 25% of paid registrations but 3% of buyers; moving its budget to the two best platforms yields +26% buyers for the same spend.
2. **Attribution audit**: reconciliation of MMP event exports with the internal database. User-level coverage is 97%; the headline gap came from a missing organic export, UTC vs UTC+5, user id formatting, Android duplicate events and IP-based country.
3. **Cohorts and reactivation**: conversion windows, cohort heatmap, repeat buyers counted by order day instead of parcel, and how short warehouse history hides reactivation.
4. **Offline events ROMI**: incremental uplift against a median baseline with a placebo test; ROMI -78% to -95%, and why splitting revenue by budget share is not a measurement.
5. **Data quality traps**: row versions, a field that changed meaning in one channel, payment status semantics, and SQL checks that fail the raw table and pass the clean one.

Stack: SQL (DuckDB, ClickHouse notes), Python (pandas, matplotlib), Jupyter, Power BI (DAX). Run: `pip install -r requirements.txt && python run_all.py`.
