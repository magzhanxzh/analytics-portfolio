-- Кейс 5. Ловушки качества данных в таблице заказов.
-- orders_raw = таблица как в хранилище (версии строк, поле price поменяло смысл в одном канале).
-- orders     = очищенная витрина, с которой работают остальные кейсы.

-- name: versions_overview
-- сколько строк, ключей и версий
SELECT
    COUNT(*)                                         AS rows_raw,
    COUNT(DISTINCT (created_at, order_id))           AS keys_created_order,
    COUNT(DISTINCT order_id)                         AS keys_order_only,
    COUNT(*) - COUNT(DISTINCT (created_at, order_id)) AS extra_versions
FROM orders_raw;

-- name: versions_per_key
SELECT versions, COUNT(*) AS keys
FROM (
    SELECT created_at, order_id, COUNT(*) AS versions
    FROM orders_raw
    GROUP BY ALL
)
GROUP BY versions
ORDER BY versions;

-- name: dedup
-- правильная дедупликация: последняя версия по ключу (created_at, order_id)
CREATE OR REPLACE TEMP TABLE orders_dedup AS
SELECT *
FROM orders_raw
QUALIFY ROW_NUMBER() OVER (PARTITION BY created_at, order_id ORDER BY updated_at DESC) = 1;

-- name: dedup_wrong_key
-- дедупликация только по order_id: у domestic свой счётчик id, и реальные заказы склеиваются
WITH d AS (
    SELECT *
    FROM orders_raw
    QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY updated_at DESC) = 1
)
SELECT channel,
       COUNT(*) AS orders_after_wrong_dedup,
       (SELECT COUNT(*) FROM orders_dedup x WHERE x.channel = d.channel) AS orders_true,
       COUNT(*) / (SELECT COUNT(*) FROM orders_dedup x WHERE x.channel = d.channel) - 1 AS diff
FROM d
GROUP BY channel
ORDER BY channel;

-- name: revenue_by_month
-- выручка по месяцам: сырая таблица без дедупа, после дедупа и чистая витрина
WITH raw AS (
    SELECT DATE_TRUNC('month', created_at) AS month,
           SUM(price) FILTER (WHERE payment_status IN (1, 2)) AS booked,
           SUM(price) FILTER (WHERE payment_status = 2)       AS paid,
           COUNT(*)                                           AS rows_
    FROM orders_raw GROUP BY 1
),
dd AS (
    SELECT DATE_TRUNC('month', created_at) AS month,
           SUM(price) FILTER (WHERE payment_status IN (1, 2)) AS booked,
           SUM(price) FILTER (WHERE payment_status = 2)       AS paid,
           COUNT(*)                                           AS rows_
    FROM orders_dedup GROUP BY 1
),
clean AS (
    SELECT DATE_TRUNC('month', created_at) AS month,
           SUM(price) FILTER (WHERE payment_status IN (1, 2)) AS booked,
           SUM(price) FILTER (WHERE payment_status = 2)       AS paid,
           COUNT(*)                                           AS rows_
    FROM orders GROUP BY 1
)
SELECT month,
       raw.booked   AS booked_raw,
       dd.booked    AS booked_dedup,
       clean.booked AS booked_clean,
       raw.rows_    AS orders_raw,
       dd.rows_     AS orders_dedup,
       raw.booked / dd.booked - 1 AS dup_inflation
FROM raw JOIN dd USING (month) JOIN clean USING (month)
WHERE month >= DATE '2025-09-01'
ORDER BY month;

-- name: unpaid_filter_before_dedup
-- фильтр по статусу ДО дедупа: старые версии оплаченных заказов попадают в "не оплачено"
SELECT
    (SELECT COUNT(*) FROM (
        SELECT DISTINCT created_at, order_id FROM orders_raw WHERE payment_status = 1)) AS unpaid_filter_first,
    (SELECT COUNT(*) FROM orders_dedup WHERE payment_status = 1) AS unpaid_dedup_first;

-- name: price_per_kg
-- медианная цена за кг по каналу и месяцу: смена смысла поля видна сразу
SELECT channel,
       DATE_TRUNC('month', created_at) AS month,
       MEDIAN(price / weight_kg)       AS median_price_per_kg,
       COUNT(*)                        AS orders
FROM orders_dedup
WHERE created_at >= DATE '2025-09-01' AND created_at < DATE '2026-09-01'
GROUP BY ALL
ORDER BY channel, month;

-- name: price_jump_alert
-- автоматическая проверка: цена за кг отличается от медианы трёх прошлых месяцев больше чем на 50%
WITH m AS (
    SELECT channel,
           DATE_TRUNC('month', created_at) AS month,
           MEDIAN(price / weight_kg)       AS ppk
    FROM orders_dedup
    GROUP BY ALL
),
w AS (
    SELECT *,
           MEDIAN(ppk) OVER (PARTITION BY channel ORDER BY month
                             ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS ppk_prev3
    FROM m
)
SELECT channel, month, ppk, ppk_prev3, ppk / ppk_prev3 - 1 AS change
FROM w
WHERE ABS(ppk / ppk_prev3 - 1) > 0.5
ORDER BY channel, month;

-- name: channel_share
-- вес канала: по выручке из сырого поля price и по числу заказов
SELECT DATE_TRUNC('month', created_at) AS month,
       SUM(price) FILTER (WHERE channel = 'marketplace_b') / SUM(price) AS share_by_price,
       COUNT(*)   FILTER (WHERE channel = 'marketplace_b') / COUNT(*)   AS share_by_orders
FROM orders_dedup
WHERE created_at >= DATE '2025-09-01' AND created_at < DATE '2026-09-01'
  AND payment_status IN (1, 2)
GROUP BY 1
ORDER BY 1;

-- name: status_by_month
-- структура статусов оплаты по месяцу заказа
SELECT DATE_TRUNC('month', created_at) AS month,
       AVG((payment_status = 2)::INT) AS share_paid,
       AVG((payment_status = 1)::INT) AS share_unpaid,
       AVG((payment_status = 0)::INT) AS share_cancelled,
       SUM(price) FILTER (WHERE payment_status = 2)       AS revenue_paid,
       SUM(price) FILTER (WHERE payment_status IN (1, 2)) AS revenue_booked
FROM orders
WHERE created_at >= DATE '2026-03-01'
GROUP BY 1
ORDER BY 1;

-- name: paid_by_age
-- доля оплаченных в зависимости от возраста заказа на дату выгрузки
SELECT DATE_DIFF('day', CAST(created_at AS DATE), DATE '2026-09-14') AS age_days,
       AVG((payment_status = 2)::INT)            AS share_paid,
       COUNT(*)                                  AS orders
FROM orders
WHERE payment_status IN (1, 2)
  AND created_at >= DATE '2026-06-01'
GROUP BY 1
ORDER BY 1;
