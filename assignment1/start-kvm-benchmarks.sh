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

SSH_KEY="${HOME}/.ssh/${USERNAME}"


# ==============================================================================
# Prepare SSH key for connecting to the GCP VM
# ==============================================================================

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

cp "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}" "${SSH_KEY}"
cp "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}.pub" "${SSH_KEY}.pub"

chmod 600 "${SSH_KEY}"
chmod 644 "${SSH_KEY}.pub"


# ==============================================================================
# Transfer benchmark script to GCP VM
# ==============================================================================

echo "[*] Transfer benchmarks.sh to GCP VM" >&2

gcloud compute scp benchmarks.sh "${USERNAME}@${VM_NAME}:~/" --zone="${ZONE}" --ssh-key-file="${SSH_KEY}"


# ==============================================================================
# Create KVM guest and execute benchmarks
# ==============================================================================

gcloud compute ssh "${USERNAME}@${VM_NAME}" \
    --zone="${ZONE}" \
    --ssh-key-file="${SSH_KEY}" \
    --command="bash -s" <<'REMOTE_SCRIPT'

set -euo pipefail

GUEST_NAME="ubuntu-kvm"                             # Name of VM used by libvirt to identify it
GUEST_VCPUS=2                                       # Number of virtual CPUs assigned to the guest
GUEST_RAM=4096                                      # RAM in (MiB) assigned to the guest
GUEST_DISK_SIZE=20                                  # Guest's virtual disk capacity (in GiB)

IMAGE_DIR="/var/lib/libvirt/images"                 # Directory on the GCP VM, where libvirt stores virtual disk images
GUEST_DISK="${IMAGE_DIR}/${GUEST_NAME}.qcow2"       # Path to the guest's virtual hard disk (.qcow2 is a QEMU disk image format)
GUEST_SEED="${IMAGE_DIR}/${GUEST_NAME}-seed.iso"    # Path to the cloud-init ISO containing the guest's initial configuration, such as its user account and SSH key

GUEST_KEY="${HOME}/.ssh/kvm_guest"                  # Path to the SSH private key used to connect from the GCP VM to the nested Ubuntu guest


# ==============================================================================
# Install packages needed to run a nested Ubuntu VM using KVM
# ==============================================================================

echo "[*] Check & install KVM packages" >&2

# qemu-kvm:                 Provides QEMU/KVM integration for hardware-accelerated virtualization
# qemu-system-x86:          Emulates an x86 computer to run the Ubuntu guest
# libvirt-daemon-system:    Provides the service for managing virtual machine.
# virtinst:                 Provides virt-install, used to create the Ubuntu guest
# cloud-image-utils:        Provides cloud-localds, which creates the cloud-init configuration ISO
# wget:                     Downloads the Ubuntu cloud image
# openssh-client:           Provides SSH to connect to the nested Ubuntu guest
# qemu-utils:               Provides qemu-img to create, convert, and resize virtual disks

if ! command -v virt-install >/dev/null 2>&1; then
    sudo apt-get update >&2
    sudo apt-get install -y qemu-kvm qemu-system-x86 libvirt-daemon-system virtinst cloud-image-utils wget openssh-client >&2
fi

# Ensure additional required utilities are installed
if ! command -v cloud-localds >/dev/null 2>&1; then
    sudo apt-get update >&2
    sudo apt-get install -y cloud-image-utils >&2 # might seem redundant but in the first check above, we checked for "virt-install" instead of "cloud-localds"
fi

if ! command -v qemu-img >/dev/null 2>&1; then
    sudo apt-get install -y qemu-utils >&2
fi

# Verify KVM availability
if [[ ! -e /dev/kvm ]]; then
    echo "KVM is unavailable. --> Terminate script..." >&2
    exit 1
fi

# Start the libvirt service
sudo systemctl enable --now libvirtd >&2

# Check whether default libvirt NAT network exists
if ! sudo virsh net-info default >/dev/null 2>&1; then
    echo "The default libvirt network does not exist. --> Terminate script..." >&2
    exit 1
fi

# Start that network if it is not already active
if ! sudo virsh net-info default | grep -q 'Active:.*yes'; then
    sudo virsh net-start default
fi


# ==============================================================================
# Prepare SSH access to nested guest
# ==============================================================================

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [[ ! -f "${GUEST_KEY}" ]]; then
    ssh-keygen -t ed25519 -N "" -f "${GUEST_KEY}" >&2
fi


# ==============================================================================
# Create and start nested Ubuntu guest (only once)
# ==============================================================================

