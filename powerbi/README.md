# Дашборд в Power BI по данным портфолио

Файла `.pbix` в репозитории нет: он бинарный и плохо живёт в git. Ниже шаги, по которым дашборд собирается за 20-30 минут из тех же CSV. Все меры написаны DAX-ом и считают то же, что SQL в кейсах, поэтому цифры можно сверить с README кейсов.

## 1. Данные

```bash
python data_gen/generate.py --csv
```

CSV появятся в `data/csv/`. Для дашборда нужны `users.csv`, `orders.csv` (чистая витрина, не `orders_raw`), `ad_spend.csv`, `offline_events.csv`.

## 2. Power Query

**users**: типы `user_id` целое, `registered_at` дата и время. Добавить столбцы:
- `reg_date` = `DateTime.Date([registered_at])`;
- `is_paid` = `[media_source] <> "organic"`.

**orders**: типы, затем:
- `order_date` = `DateTime.Date([created_at])`;
- `purchase_key` = `Text.From([user_id]) & "|" & Date.ToText([order_date], "yyyy-MM-dd")`. Одна покупка = пользователь x день заказа (см. кейс 3), по этому ключу считаются покупки.

**ad_spend**: `date` дата, `spend_usd` десятичное.

**Первая покупка за 14 дней** проще посчитать в Power Query, чем мерой: сгруппировать `orders` по `user_id` с минимумом `created_at` (только статусы 1 и 2), слить с `users` и добавить столбец
`buyer_d14 = [first_order_at] <> null and [first_order_at] < [registered_at] + #duration(14, 0, 0, 0)`.
Так же можно добавить `revenue_d14` (сумма `price` заказов в первые 14 дней).

## 3. Модель

Два календаря: по дате регистрации (для когорт и расходов) и по дате заказа (для выручки). Один общий календарь со связями и на `users`, и на `orders` даёт два пути фильтра до `orders` (напрямую и через `users`), и Power BI не даст сделать обе связи активными.

```
'Reg Date'   1 ── * users[reg_date]
'Reg Date'   1 ── * ad_spend[date]
'Order Date' 1 ── * orders[order_date]
users[user_id] 1 ── * orders[user_id]
Platform     1 ── * users[media_source]
Platform     1 ── * ad_spend[platform]
OS           1 ── * users[os]
OS           1 ── * ad_spend[os]
```

`Platform` и `OS` это маленькие справочники (`DISTINCT` из `users`), чтобы один срез фильтровал и расходы, и пользователей.

```dax
Reg Date = CALENDAR ( DATE ( 2023, 1, 1 ), DATE ( 2026, 9, 30 ) )
Order Date = CALENDAR ( DATE ( 2023, 1, 1 ), DATE ( 2026, 9, 30 ) )
```

## 4. Меры

```dax
-- базовые
Registrations = COUNTROWS ( users )
Paid Registrations = CALCULATE ( [Registrations], users[is_paid] = TRUE () )
Spend = SUM ( ad_spend[spend_usd] )
Installs = SUM ( ad_spend[installs] )

-- выручка (кейс 5: статус 2 = оплачен, 1 = ждёт оплаты, 0 = отмена)
Revenue Paid = CALCULATE ( SUM ( orders[price] ), orders[payment_status] = 2 )
Revenue Booked = CALCULATE ( SUM ( orders[price] ), orders[payment_status] IN { 1, 2 } )
Paid Share = DIVIDE ( [Revenue Paid], [Revenue Booked] )

-- покупки по дням заказа, а не по посылкам (кейс 3)
Purchases = CALCULATE ( DISTINCTCOUNT ( orders[purchase_key] ), orders[payment_status] IN { 1, 2 } )
Parcels per Purchase =
    DIVIDE ( CALCULATE ( COUNTROWS ( orders ), orders[payment_status] IN { 1, 2 } ), [Purchases] )

-- юнит-экономика когорты регистраций (кейс 1)
Buyers D14 = CALCULATE ( [Registrations], users[buyer_d14] = TRUE () )
CR D14 = DIVIDE ( [Buyers D14], [Registrations] )
Revenue D14 = SUM ( users[revenue_d14] )
CPI = DIVIDE ( [Spend], [Installs] )
CPR = DIVIDE ( [Spend], [Paid Registrations] )
CAC =
    DIVIDE ( [Spend], CALCULATE ( [Buyers D14], users[is_paid] = TRUE () ) )
ROAS D14 =
    DIVIDE ( CALCULATE ( [Revenue D14], users[is_paid] = TRUE () ), [Spend] )

-- iOS против Android
CR iOS / Android =
    DIVIDE ( CALCULATE ( [CR D14], OS[os] = "ios" ),
             CALCULATE ( [CR D14], OS[os] = "android" ) )
```

Меры юнит-экономики надо смотреть на периоде регистраций, у которых 14 дней уже прошли: срез по `'Reg Date'` с концом не позже даты выгрузки минус 14 дней.

## 5. Страницы

1. **Каналы**: таблица по `Platform` (Spend, Registrations, CPI, CPR, CR D14, CAC, ROAS D14), столбчатая диаграмма 100% "доля в расходе / регистрациях / покупателях", срез по `OS`.
2. **Когорты**: матрица "месяц регистрации x месяц после регистрации" с условным форматированием. Для номера месяца добавить в `orders` столбец `month_n = DATEDIFF ( RELATED ( users[reg_date] ), orders[order_date], MONTH )` и меру `DISTINCTCOUNT ( orders[user_id] ) / [Registrations]`.
3. **Выручка**: Revenue Paid и Revenue Booked по месяцам на одном графике и Paid Share. Разрыв в последних месяцах показывает незрелость текущего месяца.

## 6. Проверка

С данными генератора по умолчанию на странице "Каналы" за 01.07-31.08.2026 должно получиться: расход по платным $19 791, CAC Google $11.7, Meta $236, CR D14 iOS 18.3%, Android 9.1%. Если цифры не сходятся, чаще всего срез стоит не на том календаре (`'Order Date'` вместо `'Reg Date'`) или покупки посчитаны по `order_id`.
