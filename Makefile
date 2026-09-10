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
