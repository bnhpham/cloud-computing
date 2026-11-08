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
# Prepare SSH key
# ==============================================================================

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

cp "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}" "${SSH_KEY}"
cp "${SSH_KEYS_DICT}/${SSH_KEYS_NAME}.pub" "${SSH_KEY}.pub"

chmod 600 "${SSH_KEY}"
chmod 644 "${SSH_KEY}.pub"


# ==============================================================================
# Copy Dockerfile and benchmark script to VM's home directory "~/"
# ==============================================================================

echo "[*] Transfer benchmark files to VM" >&2

gcloud compute scp Dockerfile benchmarks.sh "${USERNAME}@${VM_NAME}:~/" --zone="${ZONE}" --ssh-key-file="${SSH_KEY}"


# ==============================================================================
# Install Docker, build image, and run benchmarks on VM
# ==============================================================================

echo "[*] Install Docker and run Docker benchmarks" >&2

gcloud compute ssh "${USERNAME}@${VM_NAME}" \
    --zone="${ZONE}" \
    --ssh-key-file="${SSH_KEY}" \
    --command="bash -s" <<'REMOTE_SCRIPT'

set -euo pipefail

# ==============================================================================
# Install Docker if necessary
# ==============================================================================

if ! command -v docker >/dev/null 2>&1; then

    echo "[*] Installing Docker..." >&2

    # 1. Remove conflicting packages if any exists
    packages=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1)
    if [[ -n "${packages}" ]]; then
        sudo apt-get remove -y ${packages} >&2
    fi

    # 2. Set up the Docker apt repository

    # Add Docker's official GPG key
    sudo apt-get update >&2
    sudo apt-get install -y ca-certificates curl >&2
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources
    sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # 3. Install Docker Engine
    sudo apt-get update >&2
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >&2
    
    # 4. Start Docker and enable automatic startup
    sudo systemctl enable --now docker

else
    echo "[*] Docker is already installed." >&2
fi

# Check if the Docker daemon is usable
if ! sudo docker info >/dev/null 2>&1; then
    echo "Docker is installed but not usable. --> Terminate script..." >&2
    exit 1
fi


# ==============================================================================
# Build Docker image
# ==============================================================================

echo "[*] Building Docker image..." >&2

sudo docker build -t cc-benchmark "$HOME" >&2


# ==============================================================================
# Run benchmarks
# ==============================================================================

echo "[*] Running Docker benchmarks..." >&2

mkdir -p "$HOME/benchmark-results"

sudo docker run --rm \
    --mount "type=bind,src=$HOME/benchmark-results,dst=/results" \
    cc-benchmark \
    > "$HOME/benchmark-results/docker.csv"

# Print exactly one CSV line to stdout
cat "$HOME/benchmark-results/docker.csv"

REMOTE_SCRIPT

echo "[*] Docker benchmarks completed successfully." >&2


# ./start-docker-benchmark.sh > docker.csv