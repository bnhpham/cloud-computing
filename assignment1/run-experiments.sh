
#!/usr/bin/env bash
set -euo pipefail


# ==============================================================================
# CONFIGURATION
# ==============================================================================

# Resolve paths relative to this script
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
RUNS_DIR="${RESULTS_DIR}/runs"
LOGS_DIR="${RESULTS_DIR}/logs"

ZONE="europe-west3-a"
MACHINE_TYPES=("n4-standard-2" "n4d-standard-2" "c4-standard-2")
ENVIRONMENTS=("native" "docker" "kvm" "qemu")
VM_NAME_PREFIX="cloud-computing-vm"

REPETITIONS=1

mkdir -p "${RUNS_DIR}" "${LOGS_DIR}"

# csv header
if [[ ! -f "${RESULTS_DIR}/runs.csv" ]]; then
    echo "machine_type,vm_name,environment,repetition,start_time,end_time,exit_code,status" > "${RESULTS_DIR}/runs.csv"
fi


# ==============================================================================
# MAP ENVIRONMENTS TO LAUNCHER SCRIPTS
# ==============================================================================

get_launcher() {
    case "$1" in
        native)
            echo "${ROOT_DIR}/start-native-linux-benchmarks.sh"
            ;;
        docker)
            echo "${ROOT_DIR}/start-docker-benchmarks.sh"
            ;;
        kvm)
            echo "${ROOT_DIR}/start-kvm-benchmarks.sh"
            ;;
        qemu)
            echo "${ROOT_DIR}/start-qemu-benchmarks.sh"
            ;;
        *)
            echo "Unknown environment: $1" >&2
            return 1
            ;;
    esac
}


# ==============================================================================
# CREATE AGGREGATED RESULTS
# ==============================================================================

