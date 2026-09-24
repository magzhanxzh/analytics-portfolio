-- Кейс 1. Юнит-экономика рекламных каналов, июль-август 2026.
-- Диалект DuckDB. Каждый запрос начинается с маркера "-- name:", ноутбук читает их по имени.
-- Когорта: регистрации 01.07-31.08.2026. Окно покупки: 14 дней от регистрации,
-- чтобы у поздних августовских регистраций было столько же времени, сколько у июльских.
-- Выручка: заказы со статусом 1 или 2 (оплачен или ждёт оплаты при получении), без отмен.

-- name: cohort_users
-- одна строка на пользователя когорты: сколько посылок и выручки за 14 дней
WITH cohort AS (
    SELECT user_id, media_source AS platform, os, registered_at
    FROM users
    WHERE registered_at >= DATE '2026-07-01'
      AND registered_at <  DATE '2026-09-01'
)
SELECT
    c.user_id,
    c.platform,
    c.os,
    c.registered_at,
    COUNT(o.order_id)                                                    AS parcels_d14,
    COUNT(DISTINCT CAST(o.created_at AS DATE))                           AS purchase_days_d14,
    COALESCE(SUM(o.price) FILTER (WHERE o.payment_status IN (1, 2)), 0)  AS revenue_d14
FROM cohort c
LEFT JOIN orders o
       ON o.user_id = c.user_id
      AND o.created_at >= c.registered_at
      AND o.created_at <  c.registered_at + INTERVAL 14 DAY
      AND o.payment_status IN (1, 2)
GROUP BY ALL;

-- name: unit_economics
-- метрики по платформе, по платформе x ОС и итог одним запросом (GROUPING SETS)
WITH cohort AS (
    SELECT user_id, media_source AS platform, os, registered_at
    FROM users
    WHERE registered_at >= DATE '2026-07-01'
      AND registered_at <  DATE '2026-09-01'
),
per_user AS (
    SELECT c.platform, c.os, c.user_id,
           COUNT(o.order_id) > 0          AS is_buyer,
           COALESCE(SUM(o.price), 0)      AS revenue
    FROM cohort c
    LEFT JOIN orders o
           ON o.user_id = c.user_id
          AND o.created_at >= c.registered_at
          AND o.created_at <  c.registered_at + INTERVAL 14 DAY
          AND o.payment_status IN (1, 2)
    GROUP BY ALL
),
users_agg AS (
    SELECT platform, os,
           COUNT(*)                          AS regs,
           COUNT(*) FILTER (WHERE is_buyer)  AS buyers,
           SUM(revenue)                      AS revenue
    FROM per_user
    GROUP BY ALL
),
spend AS (
    SELECT platform, os, SUM(spend_usd) AS spend, SUM(installs) AS installs
    FROM ad_spend
    WHERE date BETWEEN DATE '2026-07-01' AND DATE '2026-08-31'
    GROUP BY ALL
),
base AS (
    SELECT u.*, COALESCE(s.spend, 0) AS spend, s.installs
    FROM users_agg u
    LEFT JOIN spend s USING (platform, os)
)
SELECT
    CASE WHEN GROUPING(platform) = 1 THEN 'total' ELSE platform END  AS platform,
    CASE WHEN GROUPING(os) = 1 THEN 'all' ELSE os END                AS os,
    SUM(spend)                                     AS spend,
    SUM(installs)                                  AS installs,
    SUM(regs)                                      AS regs,
    SUM(buyers)                                    AS buyers,
    SUM(revenue)                                   AS revenue_d14,
    SUM(spend) / NULLIF(SUM(installs), 0)          AS cpi,
    SUM(spend) / NULLIF(SUM(regs), 0)              AS cpr,
    SUM(buyers) / SUM(regs)                        AS cr_d14,
    SUM(spend) / NULLIF(SUM(buyers), 0)            AS cac,
    SUM(revenue) / NULLIF(SUM(spend), 0)           AS roas_d14
FROM base
GROUP BY GROUPING SETS ((platform), (platform, os), ())
ORDER BY GROUPING(platform), platform, os;

