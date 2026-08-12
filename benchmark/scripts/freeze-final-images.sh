#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BENCHMARK_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
MANIFEST="$BENCHMARK_ROOT/final-image-manifest.properties"

if [ -e "$MANIFEST" ]; then
    printf 'Refusing to overwrite frozen final image manifest: %s\n' "$MANIFEST" >&2
    exit 1
fi

image_id()
{
    docker image inspect --format '{{.Id}}' "$1"
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

{
    printf 'protocol_version=1\n'
    printf 'created_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' '# Created after the no-cache build measurements; do not edit or replace during the definitive HTTP benchmark run set.'
    printf 'image_id.monolith.monolith=%s\n' "$monolith_id"
    printf 'image_id.monolith.mysql=%s\n' "$mysql_id"
    printf 'image_id.microservices.gateway=%s\n' "$gateway_id"
    printf 'image_id.microservices.auth=%s\n' "$auth_id"
    printf 'image_id.microservices.product=%s\n' "$product_id"
    printf 'image_id.microservices.order=%s\n' "$order_id"
    printf 'image_id.microservices.mysql=%s\n' "$mysql_id"
} > "$MANIFEST"

printf 'Frozen final image manifest: %s\n' "$MANIFEST"
