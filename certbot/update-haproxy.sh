#!/usr/bin/env sh
#
# Приводит HAProxy в соответствие с сертификатом certbot'а:
#   1. пересобирает haproxy.pem (fullchain + privkey), если он отличается от live;
#   2. сравнивает serial сертификата, который HAProxy реально держит в памяти,
#      с serial на диске и, если они расходятся, загружает новый через Runtime API;
#   3. проверяет ответ HAProxy и итоговый serial — socat возвращает 0 даже тогда,
#      когда HAProxy ответил ошибкой.
#
# Скрипт идемпотентный и вызывается после КАЖДОГО цикла certbot renew, а не только
# при фактическом продлении. Код возврата != 0, если HAProxy не принял сертификат.

LIVE_DIR="/etc/letsencrypt/live/$DOMAIN_NAME"
HAPROXY_CERT_PATH="$LIVE_DIR/haproxy.pem"
SOCKET_PATH="/var/run/haproxy/haproxy.sock"
MAX_RETRIES="${HAPROXY_SOCKET_RETRIES:-5}"
RETRY_DELAY="${HAPROXY_SOCKET_RETRY_DELAY:-30}"
SOCKET_TIMEOUT="${HAPROXY_SOCKET_TIMEOUT:-3}"

if [ -z "${DOMAIN_NAME:-}" ]; then
    echo "ERROR: DOMAIN_NAME is empty — cannot update HAProxy cert" >&2
    exit 1
fi

if [ ! -s "$LIVE_DIR/fullchain.pem" ] || [ ! -s "$LIVE_DIR/privkey.pem" ]; then
    echo "ERROR: certificate files not found in $LIVE_DIR" >&2
    exit 1
fi

# Совмещённый PEM собираем во временный файл и подменяем атомарно,
# чтобы HAProxy (reload) никогда не прочитал наполовину записанный файл.
TMP_PEM="$HAPROXY_CERT_PATH.tmp"
cat "$LIVE_DIR/fullchain.pem" "$LIVE_DIR/privkey.pem" > "$TMP_PEM" || {
    echo "ERROR: cannot assemble $HAPROXY_CERT_PATH" >&2
    rm -f "$TMP_PEM"
    exit 1
}
chmod 644 "$TMP_PEM"
if cmp -s "$TMP_PEM" "$HAPROXY_CERT_PATH"; then
    rm -f "$TMP_PEM"
else
    mv -f "$TMP_PEM" "$HAPROXY_CERT_PATH"
    echo "haproxy.pem rebuilt from $LIVE_DIR"
fi

# Serial в одном формате: HEX в верхнем регистре без ведущих нулей.
normalize_serial() {
    tr 'a-f' 'A-F' | sed 's/^0*//'
}

disk_serial() {
    openssl x509 -in "$HAPROXY_CERT_PATH" -noout -serial 2>/dev/null \
        | sed 's/^serial=//' | normalize_serial
}

haproxy_serial() {
    printf 'show ssl cert %s\n' "$HAPROXY_CERT_PATH" \
        | socat -T "$SOCKET_TIMEOUT" "UNIX-CONNECT:$SOCKET_PATH" - 2>/dev/null \
        | awk '/^Serial:/ { print $2; exit }' | normalize_serial
}

# Отменяет открытую транзакцию: иначе следующий set ssl cert упрётся в неё.
abort_transaction() {
    printf 'abort ssl cert %s\n' "$HAPROXY_CERT_PATH" \
        | socat -T "$SOCKET_TIMEOUT" "UNIX-CONNECT:$SOCKET_PATH" - >/dev/null 2>&1
    return 0
}

push_cert() {
    # Шаг 1: загрузить новый PEM в HAProxy (создаёт транзакцию).
    # Payload терминируется пустой строкой. Отдельная сессия socat.
    out=$({
        printf 'set ssl cert %s <<\n' "$HAPROXY_CERT_PATH"
        cat "$HAPROXY_CERT_PATH"
        printf '\n\n'
    } | socat -T "$SOCKET_TIMEOUT" "UNIX-CONNECT:$SOCKET_PATH" - 2>&1)
    rc=$?
    echo "$out"
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    case "$out" in
        *"Transaction created"*) ;;
        *) abort_transaction; return 1 ;;
    esac

    # Шаг 2: закоммитить транзакцию (активирует новый сертификат).
    # Обязательно отдельная сессия — иначе HAProxy не обработает commit.
    out=$(printf 'commit ssl cert %s\n' "$HAPROXY_CERT_PATH" \
        | socat -T "$SOCKET_TIMEOUT" "UNIX-CONNECT:$SOCKET_PATH" - 2>&1)
    rc=$?
    echo "$out"
    if [ "$rc" -ne 0 ]; then
        abort_transaction
        return 1
    fi
    case "$out" in
        *"Success!"*) return 0 ;;
        *) abort_transaction; return 1 ;;
    esac
}

DISK_SERIAL=$(disk_serial)
if [ -z "$DISK_SERIAL" ]; then
    echo "ERROR: cannot read serial of $HAPROXY_CERT_PATH" >&2
    exit 1
fi

attempt=1
while [ "$attempt" -le "$MAX_RETRIES" ]; do
    if [ -S "$SOCKET_PATH" ]; then
        LOADED_SERIAL=$(haproxy_serial)
        if [ "$LOADED_SERIAL" = "$DISK_SERIAL" ]; then
            echo "HAProxy already serves the current certificate (serial $DISK_SERIAL)."
            exit 0
        fi
        echo "HAProxy serial '${LOADED_SERIAL:-unknown}' != disk serial '$DISK_SERIAL'; updating via Runtime API (attempt $attempt/$MAX_RETRIES)..."
        if push_cert; then
            LOADED_SERIAL=$(haproxy_serial)
            if [ "$LOADED_SERIAL" = "$DISK_SERIAL" ]; then
                echo "Certificate updated in HAProxy memory (serial $DISK_SERIAL)."
                exit 0
            fi
            echo "WARN: HAProxy accepted the commit but still reports serial '${LOADED_SERIAL:-unknown}'."
        else
            echo "WARN: Runtime API update failed."
        fi
    else
        echo "WARN: HAProxy socket not ready ($SOCKET_PATH)."
    fi
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        echo "Retrying in ${RETRY_DELAY}s..."
        sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
done

echo "ERROR: HAProxy does not serve the current certificate after ${MAX_RETRIES} attempts." >&2
echo "ERROR: On-disk certificate is up to date; the sync is repeated on every renew cycle." >&2
exit 1