-- name: os_summary
-- iOS против Android: конверсия по всем пользователям, деньги только по платному трафику
WITH cohort AS (
    SELECT user_id, media_source AS platform, os, registered_at
    FROM users
    WHERE registered_at >= DATE '2026-07-01'
      AND registered_at <  DATE '2026-09-01'
),
per_user AS (
    SELECT c.platform, c.os, c.user_id,
           COUNT(o.order_id) > 0     AS is_buyer,
           COALESCE(SUM(o.price), 0) AS revenue
    FROM cohort c
    LEFT JOIN orders o
           ON o.user_id = c.user_id
          AND o.created_at >= c.registered_at
          AND o.created_at <  c.registered_at + INTERVAL 14 DAY
          AND o.payment_status IN (1, 2)
    GROUP BY ALL
),
spend AS (
    SELECT os, SUM(spend_usd) AS spend FROM ad_spend GROUP BY os
)
SELECT
    p.os,
    COUNT(*)                                                             AS regs,
    AVG(is_buyer::INT)                                                   AS cr_d14_all,
    AVG(is_buyer::INT) FILTER (WHERE platform <> 'organic')              AS cr_d14_paid,
    COUNT(*) FILTER (WHERE platform <> 'organic')                        AS regs_paid,
    COUNT(*) FILTER (WHERE platform <> 'organic' AND is_buyer)           AS buyers_paid,
    ANY_VALUE(s.spend)                                                   AS spend,
    ANY_VALUE(s.spend) / COUNT(*) FILTER (WHERE platform <> 'organic')   AS cpr,
    ANY_VALUE(s.spend) / COUNT(*) FILTER (WHERE platform <> 'organic' AND is_buyer) AS cac,
    SUM(revenue) FILTER (WHERE platform <> 'organic') / ANY_VALUE(s.spend)          AS roas_d14
FROM per_user p
JOIN spend s USING (os)
GROUP BY p.os
ORDER BY p.os DESC;

-- name: ltv_multiplier
-- во сколько раз выручка за 365 дней больше выручки за 14 дней, по старым когортам
-- (регистрации 09.2024-08.2025: у всех уже прошло 12 месяцев)
WITH cohort AS (
    SELECT user_id, media_source AS platform, registered_at
    FROM users
    WHERE registered_at >= DATE '2024-09-01'
      AND registered_at <  DATE '2025-09-01'
),
rev AS (
    SELECT c.platform,
           COUNT(DISTINCT c.user_id)                                                         AS regs,
           SUM(o.price) FILTER (WHERE o.created_at < c.registered_at + INTERVAL 14 DAY)      AS rev_d14,
           SUM(o.price)                                                                      AS rev_d365
    FROM cohort c
    LEFT JOIN orders o
           ON o.user_id = c.user_id
          AND o.created_at >= c.registered_at
          AND o.created_at <  c.registered_at + INTERVAL 365 DAY
          AND o.payment_status IN (1, 2)
    GROUP BY c.platform
)
SELECT platform, regs,
       rev_d14  / regs     AS arpu_d14,
       rev_d365 / regs     AS arpu_d365,
       rev_d365 / rev_d14  AS k_365_to_14
FROM rev
ORDER BY platform;

-- name: weekly_trend
-- недельная динамика регистраций и конверсии по платформам (проверка, что картина не случайна)
WITH per_user AS (
    SELECT u.user_id, u.media_source AS platform,
           DATE_TRUNC('week', u.registered_at) AS week,
           COUNT(o.order_id) > 0 AS is_buyer
    FROM users u
    LEFT JOIN orders o
           ON o.user_id = u.user_id
          AND o.created_at >= u.registered_at
          AND o.created_at <  u.registered_at + INTERVAL 14 DAY
          AND o.payment_status IN (1, 2)
    WHERE u.registered_at >= DATE '2026-06-29'
      AND u.registered_at <  DATE '2026-08-31'
    GROUP BY ALL
)
SELECT week, platform, COUNT(*) AS regs, AVG(is_buyer::INT) AS cr_d14
FROM per_user
GROUP BY ALL
ORDER BY week, platform;
