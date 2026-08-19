#!/bin/sh
set -eu

SCRIPT_DIRECTORY=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BENCHMARK_ROOT=$(CDPATH= cd -- "$SCRIPT_DIRECTORY/.." && pwd)
CONTAINER_ROOT=$(CDPATH= cd -- "$BENCHMARK_ROOT/.." && pwd)
PROJECTS_ROOT=$(CDPATH= cd -- "$CONTAINER_ROOT/.." && pwd)
MONOLITH_ROOT="$PROJECTS_ROOT/tcc-monolith"
JMETER_PROPERTIES="$BENCHMARK_ROOT/jmeter/benchmark.properties"
FINAL_IMAGE_MANIFEST="$BENCHMARK_ROOT/final-image-manifest.properties"

architecture=
scenario=
concurrency=
repetition=
pilot=false
pilot_attempt=
stabilization_seconds=15
warmup_seconds=30
measurement_seconds=120
cooldown_seconds=15

usage()
{
    printf '%s\n' "Usage: $0 --architecture {monolith|microservices} --scenario {products|orders|order-show|order-create} --concurrency {10|25|50|100} --repetition {1..5} [--pilot [--pilot-attempt LABEL]]" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --architecture)
            [ "$#" -ge 2 ] || usage
            architecture=$2
            shift 2
            ;;
        --scenario)
            [ "$#" -ge 2 ] || usage
            scenario=$2
            shift 2
            ;;
        --concurrency)
            [ "$#" -ge 2 ] || usage
            concurrency=$2
            shift 2
            ;;
        --repetition)
            [ "$#" -ge 2 ] || usage
            repetition=$2
            shift 2
            ;;
        --pilot)
            pilot=true
            warmup_seconds=10
            measurement_seconds=30
            shift
            ;;
        --pilot-attempt)
            [ "$#" -ge 2 ] || usage
            [ -n "$2" ] || usage
            pilot_attempt=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

case "$architecture" in monolith|microservices) ;; *) usage ;; esac
case "$scenario" in products|orders|order-show|order-create) ;; *) usage ;; esac
case "$concurrency" in 10|25|50|100) ;; *) usage ;; esac
case "$repetition" in 1|2|3|4|5) ;; *) usage ;; esac

if [ "$pilot" = true ] && { [ "$scenario" != products ] || [ "$concurrency" != 10 ] || [ "$repetition" != 1 ]; }; then
    printf '%s\n' 'The frozen pilot is only products, concurrency 10, repetition 1.' >&2
    exit 1
fi

if [ -n "$pilot_attempt" ]; then
    [ "$pilot" = true ] || {
        printf '%s\n' '--pilot-attempt may only be used with --pilot.' >&2
        exit 1
    }
    case "$pilot_attempt" in
        *[!A-Za-z0-9._-]*)
            printf '%s\n' '--pilot-attempt must contain only letters, numbers, dots, underscores, or hyphens.' >&2
            exit 1
            ;;
    esac
fi

case "$scenario" in
    products) plan="$BENCHMARK_ROOT/jmeter/tcc-products-v1.jmx" ;;
    orders) plan="$BENCHMARK_ROOT/jmeter/tcc-orders-v1.jmx" ;;
    order-show) plan="$BENCHMARK_ROOT/jmeter/tcc-order-show-v1.jmx" ;;
    order-create) plan="$BENCHMARK_ROOT/jmeter/tcc-order-create-v1.jmx" ;;
esac

if [ "$architecture" = monolith ]; then
    experiment_command="$MONOLITH_ROOT/bin/tcc-experiment"
    compose_file="$MONOLITH_ROOT/docker-compose.experiment.yml"
    compose_env_file="$MONOLITH_ROOT/.env.experiment"
    target_port=18000
    order_id=1
    current_project=tcc-monolith-experiment
    opposite_project=tcc-microservices-experiment
else
    experiment_command="$CONTAINER_ROOT/bin/tcc-experiment"
    compose_file="$CONTAINER_ROOT/docker-compose.experiment.yml"
    compose_env_file="$CONTAINER_ROOT/.env.experiment"
    target_port=18080
    order_id=20000000-0000-4000-8000-000000000001
    current_project=tcc-microservices-experiment
    opposite_project=tcc-monolith-experiment
fi

