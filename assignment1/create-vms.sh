#!/usr/bin/env bash

set -euo pipefail # stop the script if an error or undefined variable occurs


# ==============================================================================
# CONFIGURATION
# ==============================================================================

USERNAME="cc_student"
SSH_KEYS_DICT="ssh_keys"
SSH_KEYS_NAME="ssh"
FIREWALL_RULE_NAME="allow-icmp-and-ssh-for-cc"

# Firewall rule configuration
NETWORK="default"
DIRECTION="INGRESS"
ACTION="ALLOW"
RULES="tcp:22,icmp"
SOURCE_RANGES="0.0.0.0/0" # Use "YOUR_PUBLIC_IP/32" to allow connections only from your public IPv4 address (Replace YOUR_PUBLIC_IP accordingly)
TAG="cloud-computing"

# VM configuration
ZONE="europe-west3-a"
MACHINE_TYPES=("n4-standard-2" "n4d-standard-2" "c4-standard-2") # in contrast to "e", "n" & "c" machines supports nested virtualization (used later for KVM benchmark)
IMAGE_FAMILY="ubuntu-2204-lts"
IMAGE_PROJECT="ubuntu-os-cloud"
BOOT_DISK_SIZE="100" # in GiB
VM_NAME_PREFIX="cloud-computing-vm"


# ==============================================================================
# Generate an SSH key pair (without passphrase)
# ==============================================================================

echo "[*] Generate SSH key pair"

# Create SSH key directory if necessary
mkdir -p "${SSH_KEYS_DICT}"

if [[ -f "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}" || -f "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}.pub" ]]; then
	echo "SSH keys already exist --> Skip key generation."
else
	echo "Generate SSH keys..."
	ssh-keygen -t ed25519 -f "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}" -C "${USERNAME}" -N "" >/dev/null 2>&1
fi


# ==============================================================================
# Configure SSH access through project metadata
# ==============================================================================

# Prepare public key in the format required for GCP project metadata. For metadata based SSH keys, the entry has the form: USERNAME:ssh-ed25519 AAAA... COMMENT 
echo "[*] Configure SSH access through project metadata"

echo -n "${USERNAME}:" > gcp-ssh-key.txt

tr -d '\r' < "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}.pub" >> gcp-ssh-key.txt

# Add key to project metadata
gcloud compute project-info add-metadata --metadata-from-file ssh-keys=gcp-ssh-key.txt

# Verifcation
LOCAL_KEY=$(cat gcp-ssh-key.txt)
CLOUD_KEY=$(gcloud compute project-info describe --format=json | jq -r '
	.commonInstanceMetadata.items[]?
    | select(.key == "ssh-keys")
    | .value
    ')

if [[ "${CLOUD_KEY}" == *"${LOCAL_KEY}"* ]]; then
	echo "Public key successfully added to project metadata."
else
	echo "Adding public key to the project metadata did not work. Terminate script..."
	exit 1
fi

# Cleanup
rm gcp-ssh-key.txt


# ==============================================================================
# Configure firewall rule
# ==============================================================================

echo "[*] Configure firewall rule"

if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" >/dev/null 2>&1; then
	echo "Firewall already exists --> Skip firewall configuration."
else
	# Add firewall rule
	gcloud compute firewall-rules create "${FIREWALL_RULE_NAME}" \
	--network="${NETWORK}" \
	--direction="${DIRECTION}" \
	--action="${ACTION}" \
	--rules="${RULES}" \
	--source-ranges="${SOURCE_RANGES}" \
	--target-tags="${TAG}"
fi

# Verification (tailored to RULES="tcp:22,icmp")
FIREWALL_JSON=$(gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" --format=json)

if jq -e \
    --arg network "${NETWORK}" \
    --arg direction "${DIRECTION}" \
    --arg source "${SOURCE_RANGES}" \
    --arg tag "${TAG}" \
    ' 
    (.network | endswith("/global/networks/" + $network)) and
    (.direction == $direction) and
    (.disabled == false) and
    (any(.allowed[]; .IPProtocol == "tcp" and ((.ports // []) | index("22") != null))) and
    (any(.allowed[]; .IPProtocol == "icmp")) and
    (.sourceRanges | index($source) != null) and
    (.targetTags | index($tag) != null)
    ' <<< "${FIREWALL_JSON}" >/dev/null; then

    echo "Firewall rule successfully configured."
else
    echo "Firewall rule configuration failed. Terminate script..."
    exit 1
fi


# ==============================================================================
# Create VMs
# ==============================================================================

echo "[*] Create different GCP VM instances"

for i in "${!MACHINE_TYPES[@]}"; do

    VM_NAME="${VM_NAME_PREFIX}-$((i + 1))"
    MACHINE_TYPE="${MACHINE_TYPES[$i]}"

    if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
		echo "VM already exists --> Skip VM creation."
	else
		# Create VM
		gcloud compute instances create "${VM_NAME}" \
		--zone="${ZONE}" \
		--machine-type="${MACHINE_TYPE}" \
		--image-family="${IMAGE_FAMILY}" \
		--image-project="${IMAGE_PROJECT}" \
		--boot-disk-size="${BOOT_DISK_SIZE}GB" \
		--tags="${TAG}" \
		--enable-nested-virtualization # for KVM
	fi

	# Verification (without checking image family/project)
	VM_DESCRIPTION_JSON=$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format=json)

	if jq -e \
	    --arg machine_type "${MACHINE_TYPE}" \
	    --arg disk_size "${BOOT_DISK_SIZE}" \
	    --arg tag "${TAG}" \
	    '
	    (.status == "RUNNING") and
	    (.machineType | endswith("/machineTypes/" + $machine_type)) and
	    (.disks[0].diskSizeGb == $disk_size) and
	    ((.tags.items // []) | index($tag) != null)
	    ' <<< "${VM_DESCRIPTION_JSON}" >/dev/null; then

	    echo "${VM_NAME} successfully created."
	else
	    echo "VM generation of ${VM_NAME} failed. Terminate script..."
	    exit 1
	fi
done
