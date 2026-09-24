-- Проверки качества таблицы заказов. Каждая проверка возвращает число нарушений, норма = 0.
-- {t} заменяется на имя проверяемой таблицы (orders, orders_dedup, ...).

-- name: unique_key
-- ключ (created_at, order_id) уникален
SELECT COUNT(*) - COUNT(DISTINCT (created_at, order_id)) FROM {t};

-- name: status_domain
-- статус оплаты только 0, 1, 2
SELECT COUNT(*) FROM {t} WHERE payment_status NOT IN (0, 1, 2) OR payment_status IS NULL;

-- name: price_positive
-- цена доставки положительная и не пустая
SELECT COUNT(*) FROM {t} WHERE price IS NULL OR price <= 0;

-- name: updated_after_created
-- версия строки не старше самого заказа
SELECT COUNT(*) FROM {t} WHERE updated_at < created_at;

-- name: user_exists
-- у каждого заказа есть пользователь
SELECT COUNT(*) FROM {t} o WHERE NOT EXISTS (SELECT 1 FROM users u WHERE u.user_id = o.user_id);

-- name: order_after_registration
-- заказ не раньше регистрации
SELECT COUNT(*) FROM {t} o JOIN users u USING (user_id) WHERE o.created_at < u.registered_at;

-- name: price_per_kg_stable
-- медиана цены за кг в месяце канала не уходит больше чем на 50% от трёх прошлых месяцев
WITH m AS (
    SELECT channel, DATE_TRUNC('month', created_at) AS month, MEDIAN(price / weight_kg) AS ppk
    FROM {t} GROUP BY ALL
),
w AS (
    SELECT *, MEDIAN(ppk) OVER (PARTITION BY channel ORDER BY month ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING) AS prev3
    FROM m
)
SELECT COUNT(*) FROM w WHERE ABS(ppk / prev3 - 1) > 0.5;

-- name: closed_month_paid
-- в закрытых месяцах (заказ старше 45 дней) неоплаченных меньше 2%
SELECT COUNT(*) FROM (
    SELECT DATE_TRUNC('month', created_at) AS month, AVG((payment_status = 1)::INT) AS unpaid
    FROM {t}
    WHERE created_at < DATE '2026-09-14' - INTERVAL 45 DAY
    GROUP BY 1
) WHERE unpaid > 0.02;
