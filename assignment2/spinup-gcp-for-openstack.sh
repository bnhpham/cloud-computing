#!/usr/bin/env bash

set -euo pipefail # stop the script if an error or undefined variable occurs


# ==============================================================================
# CONFIGURATION
# ==============================================================================

USERNAME="cc_student"
SSH_KEYS_DICT="ssh_keys"
SSH_KEYS_NAME="ssh"

# Firewall rule configuration
FIREWALL_RULE_NAME_PREFIX="allow-tcp-udp-icmp-for-subnets"
DIRECTION="INGRESS"
ACTION="ALLOW"
RULES="tcp,udp,icmp"
TAG="cc"
FIREWALL_RULE_NAME_EXTERNAL="allow-external-traffic"
RULES_EXTERNAL="tcp,icmp"
SOURCE_RANGES_EXTERNAL="0.0.0.0/0"

# VM configuration
#MACHINE_TYPES=("n4-standard-2" "n4d-standard-2" "c4-standard-2") # in contrast to "e", "n" & "c" machines supports nested virtualization (used later for KVM benchmark)
#IMAGE_FAMILY="ubuntu-2404-lts-amd64"
#IMAGE_PROJECT="ubuntu-os-cloud"
#BOOT_DISK_SIZE="100" # in GiB
#VM_NAME_PREFIX="cc-network"

# VPC networks and subnets
VPC_NETWORK_NAME_PREFIX="cc-network"
SUBNET_NAME_PREFIX="cc-subnet"
IP_RANGE_SUBNET1="10.10.0.0/24"
SECONDARY_RANGE_NAME="cc-secondary1"
SECONDARY_RANGE="10.10.1.0/24"
IP_RANGE_SUBNET2="10.20.0.0/24"
REGION="europe-west3"

# Disk
ZONE="europe-west3-a"
DISK_NAME="ubuntu-data-disk"
DISK_SIZE="100" # in GiB

# Image
IMAGE_NAME="ubuntu-nested-vm-image"
# license for nested virtualization --> no --enable-nested-virtualization required
LICENSE="https://www.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx"

# VMs
VM_NAMES=("controller" "compute1" "compute2")
MACHINE_TYPE="n2-standard-2"


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
# Create VPC networks
# ==============================================================================

echo "[*] Create 2 VPC networks"

for i in {1..2}; do

    VPC_NET_NAME="${VPC_NETWORK_NAME_PREFIX}$((i))"

	# Create VPC network
    if gcloud compute networks describe "${VPC_NET_NAME}" >/dev/null 2>&1; then
		echo "${VPC_NET_NAME} already exists --> Skip creation."
	else
		gcloud compute networks create "${VPC_NET_NAME}" --subnet-mode=custom

		echo "VPC network ${VPC_NET_NAME} successfully created."
	fi
done

# ==============================================================================
# Configure firewall rule
# ==============================================================================

