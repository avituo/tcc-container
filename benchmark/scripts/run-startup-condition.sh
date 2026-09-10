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
run_directory="$RESULTS_ROOT/startup/r$repetition/$architecture"
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

verify_running_laravel_version()
{
    service=$1
    compose_env_file=$2
    project_name=$3
    compose_file=$4
    project_directory=$5
    output=$(docker compose \
        --env-file "$compose_env_file" \
        --project-name "$project_name" \
        --file "$compose_file" \
        exec -T "$service" php artisan --version)
    runtime_version=$(printf '%s\n' "$output" | awk '/^Laravel Framework / { print $3; exit }')
    if [ "$runtime_version" != "$laravel_version" ]; then
        printf 'Laravel runtime mismatch in %s: expected %s, found %s.\n' "$service" "$laravel_version" "${runtime_version:-unknown}"
        return 1
    fi
    source_hash=$(shasum -a 256 "$project_directory/composer.lock" | awk '{ print $1 }')
    runtime_hash=$(docker compose \
        --env-file "$compose_env_file" \
        --project-name "$project_name" \
        --file "$compose_file" \
        exec -T "$service" php -r 'echo hash_file("sha256", "composer.lock"), PHP_EOL;')
    if [ "$runtime_hash" != "$source_hash" ]; then
        printf 'Stale running container %s: composer.lock hash should be %s, found %s.\n' "$service" "$source_hash" "${runtime_hash:-unknown}"
        return 1
    fi
    printf 'Laravel runtime verified in %s: %s\n' "$service" "$runtime_version"
    printf 'composer.lock verified in %s: %s\n' "$service" "$runtime_hash"
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

if [ "$status" -eq 0 ]; then
    if [ "$architecture" = monolith ]; then
        verify_running_laravel_version \
            monolith "$MONOLITH_ROOT/.env.experiment" tcc-monolith-experiment \
            "$MONOLITH_ROOT/docker-compose.experiment.yml" "$MONOLITH_ROOT" >> "$run_directory/startup.log" 2>&1 || status=$?
    else
        for service in auth product order; do
            verify_running_laravel_version \
                "$service" "$CONTAINER_ROOT/.env.experiment" tcc-microservices-experiment \
                "$CONTAINER_ROOT/docker-compose.experiment.yml" "$PROJECTS_ROOT/tcc-$service-service" >> "$run_directory/startup.log" 2>&1 || status=$?
        done
    fi
fi

{
    printf 'protocol_version=2\n'
    printf 'result_set=%s\n' "${result_set:-legacy-default}"
    printf 'architecture=%s\n' "$architecture"
    printf 'repetition=%s\n' "$repetition"
    printf 'laravel_framework_version=%s\n' "$laravel_version"
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