for required_command in docker curl php python3 java git shasum mktemp; do
    command -v "$required_command" >/dev/null 2>&1 || {
        printf 'Required command is not on PATH: %s\n' "$required_command" >&2
        exit 1
    }
done

[ -x "$experiment_command" ] || {
    printf 'Experiment command is missing or not executable: %s\n' "$experiment_command" >&2
    exit 1
}
[ -r "$compose_file" ] || {
    printf 'Experiment Compose file is not readable: %s\n' "$compose_file" >&2
    exit 1
}
[ -r "$compose_env_file" ] || {
    printf 'Missing experiment environment: %s. Run %s init.\n' "$compose_env_file" "$experiment_command" >&2
    exit 1
}
[ -r "$plan" ] || {
    printf 'JMeter plan is not readable: %s\n' "$plan" >&2
    exit 1
}
[ -r "$JMETER_PROPERTIES" ] || {
    printf 'JMeter properties are not readable: %s\n' "$JMETER_PROPERTIES" >&2
    exit 1
}

for repository in \
    "$MONOLITH_ROOT" \
    "$CONTAINER_ROOT" \
    "$PROJECTS_ROOT/api-gateway-core" \
    "$PROJECTS_ROOT/tcc-auth-service" \
    "$PROJECTS_ROOT/tcc-product-service" \
    "$PROJECTS_ROOT/tcc-order-service"; do
    git -C "$repository" rev-parse --git-dir >/dev/null 2>&1 || {
        printf 'Required Git repository is missing or invalid: %s\n' "$repository" >&2
        exit 1
    }
done

temporary_root=${TCC_BENCHMARK_TMPDIR:-${TMPDIR:-/tmp}}
[ -d "$temporary_root" ] && [ -w "$temporary_root" ] || {
    printf 'Benchmark temporary directory must exist and be writable: %s\n' "$temporary_root" >&2
    exit 1
}

local_jmeter="$CONTAINER_ROOT/.tools/apache-jmeter-5.6.3/bin/jmeter"
if [ -n "${TCC_JMETER_BIN:-}" ]; then
    jmeter_command=$TCC_JMETER_BIN
elif command -v jmeter >/dev/null 2>&1; then
    jmeter_command=jmeter
else
    jmeter_command=$local_jmeter
fi
command -v "$jmeter_command" >/dev/null 2>&1 || {
    printf 'Apache JMeter is not available: %s. Install JMeter 5.6.3 locally, add it to PATH, or set TCC_JMETER_BIN.\n' "$jmeter_command" >&2
    exit 1
}

jmeter_version=$("$jmeter_command" -j /dev/null --version 2>&1 | awk '/[0-9]+\.[0-9]+\.[0-9]+$/ { print $NF; exit }')
if [ "$jmeter_version" != 5.6.3 ]; then
    printf 'Apache JMeter 5.6.3 is required; found %s.\n' "${jmeter_version:-unknown}" >&2
    exit 1
fi

if [ -n "$(docker ps --filter "label=com.docker.compose.project=$opposite_project" --quiet)" ]; then
    printf 'Refusing to run while the opposite architecture project %s is active.\n' "$opposite_project" >&2
    exit 1
fi

result_class=final
if [ "$pilot" = true ]; then
    result_class=pilot
fi

result_name=$architecture
if [ -n "$pilot_attempt" ]; then
    result_name="$architecture-attempt-$pilot_attempt"
fi
run_directory="$BENCHMARK_ROOT/results/$result_class/$scenario/c$concurrency/r$repetition/$result_name"
if [ -e "$run_directory" ]; then
    printf 'Refusing to overwrite preserved benchmark output: %s\n' "$run_directory" >&2
    exit 1
fi

counter_properties="$run_directory/thread-counters.properties"
stack_started=false
resource_pid=
resource_ready_file="$run_directory/resource-collector.ready"
resource_start_file="$run_directory/resource-collector.start"

image_services()
{
    if [ "$architecture" = monolith ]; then
        printf '%s\n' 'monolith mysql'
    else
        printf '%s\n' 'gateway auth product order mysql'
    fi
}

image_id_for_reference()
{
    docker image inspect --format '{{.Id}}' "$1"
}

