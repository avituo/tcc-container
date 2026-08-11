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

run_directory="$BENCHMARK_ROOT/results/startup/r$repetition/$architecture"
if [ -e "$run_directory" ]; then
    printf 'Refusing to overwrite preserved startup output: %s\n' "$run_directory" >&2
    exit 1
fi
mkdir -p "$run_directory"

"$MONOLITH_ROOT/bin/tcc-experiment" stop >/dev/null 2>&1 || true
"$CONTAINER_ROOT/bin/tcc-experiment" stop >/dev/null 2>&1 || true

wait_for_url()
{
    ready_url=$1
    attempts=0
    until curl --fail --silent --show-error "$ready_url" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 120 ]; then
            return 1
        fi
        sleep 1
    done
}

wait_for_microservice()
{
    service=$1
    service_url=$2
    attempts=0
    until docker compose \
        --env-file "$CONTAINER_ROOT/.env.experiment" \
        --project-name tcc-microservices-experiment \
        --file "$CONTAINER_ROOT/docker-compose.experiment.yml" \
        exec -T "$service" php -r 'exit(@file_get_contents($argv[1]) === false ? 1 : 0);' "$service_url" \
        >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 120 ]; then
            return 1
        fi
        sleep 1
    done
}

start_nanoseconds=$(python3 -c 'import time; print(time.time_ns())')
status=0

if [ "$architecture" = monolith ]; then
    docker compose \
        --env-file "$MONOLITH_ROOT/.env.experiment" \
        --project-name tcc-monolith-experiment \
        --file "$MONOLITH_ROOT/docker-compose.experiment.yml" \
        up --detach --no-build mysql monolith > "$run_directory/startup.log" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        wait_for_url http://localhost:18000/up >> "$run_directory/startup.log" 2>&1 || status=$?
    fi
else
    docker compose \
        --env-file "$CONTAINER_ROOT/.env.experiment" \
        --project-name tcc-microservices-experiment \
        --file "$CONTAINER_ROOT/docker-compose.experiment.yml" \
        up --detach --no-build mysql auth product order gateway > "$run_directory/startup.log" 2>&1 || status=$?
    if [ "$status" -eq 0 ]; then
        wait_for_microservice auth http://127.0.0.1:8003/up >> "$run_directory/startup.log" 2>&1 || status=$?
    fi
    if [ "$status" -eq 0 ]; then
        wait_for_microservice product http://127.0.0.1:8001/up >> "$run_directory/startup.log" 2>&1 || status=$?
    fi
    if [ "$status" -eq 0 ]; then
        wait_for_microservice order http://127.0.0.1:8002/up >> "$run_directory/startup.log" 2>&1 || status=$?
    fi
    if [ "$status" -eq 0 ]; then
        wait_for_url http://localhost:18080/actuator/health >> "$run_directory/startup.log" 2>&1 || status=$?
    fi
fi

end_nanoseconds=$(python3 -c 'import time; print(time.time_ns())')
elapsed_nanoseconds=$((end_nanoseconds - start_nanoseconds))

{
    printf 'protocol_version=1\n'
    printf 'architecture=%s\n' "$architecture"
    printf 'repetition=%s\n' "$repetition"
    printf 'images=already-built\n'
    printf 'start_unix_nanoseconds=%s\n' "$start_nanoseconds"
    printf 'end_unix_nanoseconds=%s\n' "$end_nanoseconds"
    printf 'elapsed_nanoseconds=%s\n' "$elapsed_nanoseconds"
    printf 'exit_status=%s\n' "$status"
} > "$run_directory/startup-timing.properties"

if [ "$architecture" = monolith ]; then
    docker compose \
        --env-file "$MONOLITH_ROOT/.env.experiment" \
        --project-name tcc-monolith-experiment \
        --file "$MONOLITH_ROOT/docker-compose.experiment.yml" \
        ps --all >> "$run_directory/startup.log" 2>&1 || true
    "$MONOLITH_ROOT/bin/tcc-experiment" stop >> "$run_directory/startup.log" 2>&1 || true
else
    docker compose \
        --env-file "$CONTAINER_ROOT/.env.experiment" \
        --project-name tcc-microservices-experiment \
        --file "$CONTAINER_ROOT/docker-compose.experiment.yml" \
        ps --all >> "$run_directory/startup.log" 2>&1 || true
    "$CONTAINER_ROOT/bin/tcc-experiment" stop >> "$run_directory/startup.log" 2>&1 || true
fi

exit "$status"
