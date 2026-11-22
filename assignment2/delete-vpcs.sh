#!/usr/bin/env bash

set -euo pipefail # stop the script if an error or undefined variable occurs


# ==============================================================================
# CONFIGURATION
# ==============================================================================

USERNAME="cc_student"
SSH_KEYS_DICT="ssh_keys"
SSH_KEYS_NAME="ssh"
FIREWALL_RULE_NAME_PREFIX="allow-tcp-udp-icmp-for-subnets"
FIREWALL_RULE_NAME_EXTERNAL="allow-external-traffic"
ZONE="europe-west3-a"

# VPC networks and subnets
VPC_NETWORK_NAME_PREFIX="cc-network"
SUBNET_NAME_PREFIX="cc-subnet"
REGION="europe-west3"

# Disk
ZONE="europe-west3-a"
DISK_NAME="ubuntu-data-disk"

# Image
IMAGE_NAME="ubuntu-nested-vm-image"

# VMs
VM_NAMES=("controller" "compute1" "compute2")


# ==============================================================================
# Delete VMs
# ==============================================================================

echo "[*] Delete VMs"

for VM_NAME in "${VM_NAMES[@]}"; do

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

echo "[*] Delete firewall rules"

for i in {1..2}; do
    FIREWALL_RULE_NAME="${FIREWALL_RULE_NAME_PREFIX}$((i))"

    if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" >/dev/null 2>&1; then
        gcloud compute firewall-rules delete "${FIREWALL_RULE_NAME}" --quiet
        echo "Firewall rule "${FIREWALL_RULE_NAME}" successfully deleted."
    else
        echo "Firewall rule "${FIREWALL_RULE_NAME}" does not exist --> Skip deletion."
    fi
done

if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME_EXTERNAL}" >/dev/null 2>&1; then
    gcloud compute firewall-rules delete "${FIREWALL_RULE_NAME_EXTERNAL}" --quiet
    echo "Firewall rule "${FIREWALL_RULE_NAME_EXTERNAL}" successfully deleted."
else
    echo "Firewall rule "${FIREWALL_RULE_NAME_EXTERNAL}" does not exist --> Skip deletion."
fi


# ==============================================================================
# Delete VPC networks and subnets
# ==============================================================================

echo "[*] Delete VPC networks"

for i in {1..2}; do

    # Delete subnet
    SUBNET_NAME="${SUBNET_NAME_PREFIX}$((i))"
    if gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" >/dev/null 2>&1; then
        gcloud compute networks subnets delete "${SUBNET_NAME}" --region="${REGION}" --quiet
        echo ""${SUBNET_NAME}" successfully deleted."
    else
        echo ""${SUBNET_NAME}" does not exist --> Skip deletion."
    fi

    # Delete VPC network
    VPC_NET_NAME="${VPC_NETWORK_NAME_PREFIX}$((i))"
    if gcloud compute networks describe "${VPC_NET_NAME}" >/dev/null 2>&1; then
        gcloud compute networks delete "${VPC_NET_NAME}" --quiet
        echo ""${VPC_NET_NAME}" successfully deleted."
    else
        echo ""${VPC_NET_NAME}" does not exist --> Skip deletion."
    fi
done


# ==============================================================================
# Delete disk
# ==============================================================================

echo "[*] Delete disk"

if gcloud compute disks describe "${DISK_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
    gcloud compute disks delete "${DISK_NAME}" --zone="${ZONE}" --quiet
    echo ""${DISK_NAME}" successfully deleted."
else
    echo ""${DISK_NAME}" does not exist --> Skip deletion."
fi


# ==============================================================================
# Delete image
# ==============================================================================

echo "[*] Delete image"

if gcloud compute images describe "${IMAGE_NAME}" >/dev/null 2>&1; then
	gcloud compute images delete "${IMAGE_NAME}" --quiet
    echo ""${IMAGE_NAME}" successfully deleted."
else
	echo ""${IMAGE_NAME}" does not exist --> Skip deletion."
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
echo "Remaining VPC networks:"
gcloud compute networks list

echo ""
echo "Remaining subnets:"
gcloud compute networks subnets list

echo ""
echo "Remaining VMs:"
gcloud compute instances list

echo ""
echo "Remaining disks:"
gcloud compute disks list

echo ""
echo "Cleanup completed."

# chmod +x delete-vpcs.sh
# ./delete-vpcs.sh