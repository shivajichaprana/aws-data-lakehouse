# ---------------------------------------------------------------------------
# aws-data-lakehouse — developer & operator entrypoints
#
# Usage:
#   make <target> [ENV=dev|staging|prod] [PROJECT=lakehouse] [COUNT=500]
#
# Run `make help` for the full target list.
# ---------------------------------------------------------------------------

# --------------------------- Configuration --------------------------------
TF_DIR      ?= terraform
PROJECT     ?= lakehouse
ENV         ?= dev
COUNT       ?= 500
PRODUCER    := $(TF_DIR)/ingest/sample-producer.py

# Variables passed to every plan/apply/destroy.
TF_VARS     := -var 'project=$(PROJECT)' -var 'environment=$(ENV)'

# Resolve a single -raw Terraform output (used by seed / run-pipeline).
# Usage: $(call tf_output,firehose_stream_name)
tf_output    = $$(cd $(TF_DIR) && terraform output -raw $(1))

# Treat every target as a command, not a file.
.PHONY: help init fmt validate plan apply destroy lint test seed run-pipeline outputs clean

# --------------------------- Help -----------------------------------------
help: ## Show this help.
	@echo "aws-data-lakehouse — make targets:"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables: ENV=$(ENV)  PROJECT=$(PROJECT)  COUNT=$(COUNT)"

# --------------------------- Terraform lifecycle --------------------------
init: ## terraform init.
	cd $(TF_DIR) && terraform init

fmt: ## Format all Terraform files in place.
	terraform fmt -recursive $(TF_DIR)

validate: ## Backend-free init + validate (no credentials needed).
	cd $(TF_DIR) && terraform init -backend=false -upgrade >/dev/null && terraform validate

plan: ## Show an execution plan for ENV.
	cd $(TF_DIR) && terraform plan $(TF_VARS)

apply: ## Apply the configuration for ENV.
	cd $(TF_DIR) && terraform apply $(TF_VARS)

destroy: ## Destroy the ENV deployment (asks for confirmation).
	cd $(TF_DIR) && terraform destroy $(TF_VARS)

outputs: ## Print all root outputs.
	cd $(TF_DIR) && terraform output

# --------------------------- Quality gates --------------------------------
lint: ## Lint Terraform (tflint, checkov) and Python (flake8 / py_compile).
	@echo ">> terraform fmt check"
	terraform fmt -check -recursive $(TF_DIR)
	@echo ">> tflint"
	@command -v tflint >/dev/null 2>&1 && (cd $(TF_DIR) && tflint --recursive) || echo "tflint not installed, skipping"
	@echo ">> checkov"
	@command -v checkov >/dev/null 2>&1 && checkov -d $(TF_DIR) --quiet --compact || echo "checkov not installed, skipping"
	@echo ">> python lint"
	@command -v flake8 >/dev/null 2>&1 \
		&& flake8 --select=E9,F63,F7,F82 --show-source $(TF_DIR)/ingest/sample-producer.py glue-scripts/ \
		|| (echo "flake8 not installed; falling back to py_compile" \
		    && python -m py_compile $(TF_DIR)/ingest/sample-producer.py glue-scripts/*.py)

test: ## Run the Python test suite (if present).
	@if [ -d tests ]; then \
		python -m pytest -q tests; \
	else \
		echo "no tests/ directory — running py_compile smoke check"; \
		python -m py_compile $(TF_DIR)/ingest/sample-producer.py glue-scripts/*.py; \
	fi

# --------------------------- Operations -----------------------------------
seed: ## Publish COUNT sample events to the ingest Firehose stream.
	python $(PRODUCER) --stream "$(call tf_output,firehose_stream_name)" --count $(COUNT)

run-pipeline: ## Start one execution of the daily orchestration state machine now.
	aws stepfunctions start-execution \
		--state-machine-arn "$(call tf_output,pipeline_state_machine_arn)" \
		--name "manual-$$(date +%Y%m%d-%H%M%S)"

# --------------------------- Housekeeping ---------------------------------
clean: ## Remove local Terraform working files (state is untouched).
	find $(TF_DIR) -type d -name '.terraform' -prune -exec rm -rf {} +
	find $(TF_DIR) -type f -name '.terraform.lock.hcl' -delete
	find . -type d -name '__pycache__' -prune -exec rm -rf {} +
