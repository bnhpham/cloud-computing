#!/usr/bin/env bash

set -euo pipefail # stop the script if an error or undefined variable occurs


# ==============================================================================
# CONFIGURATION
# ==============================================================================

USERNAME="cc_student"
SSH_KEYS_DICT="ssh_keys"
SSH_KEYS_NAME="ssh"
FIREWALL_RULE_NAME="allow-icmp-and-ssh-for-cc"
ZONE="europe-west3-a"
VM_NAME_PREFIX="cloud-computing-vm"
NUM_MACHINES=3


# ==============================================================================
# Delete assignment VMs
# ==============================================================================

echo "[*] Delete VMs"

# Find existing VMs in the configured zone
mapfile -t VM_NAMES < <(
    gcloud compute instances list --zones="${ZONE}" --format="value(name)"
)

for VM_NAME in "${VM_NAMES[@]}"; do

    # Only delete VMs named "cloud-computing-vm-<number>"
    if [[ ! "${VM_NAME}" =~ ^${VM_NAME_PREFIX}-[0-9]+$ ]]; then
        continue
    fi

    # Deletion
    if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
        gcloud compute instances delete "${VM_NAME}" --zone="${ZONE}" --quiet
        echo "${VM_NAME} successfully deleted."
    else
        echo "${VM_NAME} does not exist --> Skip deletion."
    fi

    # Delete remaining boot disk
    # The boot disk is expected to have the same name as the VM. It should normally be deleted automatically with the VM.
    if gcloud compute disks describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
        DISK_USERS=$(gcloud compute disks describe "${VM_NAME}" --zone="${ZONE}" --format="value(users)")

        if [[ -z "${DISK_USERS}" ]]; then
            gcloud compute disks delete "${VM_NAME}" --zone="${ZONE}" --quiet
            echo "Remaining boot disk successfully deleted."
        else
            echo "Disk is still attached to one or more other VMs. --> Skip deletion."
        fi
    else
        echo "No remaining boot disk found."
    fi

done


# ==============================================================================
# Delete firewall rule
# ==============================================================================

echo "[*] Delete firewall rule"

if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" >/dev/null 2>&1; then
    gcloud compute firewall-rules delete "${FIREWALL_RULE_NAME}" --quiet
    echo "Firewall rule successfully deleted."
else
    echo "Firewall rule does not exist --> Skip deletion."
fi


# ==============================================================================
# Delete ALL SSH keys from project metadata
# ==============================================================================

echo "[*] Delete ALL SSH keys from project metadata"

# Check whether the project has an ssh-keys metadata entry
SSH_KEYS=$(gcloud compute project-info describe --format=json | jq -r '
        [.commonInstanceMetadata.items[]?
         | select(.key == "ssh-keys")
         | .value][0] // ""
    ')

# if ssh-keys metadata exists, remove the entire entry
if [[ -n "${SSH_KEYS}" ]]; then
    gcloud compute project-info remove-metadata --keys=ssh-keys
    echo "All project-level SSH keys successfully removed."
else
    echo "No project-level SSH keys found --> Skip deletion."
fi


# ==============================================================================
# Delete local SSH key copy
# ==============================================================================

echo "[*] Delete local SSH key COPY"

SSH_KEY_COPY="${HOME}/.ssh/${USERNAME}"

if [[ -f "${SSH_KEY_COPY}" ]]; then
    rm -- "${SSH_KEY_COPY}"
    echo "Local SSH key copy successfully deleted."
else
    echo "Local SSH key copy does not exist --> Skip deletion."
fi


# ==============================================================================
# Delete local SSH key copy
# ==============================================================================

echo "[*] Delete SSH key pair"

if [[ -d "./${SSH_KEYS_DICT}" ]]; then
    rm -r "./${SSH_KEYS_DICT}"
    echo "SSH key pair successfully deleted."
else
    echo "SSH key pair does not exist --> Skip deletion."
fi

# ==============================================================================
# Final verification
# ==============================================================================

echo ""
echo "Remaining VMs:"
gcloud compute instances list

echo ""
echo "Remaining disks:"
gcloud compute disks list

echo ""
echo "Cleanup completed."