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
RULES="tcp,icmp"
SOURCE_RANGES="0.0.0.0/0" # Use "YOUR_PUBLIC_IP/32" to allow connections only from your public IPv4 address (Replace YOUR_PUBLIC_IP accordingly)
TAG="cloud-computing"

# VM configuration
ZONE="europe-west3-a"
MACHINE_TYPE="n2-standard-2"
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

# Verification (tailored to RULES="tcp,icmp")
FIREWALL_JSON=$(gcloud compute firewall-rules describe "${FIREWALL_RULE_NAME}" --format=json)

if jq -e \
	--arg network "${NETWORK}" \
	--arg direction "${DIRECTION}" \
	--arg tag "${TAG}" \
	--argjson sources "$(printf '%s\n' "${SOURCE_RANGES}" | jq -R 'split(",")')" \
	'
	(.network | endswith("/global/networks/" + $network)) and
	(.direction == $direction) and
	(.disabled == false) and
	([.allowed[].IPProtocol] | sort == (["tcp", "icmp"] | sort)) and
	(all(.allowed[]; (.ports // []) | length == 0)) and
	(.sourceRanges | sort == ($sources | sort)) and
	(.targetTags | index($tag) != null)
	' <<< "${FIREWALL_JSON}" >/dev/null; then

	echo "Firewall rule ${FIREWALL_RULE_NAME} correctly configured."
else
	echo "Firewall rule configuration failed. Terminate script..."
	exit 1
fi


# ==============================================================================
# Create VMs
# ==============================================================================

echo "[*] Create 3 VM instances"

for i in {1..3}; do

    VM_NAME="${VM_NAME_PREFIX}-$((i))"

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


# ==============================================================================
# Verify password-less SSH access to the VMs and that the SSH user has a 
# password-less sudo prompt. Furthermore, install pip.
# ==============================================================================

echo "[*] Verify password-less SSH/sudo and install python3-pip"

# Private key copy with strict permissions (WSL: files on /mnt/c are always 0777)
SSH_KEY_RUNTIME="$(mktemp)"
cp "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}" "${SSH_KEY_RUNTIME}"
chmod 600 "${SSH_KEY_RUNTIME}"
trap 'rm -f "${SSH_KEY_RUNTIME}"' EXIT

# -i "${SSH_KEY_RUNTIME}": Uses the specified private SSH key file.
# -o StrictHostKeyChecking=accept-new: Automatically trusts and records the host key of a new/unknown server on
#   first connect, while still rejecting changed/mismatched keys
#   (safer than no, better for automation than interactive prompts).
# -o UserKnownHostsFile="${SSH_KEYS_DICT}/known_hosts": Stores known host keys in a custom file inside ${SSH_KEYS_DICT}
#    instead of ~/.ssh/known_hosts.
# -o ConnectTimeout=5: Gives up on a TCP connection attempt after 5 seconds instead of hanging.
# -o BatchMode=yes: Disables password/passphrase/interactive prompts so ssh fails immediately if key authentication isn't non-interactive
SSH_FLAGS=(-i "${SSH_KEY_RUNTIME}"
          -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="${SSH_KEYS_DICT}/known_hosts"
          -o ConnectTimeout=5 -o BatchMode=yes)

# Forget host keys from earlier runs: re-created VMs can reuse an external IP with a new host key
rm -f "${SSH_KEYS_DICT}/known_hosts"

for i in {1..3}; do

    VM_NAME="${VM_NAME_PREFIX}-${i}"
    IP=$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
    
	echo "${VM_NAME}: ${IP}"

    # Wait until SSH works (max 3 min)
    for attempt in {1..30}; do
        ssh "${SSH_FLAGS[@]}" "${USERNAME}@${IP}" true 2>/dev/null && break # run true (no-op command). If ssh succeeds, exit loop ("&& break")
        [[ ${attempt} -eq 30 ]] && { echo "SSH to ${VM_NAME} failed"; exit 1; }
        sleep 10
    done

    # Passwordless sudo check (-n = non-interactive --> Check fails immediately if a password would be required)
	# Single quotes around 'sudo -n true' ensure sudo -n true is evaluated on the remote VM, not locally.
    ssh "${SSH_FLAGS[@]}" "${USERNAME}@${IP}" 'sudo -n true' && echo "  passwordless sudo OK"

	# Refresh package lists quietly (sudo apt-get update -qq) and
    # install pip without interactive configuration prompts (DEBIAN_FRONTEND=noninteractive), auto-confirming (-y) and quietly (-qq)
    ssh "${SSH_FLAGS[@]}" "${USERNAME}@${IP}" \
        'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pip && pip3 --version'
done
