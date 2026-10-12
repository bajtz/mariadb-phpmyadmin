#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

HOME="${HOME:-/home/container}"
SERVER_PORT="${SERVER_PORT:-3306}"
PMA_PORT="${PMA_PORT:-8080}"
export SERVER_PORT PMA_PORT
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
chmod 0777 "$TMP_DIR" 2>/dev/null || chmod 777 "$TMP_DIR" 2>/dev/null || true
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
          || MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin --no-defaults \
          --protocol=socket --socket="$SOCKET" -u root shutdown >/dev/null 2>&1 \
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

# Prepare user configuration SQL to run on every start
INIT_FILE="$RUN_DIR/init.sql"
php <<'PHP' > "$INIT_FILE"
<?php
$pass = getenv('MARIADB_ROOT_PASSWORD');
$escaped = str_replace(['\\', "\x00", "'"], ['\\\\', '\\0', "\\'"], $pass);
echo "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('" . $escaped . "');\n";
echo "CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('" . $escaped . "');\n";
echo "ALTER USER 'root'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('" . $escaped . "');\n";
echo "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('" . $escaped . "');\n";
echo "ALTER USER 'root'@'%' IDENTIFIED VIA mysql_native_password USING PASSWORD('" . $escaped . "');\n";
echo "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;\n";
echo "GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;\n";
echo "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;\n";
echo "FLUSH PRIVILEGES;\n";
PHP
chmod 0600 "$INIT_FILE"

# Provide a user-configurable php.ini in the Pterodactyl file manager root
PHP_INI_FILE="$HOME/php.ini"
if [[ ! -f "$PHP_INI_FILE" ]]; then
    cat > "$PHP_INI_FILE" <<'EOF'
session.save_path = "/home/container/.tmp"
upload_tmp_dir = "/home/container/.tmp"
upload_max_filesize = 128M
post_max_size = 128M
memory_limit = 512M
max_execution_time = 300
max_input_time = 300
max_input_vars = 5000
date.timezone = UTC
EOF
    chmod 0644 "$PHP_INI_FILE" 2>/dev/null || true
else
    if ! grep -q "session.save_path" "$PHP_INI_FILE"; then
        echo 'session.save_path = "/home/container/.tmp"' >> "$PHP_INI_FILE"
    fi
    if ! grep -q "upload_tmp_dir" "$PHP_INI_FILE"; then
        echo 'upload_tmp_dir = "/home/container/.tmp"' >> "$PHP_INI_FILE"
    fi
fi

# Recreate the bundled app directory on each start so an image update also updates phpMyAdmin.
rm -rf "$PMA_APP_DIR"
mkdir -p "$PMA_APP_DIR"
cp -r -L /usr/share/phpmyadmin/. "$PMA_APP_DIR/"
rm -f "$PMA_APP_DIR/config.inc.php"

PMA_SECRET_FILE="$HOME/.phpmyadmin-blowfish-secret"
if [[ ! -s "$PMA_SECRET_FILE" ]]; then
    openssl rand -hex 32 > "$PMA_SECRET_FILE"
    chmod 0600 "$PMA_SECRET_FILE"
fi
PMA_SECRET="$(tr -d '\r\n' < "$PMA_SECRET_FILE")"

# Create socket symlink in /tmp so any fallback socket connection finds MariaDB
ln -sf "$SOCKET" /tmp/mysql.sock 2>/dev/null || true

PMA_CONFIG_TEXT="<?php
\$cfg['blowfish_secret'] = '${PMA_SECRET}';

\$i = 1;
\$cfg['Servers'][\$i]['verbose'] = 'MariaDB TCP (${SERVER_PORT})';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = ${SERVER_PORT};
\$cfg['Servers'][\$i]['connect_type'] = 'tcp';
\$cfg['Servers'][\$i]['socket'] = '${SOCKET}';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;

\$i = 2;
\$cfg['Servers'][\$i]['verbose'] = 'MariaDB Socket';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['socket'] = '${SOCKET}';
\$cfg['Servers'][\$i]['connect_type'] = 'socket';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;

\$cfg['TempDir'] = '${TMP_DIR}';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
"

printf '%s' "$PMA_CONFIG_TEXT" > "$PMA_APP_DIR/config.inc.php"
chmod 0644 "$PMA_APP_DIR/config.inc.php" 2>/dev/null || true

# Apache expands PMA_PORT from the container environment while parsing ports.conf and the vhost.
export APACHE_CONFDIR="/etc/apache2"
set +u
source /etc/apache2/envvars
set -u
/usr/sbin/apache2 -t || {
    echo "[PTERO-DB] Apache configuration test failed. Recent error log:" >&2
    tail -n 80 "$APACHE_ERROR_LOG" >&2 || true
    fail "Apache configuration is invalid. Check PMA_PORT and the Apache logs."
}

echo "[PTERO-DB] Starting MariaDB service..."
mariadbd --no-defaults \
  --datadir="$DB_DATA_DIR" \
  --port="$SERVER_PORT" \
  --bind-address=0.0.0.0 \
  --socket="$SOCKET" \
  --pid-file="$RUN_DIR/mariadb.pid" \
  --tmpdir="$TMP_DIR" \
  --skip-name-resolve \
  --init-file="$INIT_FILE" >>"$DB_LOG" 2>&1 &
DB_PID=$!

DB_READY=0
for i in $(seq 1 90); do
    if MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --no-defaults \
      --protocol=tcp -h 127.0.0.1 -P "$SERVER_PORT" -u root -e "SELECT 1" >/dev/null 2>&1; then
        DB_READY=1
        break
    fi

    # After the socket is created, apply init.sql directly over the socket if TCP authentication is pending
    if [[ -S "$SOCKET" ]] && (( i >= 3 )); then
        mariadb --no-defaults --socket="$SOCKET" -u root < "$INIT_FILE" >/dev/null 2>&1 \
          || MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --no-defaults --socket="$SOCKET" -u root < "$INIT_FILE" >/dev/null 2>&1 \
          || true
    fi

    if ! kill -0 "$DB_PID" 2>/dev/null; then
        echo "[PTERO-DB] MariaDB process died unexpectedly. Recent log:" >&2
        tail -n 80 "$DB_LOG" >&2 || true
        fail "MariaDB failed to start on port $SERVER_PORT."
    fi
    sleep 1
done
rm -f "$INIT_FILE"

(( DB_READY == 1 )) || {
    echo "[PTERO-DB] Failed to authenticate or verify connection on port $SERVER_PORT:" >&2
    MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb --no-defaults \
      --protocol=tcp -h 127.0.0.1 -P "$SERVER_PORT" -u root -e "SELECT 1" >&2 || true
    tail -n 80 "$DB_LOG" >&2 || true
    fail "MariaDB did not become ready or root login failed on port $SERVER_PORT."
}

echo "[PTERO-DB] Starting Apache / phpMyAdmin service..."
/usr/sbin/apache2 -DFOREGROUND &
APACHE_PID=$!

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
