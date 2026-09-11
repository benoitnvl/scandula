SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

# HashiCorp Terraform. The HCL is plain enough that `make TF=tofu fmt|validate|test`
# also works, but never point both tools at the same state or lock file.
TF ?= terraform
TF_DIR := infra

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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

.PHONY: mutants
mutants: ## Disable each validation in turn; some test must go red (run after touching variables.tf)
	TF=$(TF) python3 scripts/validation-mutants.py $(TF_DIR)

.PHONY: diagram
diagram: ## Re-export docs/diagrams/architecture.svg from its .drawio source (needs the draw.io desktop app)
	drawio --export --format svg --embed-diagram --border 20 --output docs/diagrams/architecture.svg docs/diagrams/architecture.drawio

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
	$(TF) -chdir=$(TF_DIR) providers lock -platform=linux_amd64 -platform=darwin_arm64

## --- Azure IPAM (azure-ipam/README.md). Not Terraform: ARM owns these resources. ---

.PHONY: ipam-fetch
ipam-fetch: ## Azure IPAM: clone the pinned release; verify its commit and zip checksum
	./azure-ipam/ipam.sh fetch

.PHONY: ipam-check
ipam-check: ## Azure IPAM: check pwsh, Az/Graph modules, bicep and the Azure PowerShell context
	./azure-ipam/ipam.sh check

.PHONY: ipam-apps
ipam-apps: ## Azure IPAM part 1 (tenant admin): app registrations -> azure-ipam/.work/main.parameters.json
	./azure-ipam/ipam.sh apps

.PHONY: ipam-infra
ipam-infra: ## Azure IPAM part 2: deploy (about USD 170-250/month; needs IPAM_CONFIRM_COST=yes)
	./azure-ipam/ipam.sh infra

.PHONY: ipam-update
ipam-update: ## Azure IPAM: zip-deploy the pinned release (IPAM_APP_NAME, IPAM_RESOURCE_GROUP)
	./azure-ipam/ipam.sh update

.PHONY: ipam-test
ipam-test: ## Test the Azure IPAM wrapper against stubs (no Azure, no network)
	bash scripts/test-azure-ipam.sh
