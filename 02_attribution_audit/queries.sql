-- Кейс 2. Сверка выгрузки событий из MMP с внутренней базой, август 2026.
-- База пишет время в UTC+5 (Алматы), MMP отдаёт UTC.
-- Выгрузка MMP пришла двумя отчётами: неорганика и органика. Сначала взяли только первый.

-- name: naive_compare
-- первая попытка: база против неорганического отчёта MMP, август по календарю каждой системы
WITH db AS (
    SELECT 'af_complete_registration' AS event_name, COUNT(*) AS db_cnt
    FROM users
    WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
    UNION ALL
    SELECT 'af_purchase', COUNT(*)
    FROM orders
    WHERE created_at >= DATE '2026-08-01' AND created_at < DATE '2026-09-01'
),
mmp AS (
    SELECT event_name, COUNT(*) AS mmp_cnt
    FROM mmp_events_nonorganic
    WHERE event_time >= DATE '2026-08-01' AND event_time < DATE '2026-09-01'
    GROUP BY event_name
)
SELECT db.event_name, db_cnt, mmp_cnt, mmp_cnt / db_cnt AS mmp_to_db
FROM db JOIN mmp USING (event_name)
ORDER BY event_name;

-- name: mmp_clean
-- единая таблица событий MMP: оба отчёта, нормализованный id, местное время, флаг дубля
WITH all_events AS (
    SELECT *, 'nonorganic' AS report FROM mmp_events_nonorganic
    UNION ALL
    SELECT *, 'organic' AS report FROM mmp_events_organic
)
SELECT
    event_time                                              AS event_time_utc,
    event_time + INTERVAL 5 HOUR                            AS event_time_local,
    event_name,
    customer_user_id                                        AS cuid_raw,
    TRY_CAST(NULLIF(TRIM(customer_user_id), '') AS BIGINT)  AS user_id,   -- '00123 ' -> 123
    platform,
    country_code,
    media_source,
    order_id,
    event_revenue_usd,
    report,
    -- order_id не уникален между каналами (см. кейс 5), поэтому ключ покупки = order_id + сумма
    ROW_NUMBER() OVER (
        PARTITION BY event_name,
                     COALESCE(CAST(order_id AS VARCHAR) || '|' || CAST(event_revenue_usd AS VARCHAR),
                              customer_user_id || '|' || CAST(event_time AS VARCHAR))
        ORDER BY event_time
    ) > 1                                                   AS is_duplicate
FROM all_events;

-- name: timezone_shift
-- сколько событий меняют месяц, если перевести UTC в местное время
SELECT
    event_name,
    COUNT(*) FILTER (WHERE event_time_utc   >= DATE '2026-08-01' AND event_time_utc   < DATE '2026-09-01') AS aug_by_utc,
    COUNT(*) FILTER (WHERE event_time_local >= DATE '2026-08-01' AND event_time_local < DATE '2026-09-01') AS aug_by_local,
    COUNT(*) FILTER (WHERE CAST(event_time_utc AS DATE) <> CAST(event_time_local AS DATE))                  AS day_changes,
    COUNT(*)                                                                                                AS total
FROM mmp
GROUP BY event_name
ORDER BY event_name;

-- name: hourly_shift
-- распределение событий по часу: база в местном времени, MMP в UTC
SELECT 'База (UTC+5)' AS source, HOUR(registered_at) AS hour, COUNT(*) AS n
FROM users
WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
GROUP BY ALL
UNION ALL
SELECT 'MMP (UTC)', HOUR(event_time_utc), COUNT(*)
FROM mmp
WHERE event_name = 'af_complete_registration'
  AND event_time_utc >= DATE '2026-08-01' AND event_time_utc < DATE '2026-09-01'
GROUP BY ALL
ORDER BY source, hour;

