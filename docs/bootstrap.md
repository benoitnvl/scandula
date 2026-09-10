# Bootstrap

Everything here happens **once**, by hand, before the first `make apply`. It covers
the things Terraform can't manage for itself: its own state account, and resource
provider registration.

First run: 2026-09-10. The notes marked ⚠ are what that run actually hit.

## 0. Tools, subscription, rights

```sh
brew install azure-cli
brew install hashicorp/tap/terraform   # HashiCorp's tap; can lag CI's pinned version by a day
az login --use-device-code
az account set --subscription <connectivity subscription>
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

scandula lives in the **connectivity subscription**: the one that holds the hubs and
the network manager.

Rights:

- **Contributor** on that subscription is enough for Terraform while the AVNM scope is
  that same subscription (the default). Widening `network_manager_scope` to other
  subscriptions or a management group needs rights there too, so check the AVNM scope
  docs before you do.
- ⚠ **The bootstrap itself needs more than Contributor** for one step: granting the
  state data role (step 2) needs **Owner** or **User Access Administrator**. Contributor
  can't write role assignments.
- ⚠ If `az login` ends with "No subscriptions found", the account has no role on any
  subscription in that tenant yet. Grant one, then log in again. A failed login saves
  no session, so a grant made afterwards isn't picked up until you do.
- ⚠ **New grants can take a long time to take effect.** On the first run, both were
  granted at management-group scope. Contributor worked within minutes. User Access
  Administrator took **about 39 minutes** before `roleAssignments/write` stopped failing.
  Until then, calls fail with `AuthorizationFailed … If access was recently granted,
  please refresh your credentials`, even though `az role assignment list` and the
  permissions API already show the role. Wait and retry the call. Signing in again
  wasn't what fixed it.

## 1. Register resource providers

azurerm 5.x registers **no** resource providers by default. Terraform needs
`Microsoft.Network`; the bootstrap's state account needs `Microsoft.Storage`.

```sh
az provider register --namespace Microsoft.Network --wait
az provider register --namespace Microsoft.Storage --wait
```

⚠ An unregistered `Microsoft.Storage` doesn't say so. `az storage account check-name`
fails with `SubscriptionNotFound` for a subscription that plainly exists.

For a management-group scope, register `Microsoft.Network` at the management group as
well (`az provider register --namespace Microsoft.Network --management-group-id <mg>`).

## 2. The state account

Entra ID auth only: no shared keys, no public blobs. Versioning and soft delete are on,
because this state is the only record of which IPAM pool is which.

```sh
RG=rg-scandula-tfstate
SA=stscandulatfstate          # globally unique, 3–24 lowercase letters/digits
LOC=uksouth
TAGS=(managed-by=bootstrap repo=benoitnvl/scandula purpose=tfstate)

az storage account check-name --name $SA
az group create -n $RG -l $LOC --tags "${TAGS[@]}"
az storage account create -n $SA -g $RG -l $LOC \
  --sku Standard_ZRS --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --tags "${TAGS[@]}"
az storage account blob-service-properties update -n $SA -g $RG \
  --enable-versioning true \
  --enable-delete-retention true --delete-retention-days 30

# Control plane (ARM), so it needs only Contributor, not the data role below.
az storage container-rm create --storage-account $SA -g $RG -n tfstate --public-access off

# Needs Owner / User Access Administrator — see step 0.
az role assignment create --role "Storage Blob Data Contributor" \
  --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" \
  --assignee-principal-type User \
  --scope "$(az storage account show -n $SA -g $RG --query id -o tsv)"
```

Terraform reads and writes state through that data role, because shared keys are off.
The role takes a few minutes to apply after it's granted.

## 3. Local config

```sh
cp infra/backend.hcl.example       infra/backend.hcl        # set storage_account_name
cp infra/terraform.tfvars.example  infra/terraform.tfvars   # read docs/design.md first
```

Both files are gitignored.

## 4. First apply

```sh
make lock        # provider checksums for linux_amd64 (CI) + darwin_arm64; no Azure access needed
make init        # needs the data role from step 2 to be in effect
make plan
make apply
```

`infra/.terraform.lock.hcl` is committed. Regenerate it with `make lock` when the
provider version changes, and **only with terraform**: a tofu-made lock file records
`registry.opentofu.org`.

## Later: plan in CI

CI currently never authenticates. When it's worth it, add a user-assigned managed
identity or app registration with a **federated credential** for this repo's PRs (OIDC,
no secret), grant it Reader on the subscription plus Storage Blob Data Reader on the
state container, and add a `terraform plan` job. Apply stays on a workstation.
