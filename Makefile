SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# HashiCorp Terraform. The HCL is plain enough that `make TF=tofu fmt|validate|test`
# also works, but never point both tools at the same state or lock file.
TF ?= terraform
TF_DIR := infra

# examples/spoke is a copy-me root, never applied from here — but it is validated,
# tested and mutated like the rest, because an example that has rotted is worse
# than no example.
SPOKE := examples/spoke

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: check
check: ## Confirm Azure auth env + backend config are in place
	@if [[ -z "$${ARM_SUBSCRIPTION_ID:-}" ]]; then \
	  echo "error: ARM_SUBSCRIPTION_ID is not set — see docs/bootstrap.md" >&2; exit 1; \
	fi
	@if [[ ! -f $(TF_DIR)/backend.hcl ]]; then \
	  echo "error: $(TF_DIR)/backend.hcl missing — copy backend.hcl.example (docs/bootstrap.md)" >&2; exit 1; \
	fi
	@echo "auth env + backend config look set"

.PHONY: init
init: check ## terraform init against the Azure Storage backend
	$(TF) -chdir=$(TF_DIR) init -backend-config=backend.hcl

.PHONY: init-local
init-local: ## terraform init with no backend (fmt/validate/test only — what CI does)
	$(TF) -chdir=$(TF_DIR) init -backend=false

.PHONY: fmt
fmt: ## terraform fmt -recursive
	$(TF) fmt -recursive

.PHONY: validate
validate: ## terraform validate
	$(TF) -chdir=$(TF_DIR) validate

.PHONY: test
test: ## terraform test — plan-only against a mocked azurerm, no Azure creds needed
	$(TF) -chdir=$(TF_DIR) test

.PHONY: spoke-test
spoke-test: ## terraform validate + test for examples/spoke (mocked azurerm, no creds)
	$(TF) -chdir=$(SPOKE) init -backend=false -input=false >/dev/null
	$(TF) -chdir=$(SPOKE) validate
	$(TF) -chdir=$(SPOKE) test

.PHONY: mutants
mutants: ## Disable each validation in turn, in every root; some test must go red (after init-local, ipam-test, netbox-test, spoke-test)
	@for d in $(TF_DIR) $(IPAM_ENTRA) $(IPAM_PLATFORM) $(NETBOX_PLATFORM) $(NETBOX_RECORDS) $(SPOKE); do \
	  echo "== $$d"; \
	  TF=$(TF) python3 scripts/validation-mutants.py $$d || exit 1; \
	done

