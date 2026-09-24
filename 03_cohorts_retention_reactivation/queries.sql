-- Кейс 3. Когорты регистраций, повторные покупки, реактивация.
-- Покупка = уникальный день заказа пользователя: одна покупка приходит несколькими посылками
-- (order_id), и в один день у пользователя бывает 2-5 строк заказов.
-- Заказы без отмен: payment_status IN (1, 2).

-- name: purchase_days_view
-- вспомогательная таблица: одна строка = пользователь x день покупки
CREATE OR REPLACE TEMP TABLE purchase_days AS
SELECT user_id,
       CAST(created_at AS DATE)   AS order_day,
       COUNT(*)                   AS parcels,
       SUM(price)                 AS revenue
FROM orders
WHERE payment_status IN (1, 2)
GROUP BY ALL;

-- name: parcels_per_purchase
-- сколько посылок приходится на одну покупку
SELECT parcels, COUNT(*) AS purchases, COUNT(*) / SUM(COUNT(*)) OVER () AS share
FROM purchase_days
GROUP BY parcels
ORDER BY parcels;

-- name: cohort_conversion
-- конверсия регистрации в первую покупку: в месяц регистрации, за 30 дней и за всё время
WITH cohort AS (
    SELECT user_id, registered_at, DATE_TRUNC('month', registered_at) AS cohort_month
    FROM users
    WHERE registered_at >= DATE '2025-03-01' AND registered_at < DATE '2026-09-01'
),
first_purchase AS (
    SELECT user_id, MIN(order_day) AS first_day
    FROM purchase_days
    GROUP BY user_id
)
SELECT
    c.cohort_month,
    COUNT(*)                                                                             AS regs,
    COUNT(*) FILTER (WHERE DATE_TRUNC('month', f.first_day) = c.cohort_month)            AS buyers_same_month,
    COUNT(*) FILTER (WHERE f.first_day < CAST(c.registered_at AS DATE) + INTERVAL 30 DAY) AS buyers_d30,
    COUNT(f.user_id)                                                                     AS buyers_lifetime,
    COUNT(*) FILTER (WHERE DATE_TRUNC('month', f.first_day) = c.cohort_month) / COUNT(*) AS cr_same_month,
    COUNT(*) FILTER (WHERE f.first_day < CAST(c.registered_at AS DATE) + INTERVAL 30 DAY) / COUNT(*) AS cr_d30,
    COUNT(f.user_id) / COUNT(*)                                                          AS cr_lifetime,
    DATE_DIFF('day', c.cohort_month, DATE '2026-09-14')                                  AS days_observed
FROM cohort c
LEFT JOIN first_purchase f USING (user_id)
GROUP BY c.cohort_month
ORDER BY c.cohort_month;

-- name: retention_matrix
-- доля когорты с покупкой в месяце N после регистрации (M0 = месяц регистрации)
WITH cohort AS (
    SELECT user_id, DATE_TRUNC('month', registered_at) AS cohort_month
    FROM users
    WHERE registered_at >= DATE '2025-03-01' AND registered_at < DATE '2026-09-01'
),
sizes AS (
    SELECT cohort_month, COUNT(*) AS regs FROM cohort GROUP BY 1
),
activity AS (
    SELECT DISTINCT c.cohort_month, c.user_id,
           DATE_DIFF('month', c.cohort_month, DATE_TRUNC('month', p.order_day)) AS month_n
    FROM cohort c
    JOIN purchase_days p USING (user_id)
    WHERE p.order_day < DATE '2026-09-01'   -- сентябрь неполный
)
SELECT a.cohort_month, a.month_n, s.regs,
       COUNT(*)          AS active_users,
       COUNT(*) / s.regs AS active_share
FROM activity a
JOIN sizes s USING (cohort_month)
WHERE a.month_n BETWEEN 0 AND 12
GROUP BY a.cohort_month, a.month_n, s.regs
ORDER BY a.cohort_month, a.month_n;

-- name: repeat_buyers_monthly
-- повторные покупатели по месяцам: наивно по посылкам и правильно по дням заказа
WITH o AS (
    SELECT user_id, created_at, CAST(created_at AS DATE) AS order_day,
           LAG(created_at) OVER (PARTITION BY user_id ORDER BY created_at) AS prev_parcel_at,
           MIN(CAST(created_at AS DATE)) OVER (PARTITION BY user_id)       AS first_day
    FROM orders
    WHERE payment_status IN (1, 2)
)
SELECT
    DATE_TRUNC('month', order_day)                                      AS month,
    COUNT(DISTINCT user_id)                                             AS buyers,
    COUNT(DISTINCT user_id) FILTER (WHERE prev_parcel_at IS NOT NULL)   AS repeat_by_parcels,
    COUNT(DISTINCT user_id) FILTER (WHERE order_day > first_day)        AS repeat_by_days
FROM o
WHERE order_day >= DATE '2025-03-01' AND order_day < DATE '2026-09-01'
GROUP BY 1
ORDER BY 1;

-- name: reactivation_full
-- реактивация: покупка после паузы 180+ дней, полная история заказов
WITH d AS (
    SELECT user_id, order_day,
           LAG(order_day) OVER (PARTITION BY user_id ORDER BY order_day) AS prev_day
    FROM purchase_days
)
SELECT DATE_TRUNC('month', order_day) AS month,
       COUNT(DISTINCT user_id)                                                      AS buyers,
       COUNT(DISTINCT user_id) FILTER (WHERE prev_day IS NULL)                      AS new_buyers,
       COUNT(DISTINCT user_id) FILTER (WHERE DATE_DIFF('day', prev_day, order_day) >= 180) AS reactivated
FROM d
WHERE order_day >= DATE '2025-01-01' AND order_day < DATE '2026-09-01'
GROUP BY 1
ORDER BY 1;

-- name: reactivation_short_history
-- то же самое, но в хранилище заказы только с 01.01.2025 (как бывает после миграции)
WITH d AS (
    SELECT user_id, order_day,
           LAG(order_day) OVER (PARTITION BY user_id ORDER BY order_day) AS prev_day
    FROM purchase_days
    WHERE order_day >= DATE '2025-01-01'
)
SELECT DATE_TRUNC('month', order_day) AS month,
       COUNT(DISTINCT user_id)                                                      AS buyers,
       COUNT(DISTINCT user_id) FILTER (WHERE prev_day IS NULL)                      AS new_buyers,
       COUNT(DISTINCT user_id) FILTER (WHERE DATE_DIFF('day', prev_day, order_day) >= 180) AS reactivated
FROM d
WHERE order_day < DATE '2026-09-01'
GROUP BY 1
ORDER BY 1;

-- name: dormancy_gaps
-- распределение пауз между покупками: сколько истории нужно, чтобы видеть реактивацию
WITH d AS (
    SELECT user_id, order_day,
           DATE_DIFF('day', LAG(order_day) OVER (PARTITION BY user_id ORDER BY order_day), order_day) AS gap
    FROM purchase_days
)
SELECT gap
FROM d
WHERE gap >= 180 AND order_day >= DATE '2025-01-01';
