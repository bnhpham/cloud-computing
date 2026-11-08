#!/usr/bin/env bash

set -euo pipefail # stop the script if an error or undefined variable occurs


# ==============================================================================
# CONFIGURATION
# ==============================================================================

USERNAME="cc_student"
SSH_KEYS_DICT="ssh_keys"
SSH_KEYS_NAME="ssh"
ZONE="europe-west3-a"
VM_NAME="${VM_NAME:-cloud-computing-vm-1}"


# ==============================================================================
# Connect to VM and run benchmarks
# ==============================================================================

# Copy private & public key to a location with proper unix permissions
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
cp "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}" "${HOME}/.ssh/${USERNAME}"
cp "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}.pub" "${HOME}/.ssh/${USERNAME}.pub"
chmod 600 "${HOME}/.ssh/${USERNAME}"
chmod 644 "${HOME}/.ssh/${USERNAME}.pub"

# Connect to VM and run benchmarks
if gcloud compute ssh "${USERNAME}@${VM_NAME}" --zone="${ZONE}" --ssh-key-file="${HOME}/.ssh/${USERNAME}" --command="bash -s" < benchmarks.sh; then
    :
else
    echo "Benchmark execution failed."
    exit 1
fi

