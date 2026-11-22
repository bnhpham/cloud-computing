#!/usr/bin/env bash
#
# Bash script for configuring OpenStack
#
# Prerequisites:
# 1. The Python environment with the OpenStack CLI is active
# 2. "source admin-openrc.sh" was executed (set environment variables that are used for authentication)
#    (For verification, use the admin login credentials to login via the OpenStack dashboard. 
#    You can check that all necessary resources are created in OpenStack.)
# 3. "import-images.sh" and "create-ext-network.sh" were executed
#    (They create the image "ubuntu-16.04", the flavor "m1.medium", the networks "admin-net" / "external" 
#    and the router.)
#
# Usage: ./prepare-openstack.sh <public-ip-of-controller-vm>

set -euo pipefail # stop the script if an error or undefined variable occurs


# ==============================================================================
# CONFIGURATION
# ==============================================================================

CONTROLLER_IP="${1:?Usage: $0 <public-ip-of-controller-vm>}"

# SSH access to the GCP controller VM (key from the first task, copy in WSL home)
GCP_USER="cc_student"
GCP_SSH_KEY="${HOME}/.ssh/cc_ssh"
SSH_OPTS=(-i "${GCP_SSH_KEY}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# OpenStack resources
SECURITY_GROUP="open-all"
KEYPAIR_NAME="openstack-key"
KEYPAIR_FILE="./openstack_key"      # Private key. The public key is ${KEYPAIR_FILE}.pub
VM_NAME="openstack-vm"
IMAGE_NAME="ubuntu-16.04"           # Created by import-images.sh
FLAVOR_NAME="m1.medium"             # Created by import-images.sh
NETWORK_NAME="admin-net"            # Created by create-ext-network.sh
EXTERNAL_NETWORK="external"         # Created by create-ext-network.sh

# Abort if the OpenStack credentials were not sourced (admin-openrc.sh)
if [[ -z "${OS_USERNAME:-}" ]]; then
    echo "No Keystone credentials specified. Run: source admin-openrc.sh"
    exit 1
fi


# ==============================================================================
# Create the security group "open-all"
# (Security groups are the firewall rules of OpenStack VMs)
# ==============================================================================

echo "[*] Create security group ${SECURITY_GROUP}"

if openstack security group show "${SECURITY_GROUP}" >/dev/null 2>&1; then
    echo "Security group ${SECURITY_GROUP} already exists --> Skip creation."
    SG_CREATED=false
else
    openstack security group create "${SECURITY_GROUP}" --description "Allow all TCP, UDP and ICMP traffic"
    SG_CREATED=true
fi


# ==============================================================================
# Add rules to "open-all": Allow all TCP, UDP and ICMP ingress and egress traffic
# (Acceptable here because the whole cloud sits behind the GCP firewall)
# ==============================================================================

echo "[*] Add rules to ${SECURITY_GROUP}"

if [[ "${SG_CREATED}" == true ]]; then
    for DIRECTION in ingress egress; do
        # TCP & UDP (opens all TCP/ UDP destination ports to/from 0.0.0.0/0 (the entire IPv4 internet))
        for PROTOCOL in tcp udp; do
            openstack security group rule create \
                --protocol "${PROTOCOL}" \
                --dst-port 1:65535 \
                --remote-ip 0.0.0.0/0 \
                "--${DIRECTION}" \
                "${SECURITY_GROUP}" >/dev/null
        done

        # ICMP
        openstack security group rule create \
            --protocol icmp \
            --remote-ip 0.0.0.0/0 \
            "--${DIRECTION}" \
            "${SECURITY_GROUP}" >/dev/null
    done
fi

openstack security group rule list "${SECURITY_GROUP}"


# ==============================================================================
# Create another key pair, import it to OpenStack and copy the private key to 
# the controller VM
# ==============================================================================

echo "[*] Create key pair ${KEYPAIR_NAME}"

# Generate the SSH key pair (without passphrase) if it does not exist yet
if [[ -f "${KEYPAIR_FILE}" ]]; then
    echo "Key file ${KEYPAIR_FILE} already exists --> Skip key generation."
else
    ssh-keygen -t ed25519 -f "${KEYPAIR_FILE}" -C "openstack" -N "" >/dev/null
fi

# Import the public key into OpenStack
if openstack keypair show "${KEYPAIR_NAME}" >/dev/null 2>&1; then
    echo "Key pair ${KEYPAIR_NAME} already exists in OpenStack --> Skip import."
else
    openstack keypair create --public-key "${KEYPAIR_FILE}.pub" "${KEYPAIR_NAME}"
fi

# Copy the private key to the controller VM (~/.ssh) and restrict its permissions to 400
# (SSH refuses private keys that are readable by others)
# (chmod 400 -> sets file permissions so that only the file owner can read the file)
ssh "${SSH_OPTS[@]}" "${GCP_USER}@${CONTROLLER_IP}" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/${KEYPAIR_NAME}"
scp "${SSH_OPTS[@]}" "${KEYPAIR_FILE}" "${GCP_USER}@${CONTROLLER_IP}:.ssh/${KEYPAIR_NAME}"
ssh "${SSH_OPTS[@]}" "${GCP_USER}@${CONTROLLER_IP}" "chmod 400 ~/.ssh/${KEYPAIR_NAME} && ls -l ~/.ssh/${KEYPAIR_NAME}"


# ==============================================================================
# Start a VM instance on OpenStack ("OpenStack VM")
# ==============================================================================

echo "[*] Create OpenStack VM ${VM_NAME}"

if openstack server show "${VM_NAME}" >/dev/null 2>&1; then
    echo "VM ${VM_NAME} already exists --> Skip creation."
else
    # --wait blocks until the VM left the BUILD state
    openstack server create "${VM_NAME}" \
        --image "${IMAGE_NAME}" \
        --flavor "${FLAVOR_NAME}" \
        --network "${NETWORK_NAME}" \
        --security-group "${SECURITY_GROUP}" \
        --key-name "${KEYPAIR_NAME}" \
        --wait
fi

# Verify that the VM is running (OpenStack should report the status "ACTIVE")
VM_STATUS=$(openstack server show "${VM_NAME}" -f value -c status)
echo "Status of ${VM_NAME}: ${VM_STATUS}"

if [[ "${VM_STATUS}" != "ACTIVE" ]]; then
    echo "VM is not running. Terminate script..."
    exit 1
fi


# ==============================================================================
# Assign a floating IP to the OpenStack VM
# (Allocated from the external network created by create-ext-network.sh)
# ==============================================================================

echo "[*] Assign floating IP to ${VM_NAME}"

# Reuse an already assigned floating IP. Otherwise, allocate a new one
FLOATING_IP=$(openstack floating ip list --port "$(openstack port list --server "${VM_NAME}" -f value -c ID | head -n1)" \
    -f value -c "Floating IP Address" | head -n1)

if [[ -n "${FLOATING_IP}" ]]; then
    echo "Floating IP ${FLOATING_IP} already assigned --> Skip."
else
    FLOATING_IP=$(openstack floating ip create "${EXTERNAL_NETWORK}" -f value -c floating_ip_address)
    openstack server add floating ip "${VM_NAME}" "${FLOATING_IP}"
    echo "Floating IP ${FLOATING_IP} assigned to ${VM_NAME}."
fi

# The floating IP is in the Networks column (10.122.0.x)
echo ""
openstack server list
echo ""
echo "Done. Floating IP of ${VM_NAME}: ${FLOATING_IP}"


# From kolla_ansible_arc, run:
# chmod +x ../prepare-openstack.sh
# ../prepare-openstack.sh <public-ip-of-controller-vm>