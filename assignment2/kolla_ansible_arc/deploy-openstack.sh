#!/bin/bash

# Install the Ansible Galaxy collections that kolla-ansible needs (openstack.kolla etc.). Requires an active venv.
kolla-ansible install-deps

# Generate all openstack passwords and keys (fills the empty values in ./passwords.yml)
kolla-genpwd -p ./passwords.yml

# Prepare VMs for kolla-ansible
ansible-playbook -i ./multinode ./pre-bootstrap.yml | tee ./pre-bootstrap.log

# Prepare VMs for OpenStack installation
#kolla-ansible bootstrap-servers --passwords ./passwords.yml --configdir "$(readlink -e ./)" --inventory ./multinode | tee ./bootstrap-servers.log
kolla-ansible bootstrap-servers --passwords ./passwords.yml --configdir "$(readlink -e ./)" --inventory ./multinode | tee ./bootstrap-servers.log

# Fix a common bug in /etc/hosts (this is not an idempotent operation! only execute this once)
ansible-playbook -i ./multinode ./fix-hosts-file.yml

# Pull the new images on target hosts (optional operation, but recommended)
kolla-ansible pull --passwords ./passwords.yml --configdir "$(readlink -e ./)" --inventory ./multinode 

# Run prechecks to verify that the VMs are ready for OpenStack deployment
kolla-ansible prechecks --passwords ./passwords.yml --configdir "$(readlink -e ./)" --inventory ./multinode --skip-tags haproxy | tee ./prechecks.log

# Deploy OpenStack
kolla-ansible deploy --passwords ./passwords.yml --configdir "$(readlink -e ./)" --inventory ./multinode | tee ./deploy.log

# create ./admin-rc.sh (you might need to change the ownership of ./admin-rc.sh)
kolla-ansible post-deploy --passwords ./passwords.yml --configdir "$(readlink -e ./)" --inventory ./multinode 

# Destroy OpenStack deployment
# kolla-ansible destroy --passwords ./passwords.yml --configdir "$(readlink -e ./)" --inventory ./multinode --yes-i-really-really-mean-it

