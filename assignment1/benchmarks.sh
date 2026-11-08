#!/usr/bin/env bash

set -euo pipefail # stop the script if an error or undefined variable occurs


# Unix epoch timestamp when measurements start
TIMESTAMP=$(date +%s)

# ==============================================================================
# Install sysbench inside the VM
# ==============================================================================

# Check if sysbench command exists. If not, install sysbench
if ! command -v sysbench >/dev/null 2>&1; then
	sudo apt update >/dev/null 2>&1
	sudo apt install -y sysbench >/dev/null 2>&1

	if ! command -v sysbench >/dev/null 2>&1; then
		echo "Installation failed --> Terminate script..."
		exit 1
	fi
fi


# ==============================================================================
# CPU benchmark
# ==============================================================================

# Measure CPU speed (events/s) by repeatedly checking whether numbers are prime up to 20,000
CPU_OUTPUT=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time=60 run)
CPU_SPEED=$(awk '/events per second:/ {print $4}' <<< "${CPU_OUTPUT}")


# ==============================================================================
# Memory benchmark
# ==============================================================================

# Measure memory access (MiB/s) by repeatedly performing memory-read operations using 4 KiB blocks
MEMORY_OUTPUT=$(sysbench memory --memory-block-size=4K --memory-total-size=100T --memory-oper=read --time=60 run)
MEMORY_SPEED=$(awk '/transferred/ {gsub(/[()]/, "", $4); print $4}' <<< "${MEMORY_OUTPUT}") # gsub for removing "("


# ==============================================================================
# Disk benchmarks
# ==============================================================================

# Delete test file whenever the bash script exits, whether successfully or because of an error
trap 'sysbench fileio --file-num=1 --file-total-size=1G cleanup >/dev/null 2>&1' EXIT

# Create 1GiB test file for the file I/O benchmarks
sysbench fileio --file-num=1 --file-total-size=1G prepare >/dev/null 2>&1

# Random disk read benchmark (Measure disk read speed (MiB/s) from randomly selected locations)
RANDOM_OUTPUT=$(sysbench fileio --file-num=1 --file-total-size=1G --file-test-mode=rndrd --file-io-mode=sync --file-extra-flags=direct --time=60 run)
RANDOM_SPEED=$(awk '/read, MiB\/s:/ {print $3}' <<< "${RANDOM_OUTPUT}")

# Sequential disk read benchmark (Measure disk read speed (MiB/s) of consecutive data portions)
SEQUENTIAL_OUTPUT=$(sysbench fileio --file-num=1 --file-total-size=1G --file-test-mode=seqrd --file-io-mode=sync --file-extra-flags=direct --time=60 run)
SEQUENTIAL_SPEED=$(awk '/read, MiB\/s:/ {print $3}' <<< "${SEQUENTIAL_OUTPUT}")


# ==============================================================================
# Verify extracted measurements
# ==============================================================================

for value in "${CPU_SPEED}" "${MEMORY_SPEED}" "${RANDOM_SPEED}" "${SEQUENTIAL_SPEED}"; do
	# Reject empty strings, negative numbers (including 0) and malformed decimals (such as "5.")
    if [[ ! "${value}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "The value '${value}' is not a positive float. Something went wrong during measurement extraction --> Terminate script..."
        exit 1
    fi
done


# ==============================================================================
# Output CSV
# ==============================================================================

printf '%s,%s,%s,%s,%s\n' "${TIMESTAMP}" "${CPU_SPEED}" "${MEMORY_SPEED}" "${RANDOM_SPEED}" "${SEQUENTIAL_SPEED}"