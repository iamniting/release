#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd

# install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl

SECRET_DIR="/tmp/vault/powervs-rhr-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/PRIVATE_KEY_FILE"

# https://docs.ci.openshift.org/docs/architecture/step-registry/#sharing-data-between-steps
KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

SSH_KEY_PATH="/tmp/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"
SSH_CMD="ocp.sh acquire"

# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

# acquire a ocp cluster
ssh $SSH_ARGS root@cluster.pool.synergyonpower.com "$SSH_CMD" > $KUBECONFIG_FILE

KUBECONFIG="$KUBECONFIG_FILE" ./kubectl get nodes
