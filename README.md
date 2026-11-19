# certbot

Контейнер выпускает/обновляет wildcard-сертификат через Cloudflare DNS challenge
и обновляет сертификат в HAProxy через Runtime API (`/var/run/haproxy/haproxy.sock`).

Обязательные переменные окружения:

- `DOMAIN_NAME`
- `DNS_CLOUDFLARE_API_TOKEN`

Опционально для обновления через HAProxy Runtime API:

- `HAPROXY_SOCKET_RETRIES` (по умолчанию `5`)
- `HAPROXY_SOCKET_RETRY_DELAY` (по умолчанию `30` сек)
- `HAPROXY_SOCKET_TIMEOUT` (по умолчанию `3` сек)
- `RENEW_INTERVAL` (по умолчанию `12h`)

После каждого цикла `certbot renew` (не только при фактическом продлении) `update-haproxy.sh` сравнивает serial сертификата, который HAProxy держит в памяти (`show ssl cert`), с serial в `haproxy.pem` на диске и при расхождении загружает новый через Runtime API. Ответ HAProxy проверяется (`Success!`), после коммита serial перепроверяется. Если сокет недоступен или HAProxy вернул ошибку, контейнер делает ограниченное число попыток, пишет warning/error и продолжает работу; следующая попытка — на следующем цикле renew. Вручную то же самое делает `docker exec <container> /app/update-haproxy.sh`.

Рекомендуемые volume:

- `letsencrypt:/etc/letsencrypt`
- `haproxy-socket:/var/run/haproxy`
