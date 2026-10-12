#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HOME="${HOME:-/home/container}"
SERVER_PORT="${SERVER_PORT:-3306}"
PMA_PORT="${PMA_PORT:-8080}"
MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-}"
DB_DATA_DIR="${MARIADB_DATA_DIR:-$HOME/.mariadb}"
PMA_APP_DIR="$HOME/.phpmyadmin-app"
RUN_DIR="$HOME/.run"
TMP_DIR="$HOME/.tmp"
LOG_DIR="$HOME/logs"
DB_LOG="$LOG_DIR/mariadb.log"
APACHE_ERROR_LOG="$LOG_DIR/apache2/error.log"
APACHE_ACCESS_LOG="$LOG_DIR/apache2/access.log"
SOCKET="$RUN_DIR/mariadb.sock"

fail() {
    echo "[PTERO-DB] ERROR: $*" >&2
    exit 1
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1024 && 10#$1 <= 65535 ))
}

valid_port "$SERVER_PORT" || fail "SERVER_PORT must be an integer between 1024 and 65535."
valid_port "$PMA_PORT" || fail "PMA_PORT must be an integer between 1024 and 65535."
(( 10#$SERVER_PORT != 10#$PMA_PORT )) || fail "SERVER_PORT and PMA_PORT must be different ports. Allocate a separate port for phpMyAdmin."
[[ -n "$MARIADB_ROOT_PASSWORD" ]] || fail "Set MARIADB_ROOT_PASSWORD in the Pterodactyl Startup tab before first start."
(( ${#MARIADB_ROOT_PASSWORD} >= 12 )) || fail "MARIADB_ROOT_PASSWORD must contain at least 12 characters."

mkdir -p "$DB_DATA_DIR" "$RUN_DIR/apache2" "$RUN_DIR/lock" "$TMP_DIR" "$LOG_DIR/apache2"
touch "$DB_LOG" "$APACHE_ERROR_LOG" "$APACHE_ACCESS_LOG"

# Run-time logs are tailed to stdout/stderr so they are visible in the Pterodactyl console.
tail -n 0 -F "$DB_LOG" "$APACHE_ERROR_LOG" "$APACHE_ACCESS_LOG" &
LOG_PID=$!

stop_pid() {
    local pid="${1:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

cleanup() {
    trap - INT TERM EXIT
    echo "[PTERO-DB] Shutting down services..."

    if [[ -n "${APACHE_PID:-}" ]] && kill -0 "$APACHE_PID" 2>/dev/null; then
        kill -TERM "$APACHE_PID" 2>/dev/null || true
    fi

    if [[ -n "${DB_PID:-}" ]] && kill -0 "$DB_PID" 2>/dev/null; then
        MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin --no-defaults \
          --protocol=tcp -h 127.0.0.1 -P "$SERVER_PORT" -u root shutdown >/dev/null 2>&1 \
          || kill -TERM "$DB_PID" 2>/dev/null || true
    fi

    [[ -n "${APACHE_PID:-}" ]] && wait "$APACHE_PID" 2>/dev/null || true
    [[ -n "${DB_PID:-}" ]] && wait "$DB_PID" 2>/dev/null || true
    stop_pid "$LOG_PID"
}
trap cleanup INT TERM EXIT

if [[ ! -d "$DB_DATA_DIR/mysql" ]]; then
    echo "[PTERO-DB] Initializing MariaDB data directory..."
    mariadb-install-db --no-defaults \
      --datadir="$DB_DATA_DIR" \
      --auth-root-authentication-method=normal \
      --skip-test-db >>"$DB_LOG" 2>&1 \
      || fail "MariaDB initialization failed. Check the console log above."
fi

if [[ ! -f "$DB_DATA_DIR/.pterodactyl-bootstrap-complete" ]]; then
    echo "[PTERO-DB] Setting the initial MariaDB root password..."
    SQL_FILE="$RUN_DIR/bootstrap.sql"
    ESCAPED_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD//\'/\'\'}"
    cat > "$SQL_FILE" <<SQL
CREATE OR REPLACE USER 'root'@'localhost' IDENTIFIED BY '${ESCAPED_ROOT_PASSWORD}';
CREATE OR REPLACE USER 'root'@'127.0.0.1' IDENTIFIED BY '${ESCAPED_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
    chmod 0600 "$SQL_FILE"

    BOOTSTRAP_PID=""
    mariadbd --no-defaults \
      --datadir="$DB_DATA_DIR" \
      --socket="$SOCKET" \
      --pid-file="$RUN_DIR/mariadb-bootstrap.pid" \
      --tmpdir="$TMP_DIR" \
      --skip-networking \
      --init-file="$SQL_FILE" >>"$DB_LOG" 2>&1 &
    BOOTSTRAP_PID=$!

    BOOTSTRAP_READY=0
    for _ in $(seq 1 90); do
        if MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin --no-defaults \
           --protocol=socket --socket="$SOCKET" -u root ping >/dev/null 2>&1; then
            BOOTSTRAP_READY=1
            break
        fi
        if ! kill -0 "$BOOTSTRAP_PID" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    rm -f "$SQL_FILE"

    if (( BOOTSTRAP_READY == 0 )); then
        echo "[PTERO-DB] MariaDB bootstrap did not become ready. Recent log:"
        tail -n 80 "$DB_LOG" >&2 || true
        kill "$BOOTSTRAP_PID" 2>/dev/null || true
        wait "$BOOTSTRAP_PID" 2>/dev/null || true
        fail "Could not start temporary MariaDB bootstrap process."
    fi

    if ! MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin --no-defaults \
      --protocol=socket --socket="$SOCKET" -u root shutdown >/dev/null 2>&1; then
        kill "$BOOTSTRAP_PID" 2>/dev/null || true
    fi
    wait "$BOOTSTRAP_PID" 2>/dev/null || true
    BOOTSTRAP_PID=""
    touch "$DB_DATA_DIR/.pterodactyl-bootstrap-complete"
    echo "[PTERO-DB] MariaDB bootstrap complete."
fi

# Recreate the bundled app directory on each start so an image update also updates phpMyAdmin.
rm -rf "$PMA_APP_DIR"
mkdir -p "$PMA_APP_DIR"
cp -r /usr/share/phpmyadmin/. "$PMA_APP_DIR/"
rm -f "$PMA_APP_DIR/config.inc.php"

PMA_SECRET_FILE="$HOME/.phpmyadmin-blowfish-secret"
if [[ ! -s "$PMA_SECRET_FILE" ]]; then
    openssl rand -hex 32 > "$PMA_SECRET_FILE"
    chmod 0600 "$PMA_SECRET_FILE"
fi
PMA_SECRET="$(tr -d '\r\n' < "$PMA_SECRET_FILE")"

cat > "$PMA_APP_DIR/config.inc.php" <<PHP
<?php
\$cfg['blowfish_secret'] = '${PMA_SECRET}';
\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = (int) (getenv('SERVER_PORT') ?: '3306');
\$cfg['Servers'][\$i]['connect_type'] = 'tcp';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '${TMP_DIR}';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
PHP
chmod 0600 "$PMA_APP_DIR/config.inc.php"

# Apache expands PMA_PORT from the container environment while parsing ports.conf and the vhost.
source /etc/apache2/envvars
apache2ctl -t || fail "Apache configuration is invalid. Check PMA_PORT and the Apache logs."

mariadbd --no-defaults \
  --datadir="$DB_DATA_DIR" \
  --port="$SERVER_PORT" \
  --bind-address=0.0.0.0 \
  --socket="$SOCKET" \
  --pid-file="$RUN_DIR/mariadb.pid" \
  --tmpdir="$TMP_DIR" \
  --skip-name-resolve >>"$DB_LOG" 2>&1 &
DB_PID=$!

apache2ctl -D FOREGROUND &
APACHE_PID=$!

DB_READY=0
for _ in $(seq 1 90); do
    if MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin --no-defaults \
      --protocol=tcp -h 127.0.0.1 -P "$SERVER_PORT" -u root ping >/dev/null 2>&1; then
        DB_READY=1
        break
    fi
    if ! kill -0 "$DB_PID" 2>/dev/null; then
        echo "[PTERO-DB] MariaDB process died unexpectedly. Recent log:" >&2
        tail -n 80 "$DB_LOG" >&2 || true
        fail "MariaDB failed to start on port $SERVER_PORT."
    fi
    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        echo "[PTERO-DB] Apache process died unexpectedly. Recent error log:" >&2
        tail -n 80 "$APACHE_ERROR_LOG" >&2 || true
        fail "Apache failed to start."
    fi
    sleep 1
done
(( DB_READY == 1 )) || {
    tail -n 80 "$DB_LOG" >&2 || true
    fail "MariaDB did not become ready on port $SERVER_PORT."
}

PMA_READY=0
for _ in $(seq 1 45); do
    if curl --silent --show-error --fail "http://127.0.0.1:${PMA_PORT}/" -o /dev/null 2>/dev/null; then
        PMA_READY=1
        break
    fi
    if ! kill -0 "$APACHE_PID" 2>/dev/null; then
        break
    fi
    sleep 1
done
(( PMA_READY == 1 )) || {
    tail -n 80 "$APACHE_ERROR_LOG" >&2 || true
    fail "phpMyAdmin/Apache did not become ready on port $PMA_PORT."
}

echo "[PTERO-DB] Usługi gotowe: MariaDB port=${SERVER_PORT}, phpMyAdmin port=${PMA_PORT}."

# Keep the container alive while both services are alive. If either service dies, exit and let Wings show the failure.
while kill -0 "$DB_PID" 2>/dev/null && kill -0 "$APACHE_PID" 2>/dev/null; do
    sleep 1
done

echo "[PTERO-DB] A service stopped unexpectedly; container will exit." >&2
exit 1