image_reference_for_service()
{
    case "$1" in
        monolith) printf '%s\n' 'tcc-monolith-experiment:php8.4.19' ;;
        gateway) printf '%s\n' 'tcc-gateway-experiment:java21' ;;
        auth) printf '%s\n' 'tcc-auth-experiment:php8.4.19' ;;
        product) printf '%s\n' 'tcc-product-experiment:php8.4.19' ;;
        order) printf '%s\n' 'tcc-order-experiment:php8.4.19' ;;
        mysql) printf '%s\n' 'mysql:8.4.8@sha256:2952e3be7807f06fc18de50b3ea1a632d5c70d63482ff7d7376fe3aa8999babf' ;;
        *) printf 'Unknown image service: %s\n' "$1" >&2; exit 1 ;;
    esac
}

manifest_image_id()
{
    manifest_key="image_id.$architecture.$1"
    sed -n "s/^$manifest_key=//p" "$FINAL_IMAGE_MANIFEST"
}

verify_final_image_manifest()
{
    [ "$pilot" = false ] || return 0

    if [ ! -f "$FINAL_IMAGE_MANIFEST" ]; then
        printf 'Missing final image manifest: %s. Run benchmark/scripts/freeze-final-images.sh after build benchmarking and before definitive HTTP conditions.\n' "$FINAL_IMAGE_MANIFEST" >&2
        exit 1
    fi

    for service in $(image_services); do
        reference=$(image_reference_for_service "$service")
        current_id=$(image_id_for_reference "$reference") || {
            printf 'Missing prebuilt image for %s: %s\n' "$service" "$reference" >&2
            exit 1
        }
        expected_id=$(manifest_image_id "$service")
        if [ -z "$expected_id" ]; then
            printf 'Final image manifest has no ID for %s.%s.\n' "$architecture" "$service" >&2
            exit 1
        fi
        if [ "$current_id" != "$expected_id" ]; then
            printf 'Final image mismatch for %s.%s: expected %s, found %s.\n' "$architecture" "$service" "$expected_id" "$current_id" >&2
            exit 1
        fi
    done
}

record_image_identity()
{
    for service in $(image_services); do
        container_id=$(docker compose \
            --env-file "$compose_env_file" \
            --project-name "$current_project" \
            --file "$compose_file" \
            ps --quiet "$service")
        if [ -z "$container_id" ]; then
            printf 'No running container found for image identity: %s\n' "$service" >&2
            exit 1
        fi
        image_id=$(docker inspect --format '{{.Image}}' "$container_id")
        if [ "$pilot" = false ]; then
            expected_id=$(manifest_image_id "$service")
            if [ "$image_id" != "$expected_id" ]; then
                printf 'Started container image mismatch for %s.%s: expected %s, found %s.\n' "$architecture" "$service" "$expected_id" "$image_id" >&2
                exit 1
            fi
        fi
        printf 'image_id.%s=%s\n' "$service" "$image_id" >> "$run_directory/condition.properties"
    done
}

verify_final_image_manifest
mkdir -p "$run_directory"
auth_directory=$(mktemp -d "$temporary_root/tcc-benchmark-auth.XXXXXX")
auth_properties="$auth_directory/auth.properties"

stop_stack()
{
    "$experiment_command" stop
    stack_started=false
}

cleanup()
{
    status=$?
    if [ -n "$resource_pid" ]; then
        kill "$resource_pid" >/dev/null 2>&1 || true
        wait "$resource_pid" >/dev/null 2>&1 || true
    fi
    if [ "$stack_started" = true ]; then
        "$experiment_command" stop >/dev/null 2>&1 || true
    fi
    rm -rf "$auth_directory"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

wait_for_url()
{
    ready_url=$1
    attempts=0
    until curl --fail --silent --show-error "$ready_url" >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 120 ]; then
            printf 'Timed out waiting for %s\n' "$ready_url" >&2
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
            printf 'Timed out waiting for %s at %s\n' "$service" "$service_url" >&2
            return 1
        fi
        sleep 1
    done
}

