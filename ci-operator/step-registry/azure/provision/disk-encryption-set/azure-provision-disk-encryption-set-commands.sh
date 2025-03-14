#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function run_command_with_retries()
{
    local try=0 cmd="$1" retries="${2:-}" ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}'"

    eval "${cmd}" || ret=$?
    while [ X"${ret}" != X"0" ] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success, waiting 60 sec....."
        sleep 60
        try=$((try + 1))
        ret=0
        eval "${cmd}" || ret=$?
    done
    if [ ${try} -eq ${max} ]; then
        echo "Never succeed or Timeout"
        return 1
    fi
    echo "Succeed"
    return 0
}

function create_disk_encryption_set() {
    local rg=$1 kv_name=$2 kv_key_name=$3 des_name=$4 kv_id kv_key_url des_id kv_output kv_key_output des_output
    
    echo "Creating keyvault ${kv_name} in ${rg}"
    kv_output=$(mktemp)
    run_command "az keyvault create -n ${kv_name} -g ${rg} --enable-purge-protection true --retention-days 7 | tee '${kv_output}'" || return 1
    kv_key_output=$(mktemp)
    run_command "az keyvault key create --vault-name ${kv_name} -n ${kv_key_name} --protection software | tee '${kv_key_output}'" || return 1
    #sleep for a while to wait for azure api return correct id
    #sleep 60
    #kv_id=$(az keyvault show --name ${kv_name} --query "[id]" -o tsv) &&
    #kv_key_url=$(az keyvault key show --vault-name $kv_name --name $kv_key_name --query "[key.kid]" -o tsv) || return 1
    kv_id=$(jq -r '.id' "${kv_output}") &&
    kv_key_url=$(jq -r '.key.kid' "${kv_key_output}") || return 1
    
    echo "Creating disk encryption set for ${kv_name}"
    des_output=$(mktemp)
    run_command "az disk-encryption-set create -n ${des_name} -g ${rg} --source-vault ${kv_id} --key-url ${kv_key_url} | tee '${des_output}'" || return 1
    #des_id=$(az disk-encryption-set show -n ${des_name} -g ${rg} --query "[identity.principalId]" -o tsv) || return 1
    des_id=$(jq -r '.identity.principalId' "${des_output}") || return 1
    
    echo "Granting the DiskEncryptionSet resource access to the key vault"
    run_command "az keyvault set-policy -n ${kv_name} -g ${rg} --object-id ${des_id} --key-permissions wrapkey unwrapkey get" || return 1
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}


rg_file="${SHARED_DIR}/resourcegroup"
if [ -f "${rg_file}" ]; then
    RESOURCE_GROUP=$(cat "${rg_file}")
else
    echo "Did not found an provisoned empty resource group"
    exit 1
fi

run_command "az group show --name $RESOURCE_GROUP"; ret=$?
if [ X"$ret" != X"0" ]; then
    echo "The $RESOURCE_GROUP resrouce group does not exit"
    exit 1
fi

# create disk encryption set
# The Key Vault name must be randomized because deleted Key Vaults remain in a soft-deleted state for 7 days.
# A vault's name must be between 3-24 alphanumeric characters
# The vault name must begin with a letter, end with a letter or digit, and not contain consecutive hyphens.
azure_des_json="{}"
des_id=""
kv_prefix="ci-${NAMESPACE: -6}-${UNIQUE_HASH}"
if [[ "${ENABLE_DES_DEFAULT_MACHINE}" == "true" ]]; then
    echo "Creating keyvault and disk encryption set in ${RESOURCE_GROUP} for defaultMachinePlatform"
    keyvault_default="${kv_prefix}-kv-d"
    keyvault_key_default="${kv_prefix}-kvkey-d"
    des_default="${kv_prefix}-des-d"
    create_disk_encryption_set "${RESOURCE_GROUP}" "${keyvault_default}" "${keyvault_key_default}" "${des_default}"
    
    des_default_id=$(az disk-encryption-set show -n "${des_default}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    des_id="$des_default_id"

    #save default des information to ${SHARED_DIR} for reference
    azure_des_json=$(echo "${azure_des_json}" | jq -c -S ". +={\"default\":\"${des_default}\"}")
fi

if [[ "${ENABLE_DES_CONTROL_PLANE}" == "true" ]]; then
    echo "Creating keyvault and disk encryption set in ${RESOURCE_GROUP} for ControlPlane"
    keyvault_master="${kv_prefix}-kv-m"
    keyvault_key_master="${kv_prefix}-kvkey-m"
    des_master="${kv_prefix}-des-m"
    create_disk_encryption_set "${RESOURCE_GROUP}" "${keyvault_master}" "${keyvault_key_master}" "${des_master}"

    des_master_id=$(az disk-encryption-set show -n "${des_master}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    des_id="$des_master_id"

    #save control plane des information to ${SHARED_DIR} for reference
    azure_des_json=$(echo "${azure_des_json}" | jq -c -S ". +={\"master\":\"${des_master}\"}")
fi

if [[ "${ENABLE_DES_COMPUTE}" == "true" ]]; then
    echo "Creating keyvault and disk encryption set in ${RESOURCE_GROUP} for compute"
    keyvault_worker="${kv_prefix}-kv-w"
    keyvault_key_worker="${kv_prefix}-kvkey-w"
    des_worker="${kv_prefix}-des-w"
    create_disk_encryption_set "${RESOURCE_GROUP}" "${keyvault_worker}" "${keyvault_key_worker}" "${des_worker}"

    des_worker_id=$(az disk-encryption-set show -n "${des_worker}" -g "${RESOURCE_GROUP}" --query "[id]" -o tsv)
    des_id="$des_worker_id"

    #save compute des information to ${SHARED_DIR} for reference
    azure_des_json=$(echo "${azure_des_json}" | jq -c -S ". +={\"worker\":\"${des_worker}\"}")
fi

# save disk encryption set information to ${SHARED_DIR} for reference
echo "${azure_des_json}" > "${SHARED_DIR}/azure_des.json"
echo "${des_id}" > "${SHARED_DIR}/azure_des_id"

#for debug
cat "${SHARED_DIR}/azure_des.json"