-- name: coverage_by_user
-- какая доля пользователей базы (регистрации августа) найдена в MMP хоть одним событием
WITH db_users AS (
    SELECT user_id, media_source, os, country
    FROM users
    WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
),
mmp_ids AS (
    SELECT DISTINCT user_id, report FROM mmp WHERE user_id IS NOT NULL
),
mmp_raw_ids AS (
    -- наивный матч строкой, без очистки
    SELECT DISTINCT cuid_raw FROM mmp WHERE report = 'nonorganic'
)
SELECT
    d.media_source,
    COUNT(*)                                                                    AS db_users,
    AVG((r.cuid_raw IS NOT NULL)::INT)                                          AS cov_nonorganic_raw,
    AVG((EXISTS (SELECT 1 FROM mmp_ids m WHERE m.user_id = d.user_id AND m.report = 'nonorganic'))::INT) AS cov_nonorganic_clean,
    AVG((EXISTS (SELECT 1 FROM mmp_ids m WHERE m.user_id = d.user_id))::INT)    AS cov_both_reports
FROM db_users d
LEFT JOIN mmp_raw_ids r ON r.cuid_raw = CAST(d.user_id AS VARCHAR)
GROUP BY ROLLUP (d.media_source)
ORDER BY d.media_source NULLS LAST;

-- name: id_quality
-- что не так с customer_user_id
SELECT
    CASE
        WHEN cuid_raw = ''                         THEN 'пустой (событие до логина)'
        WHEN cuid_raw <> TRIM(cuid_raw)            THEN 'пробел в конце'
        WHEN cuid_raw LIKE '0%'                    THEN 'ведущие нули'
        ELSE 'корректный'
    END                     AS id_format,
    COUNT(*)                AS events,
    COUNT(*) / SUM(COUNT(*)) OVER () AS share
FROM mmp
GROUP BY 1
ORDER BY events DESC;

-- name: purchase_match
-- посылка за посылкой: заказы базы августа против af_purchase (время MMP переведено в UTC+5)
WITH db AS (
    SELECT o.order_id, o.price, o.user_id, u.os
    FROM orders o
    JOIN users u USING (user_id)
    WHERE o.created_at >= DATE '2026-08-01' AND o.created_at < DATE '2026-09-01'
),
ev AS (
    SELECT order_id, event_revenue_usd AS price, user_id, platform, is_duplicate
    FROM mmp
    WHERE event_name = 'af_purchase'
      AND event_time_local >= DATE '2026-08-01' AND event_time_local < DATE '2026-09-01'
),
ev_unique AS (
    SELECT order_id, price, platform, COUNT(*) AS copies
    FROM ev
    GROUP BY order_id, price, platform
)
SELECT
    db.os,
    COUNT(*)                                                    AS db_orders,
    COUNT(e.order_id)                                           AS matched,
    COUNT(e.order_id) / COUNT(*)                                AS match_rate,
    (SELECT COUNT(*) FROM ev WHERE ev.platform = db.os)         AS mmp_events_raw,
    (SELECT COUNT(*) FROM ev WHERE ev.platform = db.os AND is_duplicate) AS mmp_duplicates,
    (SELECT COUNT(*) FROM ev WHERE ev.platform = db.os) / COUNT(*)       AS raw_to_db
FROM db
LEFT JOIN ev_unique e
       ON e.order_id = db.order_id
      AND e.price = db.price
      AND e.platform = db.os
GROUP BY db.os
ORDER BY db.os DESC;

-- name: geo_compare
-- регистрации по стране: страна пользователя в базе против страны по IP в MMP.
-- только пользователи, найденные в обеих системах, чтобы видеть эффект гео, а не покрытия
WITH db AS (
    SELECT user_id, country
    FROM users
    WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
),
ev AS (
    SELECT user_id, ANY_VALUE(country_code) AS country_ip
    FROM mmp
    WHERE event_name = 'af_complete_registration' AND user_id IS NOT NULL
    GROUP BY user_id
),
j AS (
    SELECT db.user_id, db.country, ev.country_ip
    FROM db JOIN ev USING (user_id)
)
SELECT
    country,
    COUNT(*)                                                     AS users_matched,
    COUNT(*) FILTER (WHERE country_ip = country)                 AS mmp_same_country,
    COUNT(*) FILTER (WHERE country_ip = country) / COUNT(*) - 1  AS mmp_country_gap,
    STRING_AGG(DISTINCT country_ip, ', ' ORDER BY country_ip) FILTER (WHERE country_ip <> country) AS other_countries
