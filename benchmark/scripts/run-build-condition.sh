#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BENCHMARK_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
CONTAINER_ROOT=$(CDPATH= cd -- "$BENCHMARK_ROOT/.." && pwd)
PROJECTS_ROOT=$(CDPATH= cd -- "$CONTAINER_ROOT/.." && pwd)
MONOLITH_ROOT="$PROJECTS_ROOT/tcc-monolith"

architecture=
repetition=

usage()
{
    printf '%s\n' "Usage: $0 --architecture {monolith|microservices} --repetition {1..5}" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --architecture) architecture=${2:-}; shift 2 ;;
        --repetition) repetition=${2:-}; shift 2 ;;
        *) usage ;;
    esac
done

case "$architecture" in monolith|microservices) ;; *) usage ;; esac
case "$repetition" in 1|2|3|4|5) ;; *) usage ;; esac

run_directory="$BENCHMARK_ROOT/results/build/r$repetition/$architecture"
if [ -e "$run_directory" ]; then
    printf 'Refusing to overwrite preserved build output: %s\n' "$run_directory" >&2
    exit 1
fi
mkdir -p "$run_directory"

"$MONOLITH_ROOT/bin/tcc-experiment" stop >/dev/null 2>&1 || true
"$CONTAINER_ROOT/bin/tcc-experiment" stop >/dev/null 2>&1 || true

start_nanoseconds=$(python3 -c 'import time; print(time.time_ns())')
status=0

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

{
    printf 'protocol_version=1\n'
    printf 'architecture=%s\n' "$architecture"
    printf 'repetition=%s\n' "$repetition"
    printf 'docker_build_cache=disabled\n'
    printf 'start_unix_nanoseconds=%s\n' "$start_nanoseconds"
    printf 'end_unix_nanoseconds=%s\n' "$end_nanoseconds"
    printf 'elapsed_nanoseconds=%s\n' "$elapsed_nanoseconds"
    printf 'exit_status=%s\n' "$status"
} > "$run_directory/build-timing.properties"

exit "$status"
