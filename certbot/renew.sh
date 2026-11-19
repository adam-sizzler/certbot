#!/usr/bin/env sh
set -e

CERT_NAME="$DOMAIN_NAME"
LETSENCRYPT_DIR="/etc/letsencrypt"
LIVE_DIR="/etc/letsencrypt/live/$CERT_NAME"
DHPARAM="$LETSENCRYPT_DIR/dhparam.pem"
HAPROXY_CERT_PATH="$LIVE_DIR/haproxy.pem"
RENEW_INTERVAL="${RENEW_INTERVAL:-12h}"

if [ -z "$CERT_NAME" ]; then
    echo "ERROR: DOMAIN_NAME is empty" >&2
    exit 1
fi

echo "=== Certbot Universal Manager started for $CERT_NAME ==="

# 1. Генерация dhparam — только если включено и файла нет
if [ "$DHPARAM_ENABLED" = "true" ]; then
    if [ ! -f "$DHPARAM" ] || [ ! -s "$DHPARAM" ]; then
        echo "Generating dhparam.pem (2048 bit)..."
        openssl dhparam -out "$DHPARAM" 2048
        chmod 644 "$DHPARAM"
        echo "dhparam.pem ready"
    else
        echo "dhparam.pem already exists — skipped"
    fi
fi

EMAIL_OPT=""
if [ -n "$EMAIL" ]; then
    EMAIL_OPT="--email $EMAIL"
fi

# 2. Первый выпуск сертификата, если его нет
if [ ! -d "$LIVE_DIR" ] || [ ! -f "$LIVE_DIR/fullchain.pem" ]; then
    echo "No certificate found — requesting new one..."
    certbot certonly --non-interactive --agree-tos --expand \
        --dns-cloudflare \
        --dns-cloudflare-credentials /app/cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        --rsa-key-size 4096 \
        -d "$CERT_NAME" \
        -d "*.$CERT_NAME" \
        --cert-name "$CERT_NAME" \
        $EMAIL_OPT

    echo "Initial certificate issued"
else
    echo "Certificate already exists — skipping initial issuance"
    # Если haproxy.pem повреждён — восстанавливаем
    if [ ! -f "$HAPROXY_CERT_PATH" ] || [ ! -s "$HAPROXY_CERT_PATH" ]; then
        echo "haproxy.pem missing or empty — recreating..."
        cat "$LIVE_DIR/fullchain.pem" "$LIVE_DIR/privkey.pem" > "$HAPROXY_CERT_PATH"
        chmod 644 "$HAPROXY_CERT_PATH"
    fi
fi

# 3. Синхронизируем HAProxy (первичная загрузка сертификата).
#    Не фатально: HAProxy может ещё стартовать, синхронизация повторяется в каждом цикле.
if [ ! -s "$LIVE_DIR/fullchain.pem" ] || [ ! -s "$LIVE_DIR/privkey.pem" ]; then
    echo "ERROR: certificate files are missing in $LIVE_DIR" >&2
    exit 1
fi
/app/update-haproxy.sh || echo "WARN: initial HAProxy sync failed, will retry next cycle"

# 4. Бесконечный цикл обновления.
#    PID 1 не получает дефолтных обработчиков сигналов, а `sleep` в foreground их
#    блокирует — без trap `docker stop` ждёт 10 с и убивает контейнер через SIGKILL.
trap 'echo "Signal received, exiting"; exit 0' TERM INT

echo "Starting renew loop (every ${RENEW_INTERVAL})..."
while true; do
    echo "[$(date)] Running certbot renew..."
    certbot renew || echo "WARN: certbot renew failed, will retry next cycle"

    # Синхронизация — ВСЕГДА, а не из --deploy-hook: хук срабатывает только в момент
    # фактического продления, и если HAProxy тогда не принял сертификат, на следующем
    # цикле certbot скажет "not yet due" и HAProxy остался бы со старым сертификатом.
    /app/update-haproxy.sh || echo "WARN: HAProxy sync failed, will retry next cycle"

    echo "[$(date)] Sleeping ${RENEW_INTERVAL}..."
    sleep "${RENEW_INTERVAL}" &
    wait $!
done
