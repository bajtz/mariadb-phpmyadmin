# syntax=docker/dockerfile:1
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/container \
    USER=container \
    TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# phpMyAdmin's Debian package asks whether it should configure a database and web server.
RUN printf '%s\n' \
      'phpmyadmin phpmyadmin/dbconfig-install boolean false' \
      'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2' \
      | debconf-set-selections \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      apache2 \
      bash \
      ca-certificates \
      coreutils \
      curl \
      libapache2-mod-php \
      mariadb-server \
      openssl \
      php-cli \
      php-curl \
      php-gd \
      php-intl \
      php-mbstring \
      php-mysql \
      php-xml \
      php-zip \
      phpmyadmin \
      procps \
      sed \
      util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 container \
    && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/container --shell /bin/bash container \
    && mkdir -p /home/container/.run/apache2 /home/container/.run/lock /home/container/logs/apache2 /home/container/.tmp \
    && chown -R container:container /home/container

RUN a2disconf phpmyadmin >/dev/null 2>&1 || true

# Apache runs as the unprivileged Pterodactyl user and stores runtime files inside its home.
RUN sed -i \
      -e 's|^export APACHE_RUN_DIR=.*|export APACHE_RUN_DIR=/home/container/.run/apache2|' \
      -e 's|^export APACHE_PID_FILE=.*|export APACHE_PID_FILE=/home/container/.run/apache2/apache2.pid|' \
      -e 's|^export APACHE_LOCK_DIR=.*|export APACHE_LOCK_DIR=/home/container/.run/lock|' \
      -e 's|^export APACHE_LOG_DIR=.*|export APACHE_LOG_DIR=/home/container/logs/apache2|' \
      -e 's|^export APACHE_RUN_USER=.*|export APACHE_RUN_USER=container|' \
      -e 's|^export APACHE_RUN_GROUP=.*|export APACHE_RUN_GROUP=container|' \
      /etc/apache2/envvars \
    && sed -i 's|^Listen 80$|Listen ${PMA_PORT}|' /etc/apache2/ports.conf

RUN a2dissite 000-default >/dev/null 2>&1 || true

RUN cat > /etc/apache2/sites-available/000-pma.conf <<'APACHECONF'
<VirtualHost *:${PMA_PORT}>
    ServerName localhost
    DocumentRoot /home/container/.phpmyadmin-app
    DirectoryIndex index.php index.html

    <Directory /home/container/.phpmyadmin-app>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory /usr/share/javascript>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHECONF

RUN a2enmod php8.2 >/dev/null
RUN a2ensite 000-pma >/dev/null

RUN echo "ServerName localhost" >> /etc/apache2/apache2.conf \
    && sed -i -e 's|^User |#User |' -e 's|^Group |#Group |' /etc/apache2/apache2.conf \
    && sed -i 's|^;*session.save_path = .*|session.save_path = "/home/container/.tmp"|' /etc/php/*/apache2/php.ini \
    && sed -i 's|^;*mysqli.default_socket = .*|mysqli.default_socket = "/home/container/.run/mariadb.sock"|' /etc/php/*/apache2/php.ini \
    && sed -i 's|^;*pdo_mysql.default_socket = .*|pdo_mysql.default_socket = "/home/container/.run/mariadb.sock"|' /etc/php/*/apache2/php.ini \
    && mkdir -p /var/lib/phpmyadmin /etc/phpmyadmin /var/run/mysqld \
    && echo "<?php" > /var/lib/phpmyadmin/blowfish_secret.inc.php \
    && echo "<?php" > /etc/phpmyadmin/config-db.php \
    && rm -f /etc/phpmyadmin/config.inc.php \
    && ln -sf /home/container/.phpmyadmin-app/config.inc.php /etc/phpmyadmin/config.inc.php \
    && ln -sf /home/container/.run/mariadb.sock /var/run/mysqld/mysqld.sock \
    && chown -R container:container /var/lib/phpmyadmin /etc/phpmyadmin /var/run/mysqld 2>/dev/null || true \
    && chmod -R 755 /var/lib/phpmyadmin /etc/phpmyadmin /usr/share/javascript 2>/dev/null || true \
    && chmod 644 /var/lib/phpmyadmin/blowfish_secret.inc.php /etc/phpmyadmin/config-db.php 2>/dev/null || true \
    && printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/chown \
    && chmod 0755 /usr/local/bin/chown

COPY entrypoint.sh /usr/local/bin/pterodactyl-mariadb-pma
RUN chmod 0755 /usr/local/bin/pterodactyl-mariadb-pma \
    && chown -R container:container /home/container

WORKDIR /home/container
USER container

EXPOSE 3306 8080
CMD ["bash", "/usr/local/bin/pterodactyl-mariadb-pma"]
