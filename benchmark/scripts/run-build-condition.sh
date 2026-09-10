#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BENCHMARK_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
CONTAINER_ROOT=$(CDPATH= cd -- "$BENCHMARK_ROOT/.." && pwd)
PROJECTS_ROOT=$(CDPATH= cd -- "$CONTAINER_ROOT/.." && pwd)
MONOLITH_ROOT="$PROJECTS_ROOT/tcc-monolith"
PARITY_CHECK="$SCRIPT_DIRECTORY/verify-laravel-parity.py"

architecture=
repetition=
result_set=

usage()
{
    printf '%s\n' "Usage: $0 --architecture {monolith|microservices} --repetition {1..5} [--result-set LABEL]" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --architecture) architecture=${2:-}; shift 2 ;;
        --repetition) repetition=${2:-}; shift 2 ;;
        --result-set) result_set=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done

case "$architecture" in monolith|microservices) ;; *) usage ;; esac
case "$repetition" in 1|2|3|4|5) ;; *) usage ;; esac

if [ -n "$result_set" ]; then
    case "$result_set" in *[!A-Za-z0-9._-]*) usage ;; esac
    RESULTS_ROOT="$BENCHMARK_ROOT/results/$result_set"
else
    RESULTS_ROOT="$BENCHMARK_ROOT/results"
fi

laravel_version=$(python3 "$PARITY_CHECK" --projects-root "$PROJECTS_ROOT")
run_directory="$RESULTS_ROOT/build/r$repetition/$architecture"
if [ -e "$run_directory" ]; then
    printf 'Refusing to overwrite preserved build output: %s\n' "$run_directory" >&2
    exit 1
fi
mkdir -p "$run_directory"

"$MONOLITH_ROOT/bin/tcc-experiment" stop >/dev/null 2>&1 || true
"$CONTAINER_ROOT/bin/tcc-experiment" stop >/dev/null 2>&1 || true

start_nanoseconds=$(python3 -c 'import time; print(time.time_ns())')
status=0

verify_image_laravel_version()
{
    image=$1
    project_directory=$2
    output=$(docker run --rm "$image" php artisan --version)
    runtime_version=$(printf '%s\n' "$output" | awk '/^Laravel Framework / { print $3; exit }')
    if [ "$runtime_version" != "$laravel_version" ]; then
        printf 'Laravel runtime mismatch in %s: expected %s, found %s.\n' "$image" "$laravel_version" "${runtime_version:-unknown}"
        return 1
    fi
    source_hash=$(shasum -a 256 "$project_directory/composer.lock" | awk '{ print $1 }')
    runtime_hash=$(docker run --rm "$image" php -r 'echo hash_file("sha256", "composer.lock"), PHP_EOL;')
    if [ "$runtime_hash" != "$source_hash" ]; then
        printf 'Stale image %s: composer.lock hash should be %s, found %s.\n' "$image" "$source_hash" "${runtime_hash:-unknown}"
        return 1
    fi
    printf 'Laravel runtime verified in %s: %s\n' "$image" "$runtime_version"
    printf 'composer.lock verified in %s: %s\n' "$image" "$runtime_hash"
}

if [ "$architecture" = monolith ]; then
    docker build --no-cache \
        --file "$CONTAINER_ROOT/Dockerfile.experiment-base" \
        --tag tcc-laravel-experiment:php8.4.19 \
        "$CONTAINER_ROOT" > "$run_directory/build.log" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        docker compose \
            --env-file "$MONOLITH_ROOT/.env.experiment" \
            --project-name tcc-monolith-experiment \
            --file "$MONOLITH_ROOT/docker-compose.experiment.yml" \
            build --no-cache monolith >> "$run_directory/build.log" 2>&1 || status=$?
    fi
else
    docker compose \
        --env-file "$CONTAINER_ROOT/.env.experiment" \
        --project-name tcc-microservices-experiment \
        --file "$CONTAINER_ROOT/docker-compose.experiment.yml" \
        --profile build-only build --no-cache experiment-base > "$run_directory/build.log" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        docker compose \
            --env-file "$CONTAINER_ROOT/.env.experiment" \
            --project-name tcc-microservices-experiment \
            --file "$CONTAINER_ROOT/docker-compose.experiment.yml" \
            build --no-cache auth product order gateway >> "$run_directory/build.log" 2>&1 || status=$?
    fi
fi

end_nanoseconds=$(python3 -c 'import time; print(time.time_ns())')
elapsed_nanoseconds=$((end_nanoseconds - start_nanoseconds))

if [ "$status" -eq 0 ]; then
    if [ "$architecture" = monolith ]; then
        verify_image_laravel_version tcc-monolith-experiment:php8.4.19 "$MONOLITH_ROOT" >> "$run_directory/build.log" 2>&1 || status=$?
    else
        verify_image_laravel_version tcc-auth-experiment:php8.4.19 "$PROJECTS_ROOT/tcc-auth-service" >> "$run_directory/build.log" 2>&1 || status=$?
        verify_image_laravel_version tcc-product-experiment:php8.4.19 "$PROJECTS_ROOT/tcc-product-service" >> "$run_directory/build.log" 2>&1 || status=$?
        verify_image_laravel_version tcc-order-experiment:php8.4.19 "$PROJECTS_ROOT/tcc-order-service" >> "$run_directory/build.log" 2>&1 || status=$?
    fi
fi

{
    printf 'protocol_version=2\n'
    printf 'result_set=%s\n' "${result_set:-legacy-default}"
    printf 'architecture=%s\n' "$architecture"
    printf 'repetition=%s\n' "$repetition"
    printf 'laravel_framework_version=%s\n' "$laravel_version"
    printf 'docker_build_cache=disabled\n'
    printf 'start_unix_nanoseconds=%s\n' "$start_nanoseconds"
    printf 'end_unix_nanoseconds=%s\n' "$end_nanoseconds"
    printf 'elapsed_nanoseconds=%s\n' "$elapsed_nanoseconds"
    printf 'exit_status=%s\n' "$status"
} > "$run_directory/build-timing.properties"

exit "$status"
