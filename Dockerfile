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

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHECONF

RUN a2enmod php8.2 >/dev/null
RUN a2ensite 000-pma >/dev/null

COPY entrypoint.sh /usr/local/bin/pterodactyl-mariadb-pma
RUN chmod 0755 /usr/local/bin/pterodactyl-mariadb-pma \
    && chown -R container:container /home/container

WORKDIR /home/container
USER container

EXPOSE 3306 8080
CMD ["bash", "/usr/local/bin/pterodactyl-mariadb-pma"]