.PHONY: diagram
diagram: ## Re-export every docs/diagrams/*.svg from its .drawio source (needs the draw.io desktop app)
	@for d in docs/diagrams/*.drawio; do \
	  drawio --export --format svg --embed-diagram --border 20 --output "$${d%.drawio}.svg" "$$d" || exit 1; \
	done

.PHONY: plan
plan: check ## terraform plan -out=tfplan
	$(TF) -chdir=$(TF_DIR) plan -out=tfplan

.PHONY: apply
apply: check ## Apply the saved plan from `make plan` (and only that plan)
	$(TF) -chdir=$(TF_DIR) apply tfplan

.PHONY: output
output: ## terraform output
	$(TF) -chdir=$(TF_DIR) output

.PHONY: lock
lock: ## Regenerate .terraform.lock.hcl for CI (linux_amd64) and Macs (darwin_arm64)
	@# infra and the spoke example share the same azurerm constraint, so a bump is one job.
	@for d in $(TF_DIR) $(SPOKE); do \
	  $(TF) -chdir=$$d providers lock -platform=linux_amd64 -platform=darwin_arm64 || exit 1; \
	done

## --- NetBox (netbox/README.md): the address authority ---
## netbox/platform runs NetBox on Azure (off until netbox_enabled = true; it costs
## money). netbox/records is the address plan as data, through the NetBox API.

NETBOX_PLATFORM := netbox/platform
NETBOX_RECORDS  := netbox/records

.PHONY: netbox-init
netbox-init: ## NetBox platform: terraform init against netbox/platform/backend.hcl
	@[[ -f $(NETBOX_PLATFORM)/backend.hcl ]] || { echo "error: $(NETBOX_PLATFORM)/backend.hcl missing: copy backend.hcl.example (netbox/README.md)" >&2; exit 1; }
	$(TF) -chdir=$(NETBOX_PLATFORM) init -backend-config=backend.hcl

.PHONY: netbox-plan
netbox-plan: ## NetBox platform: plan -out=tfplan
	$(TF) -chdir=$(NETBOX_PLATFORM) plan -input=false -out=tfplan

.PHONY: netbox-apply
netbox-apply: ## NetBox platform: apply the saved plan from netbox-plan (and only that plan)
	$(TF) -chdir=$(NETBOX_PLATFORM) apply tfplan

.PHONY: netbox-records-init
netbox-records-init: ## NetBox records: terraform init against netbox/records/backend.hcl
	@[[ -f $(NETBOX_RECORDS)/backend.hcl ]] || { echo "error: $(NETBOX_RECORDS)/backend.hcl missing: copy backend.hcl.example (netbox/README.md)" >&2; exit 1; }
	$(TF) -chdir=$(NETBOX_RECORDS) init -backend-config=backend.hcl

.PHONY: netbox-records-plan
netbox-records-plan: ## NetBox records: plan -out=tfplan (needs NETBOX_SERVER_URL + NETBOX_API_TOKEN)
	@[[ -n "$${NETBOX_SERVER_URL:-}" && -n "$${NETBOX_API_TOKEN:-}" ]] || { echo "error: export NETBOX_SERVER_URL and NETBOX_API_TOKEN first (netbox/README.md)" >&2; exit 1; }
	$(TF) -chdir=$(NETBOX_RECORDS) plan -input=false -out=tfplan

.PHONY: netbox-records-apply
netbox-records-apply: ## NetBox records: apply the saved plan from netbox-records-plan
	$(TF) -chdir=$(NETBOX_RECORDS) apply tfplan

.PHONY: netbox-test
netbox-test: ## NetBox: validate + test both roots (mocked providers, no Azure, no NetBox)
	@# The netbox provider marks server_url/api_token required, so `validate` wants them
	@# even though nothing connects. These are deliberately not real.
	@export NETBOX_SERVER_URL="$${NETBOX_SERVER_URL:-https://netbox.invalid}"; \
	export NETBOX_API_TOKEN="$${NETBOX_API_TOKEN:-not-a-real-token}"; \
	for d in $(NETBOX_PLATFORM) $(NETBOX_RECORDS); do \
	  echo "== $$d"; \
	  $(TF) -chdir=$$d init -backend=false -input=false >/dev/null || exit 1; \
	  $(TF) -chdir=$$d validate || exit 1; \
	  $(TF) -chdir=$$d test || exit 1; \
	done

.PHONY: netbox-lock
netbox-lock: ## NetBox: regenerate both roots' .terraform.lock.hcl (linux_amd64 + darwin_arm64)
	@for d in $(NETBOX_PLATFORM) $(NETBOX_RECORDS); do \
	  $(TF) -chdir=$$d providers lock -platform=linux_amd64 -platform=darwin_arm64 || exit 1; \
	done

## --- Azure IPAM (azure-ipam/README.md): two Terraform roots ---
## ⚠ DORMANT since 2026-09-15 — NetBox is the authority (docs/netbox-plan.md). Nothing
## here was ever applied. Kept as the fallback; don't dispatch its workflow.
## azure-ipam/entra is part 1 (Entra ID); azure-ipam/platform is part 2 (the Azure
## resources; off until ipam_enabled = true). Both are applied ONLY by GitHub Actions
## (.github/workflows/azure-ipam-deploy.yaml): these targets fetch, test, lock and plan.

IPAM_ENTRA    := azure-ipam/entra
IPAM_PLATFORM := azure-ipam/platform
IPAM_RELEASE  := $(IPAM_PLATFORM)/release.json
IPAM_WORK     := $(IPAM_PLATFORM)/.work

.PHONY: ipam-fetch
ipam-fetch: ## Azure IPAM: download the pinned release zip (release.json) and check its SHA-256
	@# Every step fails explicitly: macOS's GNU Make 3.81 ignores .SHELLFLAGS, so there's no set -e.
	@read -r version url sha < <(python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(r["version"], r["zip_url"], r["zip_sha256"])' $(IPAM_RELEASE)) \
	  || { echo "error: can't read $(IPAM_RELEASE)" >&2; exit 1; }; \
	out="$(IPAM_WORK)/ipam-$$version.zip"; mkdir -p "$(IPAM_WORK)" || exit 1; \
	if [[ ! -f "$$out" ]]; then \
	  curl -fsSL --show-error --retry 3 -o "$$out.part" "$$url" || { rm -f "$$out.part"; echo "error: download failed: $$url" >&2; exit 1; }; \
	  mv "$$out.part" "$$out" || exit 1; \
	fi; \
	echo "$$sha  $$out" | shasum -a 256 -c - || { echo "error: $$out isn't the pinned zip. Delete it and re-fetch; if it still differs, the release asset changed upstream: stop and investigate." >&2; exit 1; }

.PHONY: ipam-entra-init
ipam-entra-init: ## Azure IPAM part 1: terraform init against azure-ipam/entra/backend.hcl
	@[[ -f $(IPAM_ENTRA)/backend.hcl ]] || { echo "error: $(IPAM_ENTRA)/backend.hcl missing: copy backend.hcl.example (azure-ipam/README.md)" >&2; exit 1; }
	$(TF) -chdir=$(IPAM_ENTRA) init -backend-config=backend.hcl

.PHONY: ipam-entra-plan
ipam-entra-plan: ## Azure IPAM part 1: plan, read-only (applies run only in GitHub Actions)
	$(TF) -chdir=$(IPAM_ENTRA) plan -input=false

.PHONY: ipam-platform-init
ipam-platform-init: ## Azure IPAM part 2: terraform init against azure-ipam/platform/backend.hcl
	@[[ -f $(IPAM_PLATFORM)/backend.hcl ]] || { echo "error: $(IPAM_PLATFORM)/backend.hcl missing: copy backend.hcl.example (azure-ipam/README.md)" >&2; exit 1; }
	$(TF) -chdir=$(IPAM_PLATFORM) init -backend-config=backend.hcl

.PHONY: ipam-platform-plan
ipam-platform-plan: ## Azure IPAM part 2: plan, read-only (with ipam_enabled, run ipam-fetch first)
	$(TF) -chdir=$(IPAM_PLATFORM) plan -input=false

.PHONY: ipam-test
ipam-test: ## Azure IPAM: validate + test both roots, and the workflow's glue script (no Azure, no zip)
	@# `|| exit 1` on each step: without set -e (Make 3.81), a loop reports only its last command.
	@for d in $(IPAM_ENTRA) $(IPAM_PLATFORM); do \
	  echo "== $$d"; \
	  $(TF) -chdir=$$d init -backend=false -input=false >/dev/null || exit 1; \
	  $(TF) -chdir=$$d validate || exit 1; \
	  $(TF) -chdir=$$d test || exit 1; \
	done
	@echo "== azure-ipam/ci.sh"
	bash scripts/test-azure-ipam-ci.sh

.PHONY: ipam-lock
ipam-lock: ## Azure IPAM: regenerate both roots' .terraform.lock.hcl (linux_amd64 + darwin_arm64)
	@for d in $(IPAM_ENTRA) $(IPAM_PLATFORM); do \
	  $(TF) -chdir=$$d providers lock -platform=linux_amd64 -platform=darwin_arm64 || exit 1; \
	done
