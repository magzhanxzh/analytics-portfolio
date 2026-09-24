-- Кейс 4. ROMI офлайн-ивентов без трекинга лидов.
-- У ивента нет промокода и ссылки: пришедшие пользователи попадают в базу как organic.
-- Эффект оцениваем по приросту регистраций в городе ивента против медианы соседних дней.
-- Окно ивента = дни ивента + 2 дня хвоста. База = медиана дневных регистраций за 14 дней
-- до и 14 дней после окна, сами дни окна в базу не входят.

-- name: daily_city
-- дневные регистрации по городам
SELECT city, CAST(registered_at AS DATE) AS day, COUNT(*) AS regs
FROM users
GROUP BY ALL
ORDER BY city, day;

-- name: event_uplift
WITH ev AS (
    SELECT *, CAST(end_date + INTERVAL 2 DAY AS DATE) AS window_end
    FROM offline_events
),
daily AS (
    SELECT city, CAST(registered_at AS DATE) AS day, COUNT(*) AS regs
    FROM users
    GROUP BY ALL
),
baseline AS (
    SELECT ev.event_id,
           MEDIAN(d.regs)  AS baseline_per_day,
           COUNT(*)        AS baseline_days
    FROM ev
    JOIN daily d
      ON d.city = ev.city
     AND d.day BETWEEN ev.start_date - INTERVAL 14 DAY AND ev.window_end + INTERVAL 14 DAY
     AND d.day NOT BETWEEN ev.start_date AND ev.window_end
    GROUP BY ev.event_id
),
win AS (
    SELECT ev.event_id, SUM(d.regs) AS regs_window, COUNT(*) AS window_days
    FROM ev
    JOIN daily d
      ON d.city = ev.city
     AND d.day BETWEEN ev.start_date AND ev.window_end
    GROUP BY ev.event_id
)
SELECT ev.event_id, ev.event_name, ev.city, ev.start_date, ev.window_end, ev.cost_usd,
       w.window_days, w.regs_window, b.baseline_per_day, b.baseline_days,
       w.regs_window - b.baseline_per_day * w.window_days AS uplift_regs
FROM ev
JOIN win w USING (event_id)
JOIN baseline b USING (event_id)
ORDER BY ev.event_id;

-- name: baseline_arpu
-- выручка на регистрацию у обычных пользователей того же города в базовые дни
-- (30 дней от регистрации и всё время до выгрузки)
WITH ev AS (
    SELECT *, CAST(end_date + INTERVAL 2 DAY AS DATE) AS window_end
    FROM offline_events
),
base_users AS (
    SELECT ev.event_id, u.user_id, u.registered_at
    FROM ev
    JOIN users u
      ON u.city = ev.city
     AND CAST(u.registered_at AS DATE) BETWEEN ev.start_date - INTERVAL 14 DAY AND ev.window_end + INTERVAL 14 DAY
     AND CAST(u.registered_at AS DATE) NOT BETWEEN ev.start_date AND ev.window_end
),
rev AS (
    SELECT b.event_id, b.user_id,
           COALESCE(SUM(o.price) FILTER (WHERE o.created_at < b.registered_at + INTERVAL 30 DAY), 0) AS rev_30,
           COALESCE(SUM(o.price), 0)                                                              AS rev_life
    FROM base_users b
    LEFT JOIN orders o
           ON o.user_id = b.user_id
          AND o.created_at >= b.registered_at
          AND o.payment_status IN (1, 2)
    GROUP BY ALL
)
SELECT event_id,
       COUNT(*)       AS base_users,
       AVG(rev_30)    AS arpu_30,
       AVG(rev_life)  AS arpu_lifetime
FROM rev
GROUP BY event_id
ORDER BY event_id;

-- name: paid_cpr
-- цена регистрации в платном таргете, июль-август 2026
WITH s AS (SELECT SUM(spend_usd) AS spend FROM ad_spend),
r AS (
    SELECT COUNT(*) AS paid_regs
    FROM users
    WHERE media_source <> 'organic'
      AND registered_at >= DATE '2026-07-01' AND registered_at < DATE '2026-09-01'
)
SELECT spend, paid_regs, spend / paid_regs AS cpr
FROM s CROSS JOIN r;

-- name: budget_share
-- "метод" распределения: выручка месяца x доля ивента в маркетинговом бюджете месяца
WITH m AS (
    SELECT month,
           SUM(amount_usd)                                             AS budget_total,
           SUM(amount_usd) FILTER (WHERE item = 'offline_event')       AS budget_offline
    FROM marketing_budget
    GROUP BY month
),
rev AS (
    SELECT DATE_TRUNC('month', created_at) AS month,
           SUM(price) FILTER (WHERE payment_status = 2) AS revenue
    FROM orders
    GROUP BY 1
)
SELECT ev.event_id, ev.event_name, ev.cost_usd,
       m.budget_total,
       ev.cost_usd / m.budget_total              AS budget_share,
       rev.revenue                               AS month_revenue,
       rev.revenue * ev.cost_usd / m.budget_total AS attributed_revenue,
       rev.revenue * ev.cost_usd / m.budget_total / ev.cost_usd - 1 AS romi_budget_share
FROM offline_events ev
JOIN m   ON m.month   = DATE_TRUNC('month', ev.start_date)
JOIN rev ON rev.month = DATE_TRUNC('month', ev.start_date)
ORDER BY ev.event_id;