if ! sudo virsh dominfo "${GUEST_NAME}" >/dev/null 2>&1; then

    echo "[*] Download Ubuntu 22.04 cloud image" >&2
    wget -q https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O "${HOME}/ubuntu-cloud.img"

    # Copy/convert the downloaded image into the guest's virtual hard disk using the QCOW2 format.
    sudo qemu-img convert -f qcow2 -O qcow2 "${HOME}/ubuntu-cloud.img" "${GUEST_DISK}"
    
    # Increase the virtual disk capacity to 20 GiB
    sudo qemu-img resize "${GUEST_DISK}" "${GUEST_DISK_SIZE}G" >&2

    # >Create initial guest config
    cat > "${HOME}/user-data" << EOF
#cloud-config
# name: ubuntu:                       Creates the ubuntu user.
# groups: [sudo]:                     Adds the user to the sudo group.
# sudo: ALL=(ALL) NOPASSWD:ALL:       Allows sudo without a password.
# shell: /bin/bash:                   Sets Bash as the user's shell.
# ssh_authorized_keys:                Adds your public SSH key so you can connect.
# ssh_pwauth: false:                  Disables SSH password authentication.
# packages:                           Installs Sysbench and the SSH server.
users:
  - name: ubuntu
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "${GUEST_KEY}.pub")
ssh_pwauth: false
packages:
  - sysbench
  - openssh-server
EOF

cat > "${HOME}/meta-data" << EOF
instance-id: ${GUEST_NAME}-001
local-hostname: ${GUEST_NAME}
EOF
    
    # Package these configuration files into an ISO image that Ubuntu reads during initialization
    cloud-localds "${HOME}/seed.iso" "${HOME}/user-data" "${HOME}/meta-data"
    
    # Copy that ISO into libvirt's image directory
    sudo cp "${HOME}/seed.iso" "${GUEST_SEED}"

    # Create and boot the guest
    echo "[*] Create Ubuntu KVM guest" >&2

    if sudo virsh dominfo "${GUEST_NAME}" >/dev/null 2>&1; then
        sudo virsh destroy "${GUEST_NAME}" 2>/dev/null || true
        sudo virsh undefine "${GUEST_NAME}"
    fi

    sudo virt-install \
        --connect qemu:///system \
        --name "${GUEST_NAME}" \
        --memory "${GUEST_RAM}" \
        --vcpus "${GUEST_VCPUS}" \
        --import \
        --os-variant ubuntu22.04 \
        --disk "path=${GUEST_DISK},format=qcow2,bus=virtio,cache=none" \
        --disk "path=${GUEST_SEED},device=cdrom" \
        --network network=default,model=virtio \
        --graphics none \
        --noautoconsole >&2

else
    echo "[*] KVM guest already exists" >&2
    
    # Start the existing VM if it is not already running
    if [[ "$(sudo virsh domstate "${GUEST_NAME}")" != "running" ]]; then
        sudo virsh start "${GUEST_NAME}" >&2
    fi
fi


# ==============================================================================
# Wait for guest network
# ==============================================================================

echo "[*] Waiting for guest IP address..." >&2

GUEST_IP=""

for attempt in $(seq 1 60); do

    GUEST_IP=$(sudo virsh net-dhcp-leases default |
        awk -v guest="${GUEST_NAME}" '
            $0 ~ guest {
                split($5, address, "/")
                print address[1]
                exit
            }
        ')

    if [[ -n "${GUEST_IP}" ]]; then
        break
    fi

    sleep 5
done

if [[ -z "${GUEST_IP}" ]]; then
    echo "Could not determine guest IP address." >&2
    exit 1
fi

echo "[*] Guest IP: ${GUEST_IP}" >&2


# ==============================================================================
# Wait for SSH and cloud-init
# ==============================================================================

echo "[*] Waiting for guest SSH..." >&2

SSH_READY=false

for attempt in $(seq 1 60); do
    if ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes -i "${GUEST_KEY}" "ubuntu@${GUEST_IP}" "true" >/dev/null 2>&1; then

        SSH_READY=true
        break
    fi

    sleep 5
done

if [[ "${SSH_READY}" != true ]]; then
    echo "Could not connect to KVM guest via SSH." >&2
    exit 1
fi

echo "[*] Guest SSH connection established." >&2

# Check cloud-init separately
ssh -n -i "${GUEST_KEY}" "ubuntu@${GUEST_IP}" "cloud-init status --wait" >&2

# Check Sysbench separately
ssh -n -i "${GUEST_KEY}" "ubuntu@${GUEST_IP}" "command -v sysbench" >&2


# ==============================================================================
# Run benchmark inside KVM guest
# ==============================================================================

echo "[*] Running KVM benchmarks..." >&2

mkdir -p "${HOME}/benchmark-results"

ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -i "${GUEST_KEY}" "ubuntu@${GUEST_IP}" "bash -s" < "${HOME}/benchmarks.sh" > "${HOME}/benchmark-results/kvm.csv"

# Print CSV to stdout
cat "${HOME}/benchmark-results/kvm.csv"

REMOTE_SCRIPT

# chmod +x start-kvm-benchmark.sh
# ./start-kvm-benchmark.sh > results/kvm.csv