rebuild_results() {
    local output="${RESULTS_DIR}/measurements.csv"
    local temporary="${output}.tmp"

    printf '%s\n' \
        "machine_type,vm_name,environment,repetition,timestamp,cpu_events_per_second,memory_MiB_per_second,random_read_MiB_per_second,sequential_read_MiB_per_second" \
        > "${temporary}"

    local file
    local filename
    local machine_type
    local vm_name
    local environment
    local repetition
    local timestamp
    local cpu
    local memory
    local random_read
    local sequential_read

    # Each completed run is stored in a separate file.
    # Rebuilding from these files prevents duplicate rows.
    for file in "${RUNS_DIR}"/*.csv; do
        [[ -f "${file}" ]] || continue

        filename="$(basename "${file}" .csv)"

        # Files use the format:
        # machineType__vmName__environment__repetition.csv
        IFS='|' read -r machine_type vm_name environment repetition <<< "${filename//__/|}"

        IFS=',' read -r timestamp cpu memory random_read sequential_read < "${file}"

        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "${machine_type}" \
            "${vm_name}" \
            "${environment}" \
            "${repetition}" \
            "${timestamp}" \
            "${cpu}" \
            "${memory}" \
            "${random_read}" \
            "${sequential_read}" \
            >> "${temporary}"
    done

    mv "${temporary}" "${output}"
}


# ==============================================================================
# VALIDATE BENCHMARK OUTPUT
# ==============================================================================

validate_result() {
    local file="$1"
    local line
    local timestamp
    local cpu
    local memory
    local random_read
    local sequential_read
    local extra

    # Exactly one CSV line is required.
    [[ "$(wc -l < "${file}")" -eq 1 ]] || return 1

    line="$(cat "${file}")"

    IFS=',' read -r timestamp cpu memory random_read sequential_read extra <<< "${line}"

    [[ -z "${extra:-}" ]] || return 1
    [[ "${timestamp}" =~ ^[0-9]+$ ]] || return 1

    local number_regex='^[0-9]+([.][0-9]+)?$'

    for value in "${cpu}" "${memory}" "${random_read}" "${sequential_read}"; do
        [[ "${value}" =~ ${number_regex} ]] || return 1
    done
}


# ==============================================================================
# EXECUTE EXPERIMENTS
# ==============================================================================

echo "[*] Starting experiment matrix" >&2

# Create the aggregate file even if no runs exist yet.
rebuild_results

FAILURES=0

for i in "${!MACHINE_TYPES[@]}"; do

    MACHINE_TYPE="${MACHINE_TYPES[$i]}"
    VM_NAME="${VM_NAME_PREFIX}-$((i + 1))"

    echo "[*] Machine: ${VM_NAME} (${MACHINE_TYPE})" >&2

    # Verify the VM exists and has the expected machine type.
    ACTUAL_TYPE=$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format="value(machineType.basename())")

    if [[ "${ACTUAL_TYPE}" != "${MACHINE_TYPE}" ]]; then
        echo "Machine type mismatch for ${VM_NAME}" >&2
        exit 1
    fi

    for ENVIRONMENT in "${ENVIRONMENTS[@]}"; do

        LAUNCHER="$(get_launcher "${ENVIRONMENT}")"

        if [[ ! -f "${LAUNCHER}" ]]; then
            echo "Launcher not found: ${LAUNCHER}" >&2
            exit 1
        fi

        for REPETITION in $(seq 1 "${REPETITIONS}"); do

            RUN_ID="${MACHINE_TYPE}__${VM_NAME}__${ENVIRONMENT}__${REPETITION}"

            RESULT_FILE="${RUNS_DIR}/${RUN_ID}.csv"
            TEMP_FILE="${RUNS_DIR}/${RUN_ID}.tmp"
            LOG_FILE="${LOGS_DIR}/${RUN_ID}.log"

            # Resume support: Skip successfully completed runs.
            if [[ -f "${RESULT_FILE}" ]] &&
               validate_result "${RESULT_FILE}"; then

                echo "[SKIP] ${RUN_ID} already completed" >&2
                continue
            fi

            # Remove incomplete or invalid previous results.
            rm -f "${TEMP_FILE}" "${RESULT_FILE}"

            echo "[RUN] ${RUN_ID}" >&2

            START_TIME="$(date +%s)"

            # Run synchronously: the next experiment starts only after this one has finished.
            if (
                cd "${ROOT_DIR}"
                VM_NAME="${VM_NAME}" bash "${LAUNCHER}"
            ) > "${TEMP_FILE}" 2> "${LOG_FILE}"; then
                EXIT_CODE=0
            else
                EXIT_CODE=$?
            fi

            END_TIME="$(date +%s)"

            if [[ "${EXIT_CODE}" -eq 0 ]] &&
               validate_result "${TEMP_FILE}"; then

                # Atomically publish a completed result.
                mv "${TEMP_FILE}" "${RESULT_FILE}"

                echo "[OK] ${RUN_ID}" >&2
                STATUS="success"

                # Update aggregate CSV after each successful run.
                rebuild_results
            else
                echo "[FAIL] ${RUN_ID} (exit=${EXIT_CODE})" >&2

                STATUS="failed"
                FAILURES=$((FAILURES + 1))

                # Keep failed output for debugging.
                if [[ -f "${TEMP_FILE}" ]]; then
                    mv "${TEMP_FILE}" "${LOGS_DIR}/${RUN_ID}.stdout"
                fi
            fi

            # Append an execution record, including failures.
            printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "${MACHINE_TYPE}" \
                "${VM_NAME}" \
                "${ENVIRONMENT}" \
                "${REPETITION}" \
                "${START_TIME}" \
                "${END_TIME}" \
                "${EXIT_CODE}" \
                "${STATUS}" \
                >> "${RESULTS_DIR}/runs.csv"

        done
    done
done


# ==============================================================================
# FINAL SUMMARY
# ==============================================================================

rebuild_results

COMPLETED=$(find "${RUNS_DIR}" -maxdepth 1 -name '*.csv' | wc -l)

echo "[*] Experiment execution finished." >&2
echo "[*] Completed runs: ${COMPLETED}/60" >&2
echo "[*] Failed attempts this invocation: ${FAILURES}" >&2
echo "[*] Results: ${RESULTS_DIR}/measurements.csv" >&2

if (( FAILURES > 0 )); then
    exit 1
fi

# chmod +x run-experiments.sh
# ./run-experiments.sh