start_without_build()
{
    stack_started=true
    if [ "$architecture" = monolith ]; then
        docker compose \
            --env-file "$compose_env_file" \
            --project-name tcc-monolith-experiment \
            --file "$MONOLITH_ROOT/docker-compose.experiment.yml" \
            up --detach --no-build mysql monolith
        wait_for_url http://localhost:18000/up
    else
        docker compose \
            --env-file "$compose_env_file" \
            --project-name tcc-microservices-experiment \
            --file "$CONTAINER_ROOT/docker-compose.experiment.yml" \
            up --detach --no-build mysql auth product order gateway
        wait_for_microservice auth http://127.0.0.1:8003/up
        wait_for_microservice product http://127.0.0.1:8001/up
        wait_for_microservice order http://127.0.0.1:8002/up
        wait_for_url http://localhost:18080/actuator/health
    fi
}

write_auth_properties()
{
    umask 077
    if [ "$architecture" = monolith ]; then
        cookie_header=$(awk '
            /^#HttpOnly_/ { sub(/^#HttpOnly_/, "", $1) }
            !/^#/ && NF >= 7 {
                if (cookies != "") {
                    cookies = cookies "; "
                }
                cookies = cookies $6 "=" $7
            }
            END { print cookies }
        ' "$auth_directory/monolith.cookies")
        csrf_token=$(tr -d '\r\n' < "$auth_directory/monolith.csrf")
        if [ -z "$cookie_header" ] || [ -z "$csrf_token" ]; then
            printf '%s\n' 'Monolith authentication artifacts are incomplete.' >&2
            exit 1
        fi
        {
            printf 'tcc.auth.header.name=Cookie\n'
            printf 'tcc.auth.header.value=%s\n' "$cookie_header"
            printf 'tcc.csrf.token=%s\n' "$csrf_token"
        } > "$auth_properties"
    else
        jwt=$(tr -d '\r\n' < "$auth_directory/microservices.jwt")
        if [ -z "$jwt" ]; then
            printf '%s\n' 'Microservices authentication artifact is empty.' >&2
            exit 1
        fi
        {
            printf 'tcc.auth.header.name=Authorization\n'
            printf 'tcc.auth.header.value=Bearer %s\n' "$jwt"
            printf 'tcc.csrf.token=\n'
        } > "$auth_properties"
    fi
    chmod 600 "$auth_properties"
    umask 022
}

record_repository_state()
{
    : > "$run_directory/repositories.txt"
    for repository in \
        "$MONOLITH_ROOT" \
        "$CONTAINER_ROOT" \
        "$PROJECTS_ROOT/api-gateway-core" \
        "$PROJECTS_ROOT/tcc-auth-service" \
        "$PROJECTS_ROOT/tcc-product-service" \
        "$PROJECTS_ROOT/tcc-order-service"; do
        printf '%s\n' "repository=$repository" >> "$run_directory/repositories.txt"
        git -C "$repository" rev-parse HEAD >> "$run_directory/repositories.txt"
        git -C "$repository" status --short >> "$run_directory/repositories.txt"
        printf '\n' >> "$run_directory/repositories.txt"
    done
}

record_runtime_environment()
{
    {
        printf '%s\n' '[docker version]'
        docker version
        printf '%s\n' '[docker resource capacity]'
        docker info --format 'CPUs={{.NCPU}} MemoryBytes={{.MemTotal}} OperatingSystem={{.OperatingSystem}} Architecture={{.Architecture}}'
        printf '%s\n' '[jmeter version]'
        "$jmeter_command" -j /dev/null --version
        printf '%s\n' '[load-generator java version]'
        java -version
        printf '%s\n' '[load-generator operating system]'
        uname -a
    } > "$run_directory/runtime-environment.txt" 2>&1
}

printf 'Starting %s %s c%s r%s (%s).\n' "$architecture" "$scenario" "$concurrency" "$repetition" "$result_class"
start_without_build

"$experiment_command" reset > "$run_directory/reset.log" 2>&1
"$experiment_command" validate > "$run_directory/validation.log" 2>&1
"$experiment_command" auth "$auth_directory" > "$run_directory/authentication.log" 2>&1
write_auth_properties
record_repository_state
record_runtime_environment

