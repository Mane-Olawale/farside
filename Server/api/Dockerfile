# The backend image (plan section 13, deployment): FrankenPHP serves the API, and the same image
# runs Reverb and the queue worker.
FROM dunglas/frankenphp:1-php8.3-alpine

RUN install-php-extensions pdo_pgsql redis pcntl intl opcache
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction
COPY . .
RUN composer dump-autoload --optimize --no-dev \
    && mkdir -p storage/framework/cache storage/framework/views storage/logs bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache

ENV SERVER_NAME=:8000
EXPOSE 8000
