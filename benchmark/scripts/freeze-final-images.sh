#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BENCHMARK_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
CONTAINER_ROOT=$(CDPATH= cd -- "$BENCHMARK_ROOT/.." && pwd)
PROJECTS_ROOT=$(CDPATH= cd -- "$CONTAINER_ROOT/.." && pwd)
PARITY_CHECK="$SCRIPT_DIRECTORY/verify-laravel-parity.py"
result_set=

usage()
{
    printf '%s\n' "Usage: $0 [--result-set LABEL]" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --result-set) result_set=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done

if [ -n "$result_set" ]; then
    case "$result_set" in *[!A-Za-z0-9._-]*) usage ;; esac
    MANIFEST="$BENCHMARK_ROOT/results/$result_set/final-image-manifest.properties"
else
    MANIFEST="$BENCHMARK_ROOT/final-image-manifest.properties"
fi

laravel_version=$(python3 "$PARITY_CHECK" --projects-root "$PROJECTS_ROOT")

if [ -e "$MANIFEST" ]; then
    printf 'Refusing to overwrite frozen final image manifest: %s\n' "$MANIFEST" >&2
    exit 1
fi

image_id()
{
    docker image inspect --format '{{.Id}}' "$1"
}

image_laravel_version()
{
    image=$1
    output=$(docker run --rm "$image" php artisan --version)
    version=$(printf '%s\n' "$output" | awk '/^Laravel Framework / { print $3; exit }')
    if [ "$version" != "$laravel_version" ]; then
        printf 'Laravel runtime mismatch in %s: expected %s, found %s.\n' "$image" "$laravel_version" "${version:-unknown}" >&2
        exit 1
    fi
    printf '%s\n' "$version"
}

image_composer_lock_hash()
{
    image=$1
    project_directory=$2
    source_hash=$(shasum -a 256 "$project_directory/composer.lock" | awk '{ print $1 }')
    runtime_hash=$(docker run --rm "$image" php -r 'echo hash_file("sha256", "composer.lock"), PHP_EOL;')
    if [ "$runtime_hash" != "$source_hash" ]; then
        printf 'Stale image %s: composer.lock hash should be %s, found %s. Rebuild all images before freezing.\n' "$image" "$source_hash" "${runtime_hash:-unknown}" >&2
        exit 1
    fi
    printf '%s\n' "$runtime_hash"
}

monolith_id=$(image_id 'tcc-monolith-experiment:php8.4.19') || {
    printf '%s\n' 'Missing prebuilt image: tcc-monolith-experiment:php8.4.19' >&2
    exit 1
}
mysql_id=$(image_id 'mysql:8.4.8@sha256:2952e3be7807f06fc18de50b3ea1a632d5c70d63482ff7d7376fe3aa8999babf') || {
    printf '%s\n' 'Missing prebuilt image: mysql:8.4.8@sha256:2952e3be7807f06fc18de50b3ea1a632d5c70d63482ff7d7376fe3aa8999babf' >&2
    exit 1
}
gateway_id=$(image_id 'tcc-gateway-experiment:java21') || {
    printf '%s\n' 'Missing prebuilt image: tcc-gateway-experiment:java21' >&2
    exit 1
}
auth_id=$(image_id 'tcc-auth-experiment:php8.4.19') || {
    printf '%s\n' 'Missing prebuilt image: tcc-auth-experiment:php8.4.19' >&2
    exit 1
}
product_id=$(image_id 'tcc-product-experiment:php8.4.19') || {
    printf '%s\n' 'Missing prebuilt image: tcc-product-experiment:php8.4.19' >&2
    exit 1
}
order_id=$(image_id 'tcc-order-experiment:php8.4.19') || {
    printf '%s\n' 'Missing prebuilt image: tcc-order-experiment:php8.4.19' >&2
    exit 1
}

monolith_laravel_version=$(image_laravel_version 'tcc-monolith-experiment:php8.4.19')
auth_laravel_version=$(image_laravel_version 'tcc-auth-experiment:php8.4.19')
product_laravel_version=$(image_laravel_version 'tcc-product-experiment:php8.4.19')
order_laravel_version=$(image_laravel_version 'tcc-order-experiment:php8.4.19')
monolith_lock_hash=$(image_composer_lock_hash 'tcc-monolith-experiment:php8.4.19' "$PROJECTS_ROOT/tcc-monolith")
auth_lock_hash=$(image_composer_lock_hash 'tcc-auth-experiment:php8.4.19' "$PROJECTS_ROOT/tcc-auth-service")
product_lock_hash=$(image_composer_lock_hash 'tcc-product-experiment:php8.4.19' "$PROJECTS_ROOT/tcc-product-service")
order_lock_hash=$(image_composer_lock_hash 'tcc-order-experiment:php8.4.19' "$PROJECTS_ROOT/tcc-order-service")

mkdir -p "$(dirname -- "$MANIFEST")"
{
    printf 'protocol_version=2\n'
    printf 'result_set=%s\n' "${result_set:-legacy-default}"
    printf 'created_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' '# Created after the no-cache build measurements; do not edit or replace during the definitive HTTP benchmark run set.'
    printf 'image_id.monolith.monolith=%s\n' "$monolith_id"
    printf 'image_id.monolith.mysql=%s\n' "$mysql_id"
    printf 'image_id.microservices.gateway=%s\n' "$gateway_id"
    printf 'image_id.microservices.auth=%s\n' "$auth_id"
    printf 'image_id.microservices.product=%s\n' "$product_id"
    printf 'image_id.microservices.order=%s\n' "$order_id"
    printf 'image_id.microservices.mysql=%s\n' "$mysql_id"
    printf 'laravel_version.monolith.monolith=%s\n' "$monolith_laravel_version"
    printf 'laravel_version.microservices.auth=%s\n' "$auth_laravel_version"
    printf 'laravel_version.microservices.product=%s\n' "$product_laravel_version"
    printf 'laravel_version.microservices.order=%s\n' "$order_laravel_version"
    printf 'composer_lock_sha256.monolith.monolith=%s\n' "$monolith_lock_hash"
    printf 'composer_lock_sha256.microservices.auth=%s\n' "$auth_lock_hash"
    printf 'composer_lock_sha256.microservices.product=%s\n' "$product_lock_hash"
    printf 'composer_lock_sha256.microservices.order=%s\n' "$order_lock_hash"
} > "$MANIFEST"

printf 'Frozen final image manifest: %s\n' "$MANIFEST"
