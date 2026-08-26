#!/bin/bash
# Record Docker lifecycle phases with VM-process and Docker-client accounting.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 RUNTIME_PID[,RUNTIME_PID...] OUTPUT_DIRECTORY" >&2
    exit 2
fi

RUNTIME_PID_LIST=$1
OUTPUT_DIRECTORY=$2
BOBRVM=${BOBRVM_BIN:-bobrvm}
DOCKER=${DOCKER_BIN:-docker}
IMAGE=${IMAGE:-alpine:3.20}
TRIALS=${TRIALS:-10}
WARMUPS=${WARMUPS:-3}
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
LABEL="dev.bobrvm.benchmark.run=$RUN_ID"
CONTAINER_NONE="bobrvm-bench-none-$RUN_ID"
CONTAINER_DEFAULT="bobrvm-bench-default-$RUN_ID"

IFS=',' read -r -a RUNTIME_PIDS <<<"$RUNTIME_PID_LIST"
BENCH_PID_ARGS=()
for runtime_pid in "${RUNTIME_PIDS[@]}"; do
    case "$runtime_pid" in
    ''|*[!0-9]*)
        echo "each RUNTIME_PID must be a positive process id" >&2
        exit 2
        ;;
    esac
    if [ "$runtime_pid" -eq 0 ]; then
        echo "each RUNTIME_PID must be a positive process id" >&2
        exit 2
    fi
    BENCH_PID_ARGS+=(--pid "$runtime_pid")
done

cleanup() {
    "$DOCKER" rm --force "$CONTAINER_NONE" "$CONTAINER_DEFAULT" >/dev/null 2>&1 || true
    "$DOCKER" container prune --force --filter "label=$LABEL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_benchmark() {
    local label=$1
    local warmups=$2
    shift 2
    "$BOBRVM" bench-command \
        "${BENCH_PID_ARGS[@]}" \
        --trials "$TRIALS" \
        --warmups "$warmups" \
        --label "$label" \
        -- "$@" >"$OUTPUT_DIRECTORY/$label.json"
}

command -v "$BOBRVM" >/dev/null
command -v "$DOCKER" >/dev/null
"$DOCKER" image inspect "$IMAGE" >/dev/null
mkdir -p "$OUTPUT_DIRECTORY"

run_benchmark docker-api "$WARMUPS" \
    "$DOCKER" version --format '{{.Server.Version}}'
run_benchmark docker-run-none "$WARMUPS" \
    "$DOCKER" run --rm --network none "$IMAGE" true
run_benchmark docker-run-host "$WARMUPS" \
    "$DOCKER" run --rm --network host "$IMAGE" true
run_benchmark docker-run-default "$WARMUPS" \
    "$DOCKER" run --rm "$IMAGE" true
run_benchmark docker-create-none 0 \
    "$DOCKER" create --label "$LABEL" --network none "$IMAGE" true

"$DOCKER" create --name "$CONTAINER_NONE" --network none "$IMAGE" true >/dev/null
"$DOCKER" create --name "$CONTAINER_DEFAULT" "$IMAGE" true >/dev/null
run_benchmark docker-start-none "$WARMUPS" \
    "$DOCKER" start --attach "$CONTAINER_NONE"
run_benchmark docker-start-default "$WARMUPS" \
    "$DOCKER" start --attach "$CONTAINER_DEFAULT"

echo "Docker lifecycle results: $OUTPUT_DIRECTORY"
