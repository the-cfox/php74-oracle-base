FROM php:7.4-apache

# Shared base image for all the-cfox brand api/bo/web-backend repos.
# Contains only what every one of them installed identically anyway
# (system deps, PHP extensions, Oracle Instant Client + oci8, redis,
# composer binary). Each brand repo's own Dockerfile now starts with
# `FROM ghcr.io/the-cfox/php74-oracle-base:latest` and only adds its
# app-specific composer install / file copy / vhost steps.

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
