FROM php:7.4-apache

# Shared base image for all the-cfox brand api/bo/web-backend repos.
# Contains only what every one of them installed identically anyway
# (system deps, PHP extensions, Oracle Instant Client + oci8, redis,
# composer binary). Each brand repo's own Dockerfile now starts with
# `FROM ghcr.io/the-cfox/php74-oracle-base:latest` and only adds its
# app-specific composer install / file copy / vhost steps.

# --- Debian bullseye is EOL: its packages moved to archive.debian.org (deb.debian.org
# still serves a stale bullseye-security index whose .deb files 404, so apt-get install fails).
RUN printf '%s\n' \
        'deb http://archive.debian.org/debian bullseye main' \
        'deb http://archive.debian.org/debian bullseye-updates main' \
        'deb http://archive.debian.org/debian-security bullseye-security main' \
        > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/debian.sources

# --- sistem zavisnosti ---
RUN apt-get update && apt-get install -y \
        libaio1 \
        unzip \
        curl \
        libzip-dev \
        libicu-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libonig-dev \
        libxml2-dev \
    && rm -rf /var/lib/apt/lists/*

# --- PHP ekstenzije ---
RUN docker-php-ext-configure gd --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli \
        pdo \
        pdo_mysql \
        intl \
        zip \
        gd \
        mbstring \
        xml \
        sockets \
        opcache

# --- Redis (phpredis) ---
RUN pecl install redis-5.3.7 \
    && docker-php-ext-enable redis

# --- Oracle Instant Client (OCI8) ---
ARG ORACLE_CLIENT_VERSION=19.26.0.0.0
ENV ORACLE_HOME=/opt/oracle/instantclient_19_26
ENV LD_LIBRARY_PATH=$ORACLE_HOME

RUN mkdir -p /opt/oracle \
    && cd /opt/oracle \
    && curl -sSL -o basic.zip "https://download.oracle.com/otn_software/linux/instantclient/1926000/instantclient-basiclite-linux.x64-${ORACLE_CLIENT_VERSION}dbru.zip" \
    && curl -sSL -o sdk.zip   "https://download.oracle.com/otn_software/linux/instantclient/1926000/instantclient-sdk-linux.x64-${ORACLE_CLIENT_VERSION}dbru.zip" \
    && unzip -oq basic.zip && unzip -oq sdk.zip \
    && rm -f basic.zip sdk.zip \
    && cd instantclient_19_26 \
    && ln -sf libclntsh.so.19.1 libclntsh.so \
    && ln -sf libocci.so.19.1 libocci.so \
    && echo "$ORACLE_HOME" > /etc/ld.so.conf.d/oracle-instantclient.conf \
    && ldconfig

RUN echo "instantclient,$ORACLE_HOME" | pecl install oci8-2.2.0 \
    && docker-php-ext-enable oci8

# --- Composer binary (brand repos still run their own `composer install`) ---
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# --- Oracle connection hygiene + Apache worker cap ---
# All brands share one Oracle instance, so its `processes` limit is shared too.
# oci_pconnect() keeps one session per Apache worker; with the defaults
# (persistent_timeout=-1, workers never recycled) idle sessions pile up forever
# and caused ORA-12516. Close idle persistent sessions after 60s, keep few idle
# workers around and recycle workers regularly so their sessions are released.
#
# Worker cap: 150 prefork workers (the old value) let a scanner burst fork dozens
# of PHP processes, each allowed memory_limit (512M BO / 2048M API), and the pods
# were OOM-killed (travelodds, 2026-11-11; kernel also silently killed ~200
# children elsewhere). Default 16 workers; extra requests wait in the listen
# backlog. Override per service with env APACHE_MAX_WORKERS (read from envvars,
# which apache2-foreground sources). Brand Dockerfiles that sed StartServers /
# MinSpareServers / MaxSpareServers / MaxConnectionsPerChild keep working.
RUN echo 'oci8.persistent_timeout = 60' > /usr/local/etc/php/conf.d/zz-oci8.ini \
    && printf '\n# Prefork worker cap (see Dockerfile of php74-oracle-base).\n: "${APACHE_MAX_WORKERS:=16}"\nexport APACHE_MAX_WORKERS\n' >> /etc/apache2/envvars \
    && printf '<IfModule mpm_prefork_module>\n\tStartServers 3\n\tMinSpareServers 2\n\tMaxSpareServers 5\n\tServerLimit ${APACHE_MAX_WORKERS}\n\tMaxRequestWorkers ${APACHE_MAX_WORKERS}\n\tMaxConnectionsPerChild 500\n</IfModule>\n' > /etc/apache2/mods-available/mpm_prefork.conf
