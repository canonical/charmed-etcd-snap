#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Configurable parameters
# -----------------------------

ENDPOINT="${ENDPOINT:-http://localhost:2379}"
BENCH_BIN="${BENCH_BIN:-$SNAP/bin/benchmark}"

RATIO_LIST="${RATIO_LIST:-1/128 1/8 1/4 1/2 2/1 4/1 8/1 128/1}"
VALUE_SIZE_POWER_RANGE="${VALUE_SIZE_POWER_RANGE:-8 14}"
CONN_CLI_COUNT_POWER_RANGE="${CONN_CLI_COUNT_POWER_RANGE:-5 11}"

REPEAT_COUNT="${REPEAT_COUNT:-5}"
RUN_COUNT="${RUN_COUNT:-200000}"

KEY_SIZE="${KEY_SIZE:-256}"
KEY_SPACE_SIZE="${KEY_SPACE_SIZE:-65536}"
RANGE_RESULT_LIMIT="${RANGE_RESULT_LIMIT:-100}"

OUTPUT_FILE="${OUTPUT_FILE:-result-$(date '+%Y%m%d%H%M').csv}"

# -----------------------------
# Helpers
# -----------------------------

log() {
  echo "[rw-benchmark] $*"
}

require_cmd() {
  command -v "$1" >/dev/null || {
    echo "Missing required command: $1"
    exit 1
  }
}

run_benchmark() {
  local ratio="$1"
  local conns="$2"
  local value_size="$3"

  ${BENCH_BIN} txn-mixed "" \
    --conns="${conns}" \
    --clients="${conns}" \
    --total="${RUN_COUNT}" \
    --endpoints "${ENDPOINT}" \
    --rw-ratio "${ratio}" \
    --limit "${RANGE_RESULT_LIMIT}" \
    --val-size "${value_size}" \
    2>/dev/null | grep "Requests/sec" | awk '{print $2}'
}

init_db() {
  log "initializing etcd dataset"

  ${BENCH_BIN} put \
    --sequential-keys \
    --key-space-size="${KEY_SPACE_SIZE}" \
    --val-size="${VALUE_SIZE}" \
    --key-size="${KEY_SIZE}" \
    --endpoints "${ENDPOINT}" \
    --total="${KEY_SPACE_SIZE}" \
    >/dev/null
}

write_csv_header() {
  echo -n "type,ratio,conn_size,value_size" > "${OUTPUT_FILE}"

  for i in $(seq 1 "${REPEAT_COUNT}"); do
    echo -n ",iter${i}" >> "${OUTPUT_FILE}"
  done

  echo ",comment" >> "${OUTPUT_FILE}"

  echo "PARAM,,,,$(printf ',%.0s' $(seq 1 ${REPEAT_COUNT}))\"key_size=${KEY_SIZE},key_space_size=${KEY_SPACE_SIZE},range_limit=${RANGE_RESULT_LIMIT}\"" >> "${OUTPUT_FILE}"
}

# -----------------------------
# Start
# -----------------------------

require_cmd "${BENCH_BIN}"
require_cmd bc

if [[ -f "${OUTPUT_FILE}" ]]; then
  echo "Output file already exists: ${OUTPUT_FILE}"
  exit 1
fi

write_csv_header

TOTAL_ITER=$(( \
  $(echo ${RATIO_LIST} | wc -w) * \
  $(seq ${VALUE_SIZE_POWER_RANGE} | wc -l) * \
  $(seq ${CONN_CLI_COUNT_POWER_RANGE} | wc -l) \
))

ITER=0

log "starting benchmark"
log "endpoint: ${ENDPOINT}"
log "output: ${OUTPUT_FILE}"

for RATIO_STR in ${RATIO_LIST}; do

  RATIO=$(echo "scale=4; ${RATIO_STR}" | bc -l)

  for VALUE_SIZE_POWER in $(seq ${VALUE_SIZE_POWER_RANGE}); do

    VALUE_SIZE=$((2 ** VALUE_SIZE_POWER))

    init_db

    for CONN_POWER in $(seq ${CONN_CLI_COUNT_POWER_RANGE}); do

      CONNS=$((2 ** CONN_POWER))
      ITER=$((ITER + 1))

      PERCENT=$(echo "scale=2; ${ITER}/${TOTAL_ITER}*100" | bc -l)
      log "progress ${PERCENT}%"

      LINE="DATA,${RATIO},${CONNS},${VALUE_SIZE}"

      echo -n "run ratio=${RATIO} conns=${CONNS} val=${VALUE_SIZE}"

      for i in $(seq ${REPEAT_COUNT}); do

        echo -n "."

        QPS=$(run_benchmark "${RATIO}" "${CONNS}" "${VALUE_SIZE}")

        RD_QPS=$(echo "${QPS}" | sed -n '1p')
        WR_QPS=$(echo "${QPS}" | sed -n '2p')

        RD_QPS=${RD_QPS:-0}
        WR_QPS=${WR_QPS:-0}

        LINE="${LINE},${RD_QPS}:${WR_QPS}"

      done

      echo

      echo "${LINE}," >> "${OUTPUT_FILE}"

    done
  done
done

log "benchmark complete"
log "results written to ${OUTPUT_FILE}"