# 2 internal rules, one per VPC (allow communication between VMs using private IP addresses)
for i in {1..2}; do

    VPC_NET_NAME="${VPC_NETWORK_NAME_PREFIX}$((i))"
	FIREWALL_RULE_NAME="${FIREWALL_RULE_NAME_PREFIX}$((i))"

	if [[ "${i}" -eq 1 ]]; then
		SOURCE_RANGES=""${IP_RANGE_SUBNET1}","${SECONDARY_RANGE}""
	else
		SOURCE_RANGES=""${IP_RANGE_SUBNET2}""
	fi

	echo "[*] Configure firewall rule for ${VPC_NET_NAME}"

	if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" >/dev/null 2>&1; then
		echo "Firewall already exists --> Skip firewall creation."
	else
		# Add firewall rule
		gcloud compute firewall-rules create "${FIREWALL_RULE_NAME}" \
		--network="${VPC_NET_NAME}" \
		--direction="${DIRECTION}" \
		--action="${ACTION}" \
		--rules="${RULES}" \
		--source-ranges="${SOURCE_RANGES}" \
		--target-tags="${TAG}"
	fi

	# Verification (tailored to RULES="tcp,udp,icmp")
	FIREWALL_JSON=$(gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" --format=json)

	if jq -e \
		--arg network "${VPC_NET_NAME}" \
		--arg direction "${DIRECTION}" \
		--arg tag "${TAG}" \
		--argjson sources "$(printf '%s\n' "${SOURCE_RANGES}" | jq -R 'split(",")')" \
		'
		(.network | endswith("/global/networks/" + $network)) and
		(.direction == $direction) and
		(.disabled == false) and
		([.allowed[].IPProtocol] | sort == (["tcp", "udp", "icmp"] | sort)) and
		(all(.allowed[]; (.ports // []) | length == 0)) and
		(.sourceRanges | sort == ($sources | sort)) and
		(.targetTags | index($tag) != null)
		' <<< "${FIREWALL_JSON}" >/dev/null; then

		echo "Firewall rule for ${VPC_NET_NAME} correctly configured."
	else
		echo "Firewall rule configuration failed. Terminate script..."
		exit 1
	fi

done

# 1 external rule, cc-network1 only (allow access to cc-network1 services from the internet)
VPC_NET_NAME=""${VPC_NETWORK_NAME_PREFIX}"1"

echo "[*] Configure firewall rule for traffic from external IPs for "${VPC_NET_NAME}""

if gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME_EXTERNAL}" >/dev/null 2>&1; then
	echo "Firewall already exists --> Skip firewall creation."
else
	# Add firewall rule
	gcloud compute firewall-rules create "${FIREWALL_RULE_NAME_EXTERNAL}" \
    --network="${VPC_NET_NAME}" \
    --direction=INGRESS \
    --action=ALLOW \
    --rules="${RULES_EXTERNAL}" \
    --source-ranges="${SOURCE_RANGES_EXTERNAL}" \
    --target-tags="${TAG}"
fi

# Verification (tailored to RULES_EXTERNAL="tcp,icmp")
FIREWALL_JSON=$(gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME_EXTERNAL}" --format=json)

if jq -e \
	--arg network "${VPC_NET_NAME}" \
	--arg direction "${DIRECTION}" \
	--arg tag "${TAG}" \
	--argjson sources "$(printf '%s\n' "${SOURCE_RANGES_EXTERNAL}" | jq -R 'split(",")')" \
	'
	(.network | endswith("/global/networks/" + $network)) and
	(.direction == $direction) and
	(.disabled == false) and
	([.allowed[].IPProtocol] | sort == (["tcp", "icmp"] | sort)) and
	(all(.allowed[]; (.ports // []) | length == 0)) and
	(.sourceRanges | sort == ($sources | sort)) and
	(.targetTags | index($tag) != null)
	' <<< "${FIREWALL_JSON}" >/dev/null; then

	echo "Firewall rule for ${VPC_NET_NAME} correctly configured."
else
	echo "Firewall rule configuration failed. Terminate script..."
	exit 1
fi


# ==============================================================================
# Create subnets
# ==============================================================================

echo "[*] Create 2 subnets"

# Subnet 1
if gcloud compute networks subnets describe "${SUBNET_NAME_PREFIX}1" --region="${REGION}" >/dev/null 2>&1; then
	echo "${SUBNET_NAME_PREFIX}1 already exists --> Skip creation."
else
	gcloud compute networks subnets create "${SUBNET_NAME_PREFIX}1" \
	--network="${VPC_NETWORK_NAME_PREFIX}1" \
	--region="${REGION}" \
	--range="${IP_RANGE_SUBNET1}" \
	--secondary-range="${SECONDARY_RANGE_NAME}"="${SECONDARY_RANGE}"

	echo "Subnet ${SUBNET_NAME_PREFIX}1 successfully created."
fi

# Subnet 2
if gcloud compute networks subnets describe "${SUBNET_NAME_PREFIX}2" --region="${REGION}" >/dev/null 2>&1; then
	echo "${SUBNET_NAME_PREFIX}2 already exists --> Skip creation."
else
	gcloud compute networks subnets create "${SUBNET_NAME_PREFIX}2" \
	--network="${VPC_NETWORK_NAME_PREFIX}2" \
	--region="${REGION}" \
	--range="${IP_RANGE_SUBNET2}"

	echo "Subnet ${SUBNET_NAME_PREFIX}2 successfully created."
fi


# ==============================================================================
# Create disk based on the “ubuntu-2404-lts-amd64” image family
# ==============================================================================

if gcloud compute disks describe "${DISK_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
	echo "${DISK_NAME} already exists --> Skip creation."
else
	gcloud compute disks create "${DISK_NAME}" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --size=${DISK_SIZE}GB \
    --zone="${ZONE}"

	echo "Disk ${DISK_NAME} successfully created."
fi


# ==============================================================================
# Create custom image with license for nested virtualization
# ==============================================================================

if gcloud compute images describe "${IMAGE_NAME}" >/dev/null 2>&1; then
	echo "${IMAGE_NAME} already exists --> Skip creation."
else
	gcloud compute images create "${IMAGE_NAME}" \
    --source-disk="${DISK_NAME}" \
    --source-disk-zone="${ZONE}" \
    --licenses="${LICENSE}"

	echo "Image ${IMAGE_NAME} successfully created."
fi


# ==============================================================================
# Create VMs
# ==============================================================================

echo "[*] Create 3 VM instances"

for VM_NAME in "${VM_NAMES[@]}"; do

    if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
		echo "${VM_NAME} already exists --> Skip VM creation."
	else
		# Create VM
		gcloud compute instances create "${VM_NAME}" \
		--zone="${ZONE}" \
		--machine-type="${MACHINE_TYPE}" \
		--tags="${TAG}" \
		--image="${IMAGE_NAME}" \
		--network-interface=subnet=cc-subnet1 \
    	--network-interface=subnet=cc-subnet2

		echo "VM ${VM_NAME} successfully created."
	fi
done





# chmod +x spinup-gcp-for-openstack.sh
# ./spinup-gcp-for-openstack.sh