FROM j
GROUP BY country
ORDER BY users_matched DESC;

-- name: geo_by_ip_country
-- куда "уехали" пользователи по версии MMP
WITH db AS (
    SELECT user_id, country FROM users
    WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
),
ev AS (
    SELECT user_id, ANY_VALUE(country_code) AS country_ip
    FROM mmp
    WHERE event_name = 'af_complete_registration' AND user_id IS NOT NULL
    GROUP BY user_id
)
SELECT db.country AS country_db, ev.country_ip, COUNT(*) AS users
FROM db JOIN ev USING (user_id)
WHERE ev.country_ip <> db.country
GROUP BY ALL
ORDER BY country_db, users DESC;

-- name: final_compare
-- итоговая сверка после всех поправок
WITH db AS (
    SELECT 'af_complete_registration' AS event_name, COUNT(*) AS db_cnt
    FROM users
    WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
    UNION ALL
    SELECT 'af_purchase', COUNT(*)
    FROM orders
    WHERE created_at >= DATE '2026-08-01' AND created_at < DATE '2026-09-01'
),
m AS (
    SELECT event_name,
           COUNT(*) FILTER (WHERE report = 'nonorganic'
                              AND event_time_utc >= DATE '2026-08-01' AND event_time_utc < DATE '2026-09-01') AS step0_nonorganic_utc,
           COUNT(*) FILTER (WHERE event_time_utc >= DATE '2026-08-01' AND event_time_utc < DATE '2026-09-01') AS step1_plus_organic,
           COUNT(*) FILTER (WHERE event_time_local >= DATE '2026-08-01' AND event_time_local < DATE '2026-09-01') AS step2_local_time,
           COUNT(*) FILTER (WHERE event_time_local >= DATE '2026-08-01' AND event_time_local < DATE '2026-09-01'
                              AND NOT is_duplicate) AS step3_no_duplicates
    FROM mmp
    GROUP BY event_name
)
SELECT db.event_name, db.db_cnt, m.* EXCLUDE (event_name)
FROM db JOIN m USING (event_name)
ORDER BY db.event_name;

-- name: coverage_by_country
-- покрытие по id в разрезе страны из базы: если оно ровное, разрыв в гео-отчёте дают не потери, а IP
WITH db AS (
    SELECT user_id, country FROM users
    WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
),
ids AS (SELECT DISTINCT user_id FROM mmp WHERE user_id IS NOT NULL)
SELECT db.country,
       COUNT(*) AS db_users,
       AVG((ids.user_id IS NOT NULL)::INT) AS coverage_by_id
FROM db LEFT JOIN ids USING (user_id)
GROUP BY db.country
ORDER BY db_users DESC;

-- name: daily_tz_error
-- дневные регистрации: база против MMP по дате UTC и по дате UTC+5
WITH db AS (
    SELECT CAST(registered_at AS DATE) AS day, COUNT(*) AS db_cnt
    FROM users
    WHERE registered_at >= DATE '2026-08-01' AND registered_at < DATE '2026-09-01'
    GROUP BY 1
),
m_utc AS (
    SELECT CAST(event_time_utc AS DATE) AS day, COUNT(*) AS mmp_utc
    FROM mmp WHERE event_name = 'af_complete_registration' GROUP BY 1
),
m_loc AS (
    SELECT CAST(event_time_local AS DATE) AS day, COUNT(*) AS mmp_local
    FROM mmp WHERE event_name = 'af_complete_registration' GROUP BY 1
)
SELECT day, db_cnt, mmp_utc, mmp_local,
       mmp_utc   / db_cnt - 1 AS err_utc,
       mmp_local / db_cnt - 1 AS err_local
FROM db LEFT JOIN m_utc USING (day) LEFT JOIN m_loc USING (day)
ORDER BY day;
