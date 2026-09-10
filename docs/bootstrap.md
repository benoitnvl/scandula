# Bootstrap

Everything here happens **once**, by hand, before the first `make apply`. It covers
the things Terraform can't manage for itself: its own state account, and resource
provider registration.

## 0. Pick the subscription

scandula lives in the **connectivity subscription**: the one that holds the hubs and
the network manager.

```sh
az login
az account set --subscription <connectivity subscription>
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

Rights: **Contributor** on that subscription is enough while the AVNM scope is that
same subscription (the default). Widening `network_manager_scope` to other
subscriptions or a management group needs rights there too, so check the AVNM scope
docs before you do.

## 1. Register Microsoft.Network

azurerm 5.x registers **no** resource providers by default.

```sh
az provider register --namespace Microsoft.Network --wait
```

For a management-group scope, register it at the management group as well
(`az provider register --namespace Microsoft.Network --management-group-id <mg>`).

## 2. The state account

Entra ID auth only: no shared keys, no public blobs. Versioning and soft delete are on,
because this state is the only record of which IPAM pool is which.

```sh
RG=rg-scandula-tfstate
SA=stscandulatfstate          # globally unique, 3–24 lowercase letters/digits
LOC=uksouth

az group create -n $RG -l $LOC
az storage account create -n $SA -g $RG -l $LOC \
  --sku Standard_ZRS --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false
az storage account blob-service-properties update -n $SA -g $RG \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30
az role assignment create --role "Storage Blob Data Contributor" \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "$(az storage account show -n $SA -g $RG --query id -o tsv)"
az storage container create -n tfstate --account-name $SA --auth-mode login
```

Role assignments can take a minute or two to apply, so if `container create` returns
403, wait and retry.

## 3. Local config

```sh
cp infra/backend.hcl.example       infra/backend.hcl        # set storage_account_name
cp infra/terraform.tfvars.example  infra/terraform.tfvars   # read docs/design.md first
```

Both files are gitignored.

## 4. First apply

```sh
make init
make lock        # .terraform.lock.hcl for linux_amd64 (CI) + darwin_arm64
make plan
make apply
```

Commit `infra/.terraform.lock.hcl` in a PR afterwards. CI can then pin the same
provider build you applied with.

## Later: plan in CI

CI currently never authenticates. When it's worth it, add a user-assigned managed
identity or app registration with a **federated credential** for this repo's PRs (OIDC,
no secret), grant it Reader on the subscription plus Storage Blob Data Reader on the
state container, and add a `terraform plan` job. Apply stays on a workstation.
