# remnawave/paywall/ — сквад «только оплата»

Истёкший клиент без денег не отключается, а уходит во внутренний сквад `paywall` (web-tech §3). Его VPN пускает только к нашим доменам, платёжкам и DoH, чтобы он мог оплатить и написать в поддержку без чужого VPN. Остальное, Telegram тоже, получает `block`.

## Файлы

| Файл | Роль |
|---|---|
| `allowlist.json` | белый список: домены (`domain:` берёт и поддомены) и IP DNS-резолверов |
| `add-to-profile.jq` | добавляет в конфиг профиля инбаунд `PAYWALL-IN-<НОДА>` (копия инбаунда ноды со своим тегом, портом и путём) и пересобирает правила paywall; повтор с тем же тегом заменяет инбаунд |
| `nginx-location.conf` | путь paywall на origin за CDN: свой upstream и `location` рядом с туннельным |

## Как устроено

- Обычная нода: копия её Reality-инбаунда на отдельном TCP-порту (443 занят основным). Ключи, сайт self-steal и shortId те же, хост в панели копирует хост основного инбаунда с другим портом. xray предупреждает, что Reality не на 443 заметнее для DPI, поэтому paywall стоит на одной ноде, а не на всех.
- Нода LTE за CDN: копия её xhttp-инбаунда на `127.0.0.1:4444` с путём `/api/v3.jpg`. CDN пропускает любой путь к origin, поэтому край, SNI и Host те же, что у туннеля ноды, а nginx origin разводит пути по портам xray. Хост копирует хост ноды (тот же `extra`) с другим путём.
- Маршрутизация: правила профиля остаются первыми (они только блокируют: частные сети, торренты, QUIC на CDN-профилях), за ними три правила paywall: домены → `DIRECT`, IP резолверов → `DIRECT`, всё остальное с инбаундов paywall → `BLOCK`. Sniffing инбаунда: `http`, `tls`, `quic`, `routeOnly`.
- Белый список: `trojanvpn.net` (app., help., api., sub.), ЮKassa (`yookassa.ru`, `yoomoney.ru`, `yastatic.net`, `qr.nspk.ru`), `heleket.com`, DoH (`cloudflare-dns.com`, `one.one.one.one`, `dns.google`) и IP 1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4 для DNS без имени (UDP 53, DoH по IP).

## Шаги в панели

Каждое изменение профиля и инбаундов ноды перезапускает xray на нодах профиля: живые клиенты переподключаются. Одна нода за раз, в тихий час, после каждой ноды проверить, что она снова online.

1. Origin за CDN (без влияния на клиентов): snippet и `location` из `nginx-location.conf`, `nginx -t`, `systemctl reload nginx`. До шага 2 путь отвечает 502.
2. Профиль: `GET /api/config-profiles/{uuid}`, взять `.response.config`, прогнать через `add-to-profile.jq`, проверить на ноде `docker exec -i remnanode rw-core run -test -config stdin:`, отправить `PATCH /api/config-profiles` с `{uuid, config}`.
3. Нода: новый инбаунд панель сама в ноду не включает. `PATCH /api/nodes` с `configProfile.activeInbounds`, к прежним добавить UUID нового инбаунда. Это второй перезапуск xray.
4. Сквад `paywall` (`POST /api/internal-squads`) со всеми инбаундами `PAYWALL-IN-*`. Его UUID идёт в `REMNAWAVE_PAYWALL_SQUAD_UUID` cybervpn-api (окружение, не репозиторий).
5. Хосты: по одному на инбаунд, копия хоста основного инбаунда ноды (адрес, SNI, Host, `extra`, шаблон JSON) с портом или путём paywall.

## Проверка

Тестовый пользователь в одном скваде `paywall`, подписка с `x-hwid`, локальный xray с исходящим из подписки (на Mac с TUN-VPN `sockopt.interface en0`). Должно открываться: app., help., api.trojanvpn.net, форма ЮKassa (СБП и карта), страница Heleket, DoH. Не должно: google.com, telegram.org, api.telegram.org, IP Telegram.

## Банки при СБП (O3)

Шаблон подписки JSON, который получают Happ и Incy, уже отправляет мимо туннеля `geosite:category-ru`, `.ru`, `.рф`, `geoip:ru` и домены банков (Т-Банк, Сбер, ВТБ, Альфа, ОТП). Приложение банка и сама форма ЮKassa (`.ru`) идут с телефона напрямую, туннель paywall их не видит. Серверное `geoip:ru → direct` не нужно: часть банков режет зарубежные IP, а выход через ноду и есть зарубежный IP. Клиенты без нашего JSON (base64-ссылки, sing-box, mihomo) идут целиком в туннель, им ЮKassa открывает белый список.