{
    printf 'protocol_version=1\n'
    printf 'result_class=%s\n' "$result_class"
    printf 'architecture=%s\n' "$architecture"
    printf 'scenario=%s\n' "$scenario"
    printf 'concurrency=%s\n' "$concurrency"
    printf 'repetition=%s\n' "$repetition"
    printf 'target=http://localhost:%s\n' "$target_port"
    printf 'logical_order_1_physical_id=%s\n' "$order_id"
    printf 'stabilization_seconds=%s\n' "$stabilization_seconds"
    printf 'warmup_seconds=%s\n' "$warmup_seconds"
    printf 'measurement_seconds=%s\n' "$measurement_seconds"
    printf 'cooldown_seconds=%s\n' "$cooldown_seconds"
    printf 'jmeter_version=%s\n' "$jmeter_version"
    printf 'jmeter_plan_sha256=%s\n' "$(shasum -a 256 "$plan" | awk '{ print $1 }')"
    printf 'compose_project=%s\n' "$current_project"
    printf 'started_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$run_directory/condition.properties"

record_image_identity

printf 'Stabilizing for %s seconds.\n' "$stabilization_seconds"
sleep "$stabilization_seconds"

printf 'Running excluded warm-up for %s seconds.\n' "$warmup_seconds"
"$jmeter_command" -n \
    -t "$plan" \
    -q "$JMETER_PROPERTIES" \
    -q "$auth_properties" \
    -Jthreads="$concurrency" \
    -Jduration_seconds="$warmup_seconds" \
    -Jtarget_host=localhost \
    -Jtarget_port="$target_port" \
    -Jtcc.order.id="$order_id" \
    -Jrepetition="$repetition" \
    -l "$run_directory/warmup.jtl" \
    -j "$run_directory/warmup-jmeter.log"

python3 "$BENCHMARK_ROOT/analysis/extract-thread-counters.py" \
    --input "$run_directory/warmup.jtl" \
    --output "$counter_properties" \
    --threads "$concurrency"

printf 'Running timed workload and one-second resource sampling for %s seconds.\n' "$measurement_seconds"
python3 "$BENCHMARK_ROOT/scripts/collect-resources.py" \
    --architecture "$architecture" \
    --samples "$measurement_seconds" \
    --output-directory "$run_directory/resources" \
    --ready-file "$resource_ready_file" \
    --start-file "$resource_start_file" \
    > "$run_directory/resource-collector.log" 2>&1 &
resource_pid=$!

ready_attempts=0
until [ -f "$resource_ready_file" ]; do
    if ! kill -0 "$resource_pid" >/dev/null 2>&1; then
        wait "$resource_pid" || true
        resource_pid=
        printf '%s\n' 'Resource collector failed before becoming ready.' >&2
        exit 1
    fi
    ready_attempts=$((ready_attempts + 1))
    if [ "$ready_attempts" -ge 120 ]; then
        printf '%s\n' 'Timed out waiting for the resource collector.' >&2
        exit 1
    fi
    sleep 1
done

date -u '+%Y-%m-%dT%H:%M:%SZ' > "$resource_start_file"

"$jmeter_command" -n \
    -t "$plan" \
    -q "$JMETER_PROPERTIES" \
    -q "$auth_properties" \
    -q "$counter_properties" \
    -Jthreads="$concurrency" \
    -Jduration_seconds="$measurement_seconds" \
    -Jtarget_host=localhost \
    -Jtarget_port="$target_port" \
    -Jtcc.order.id="$order_id" \
    -Jrepetition="$repetition" \
    -l "$run_directory/timed.jtl" \
    -j "$run_directory/timed-jmeter.log"

if ! wait "$resource_pid"; then
    resource_pid=
    printf '%s\n' 'Resource collection failed; raw HTTP samples have been preserved.' >&2
    exit 1
fi
resource_pid=

python3 "$BENCHMARK_ROOT/analysis/analyze-run.py" \
    --timed-jtl "$run_directory/timed.jtl" \
    --warmup-jtl "$run_directory/warmup.jtl" \
    --individual-resources "$run_directory/resources/docker-stats-individual.csv" \
    --total-resources "$run_directory/resources/docker-stats-totals.csv" \
    --measurement-seconds "$measurement_seconds" \
    --warmup-seconds "$warmup_seconds" \
    --output-directory "$run_directory"

printf 'Cooling down for %s seconds.\n' "$cooldown_seconds"
sleep "$cooldown_seconds"
printf 'completed_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$run_directory/condition.properties"

stop_stack
trap - EXIT HUP INT TERM
rm -rf "$auth_directory"

printf 'Condition complete. Raw and derived output: %s\n' "$run_directory"
