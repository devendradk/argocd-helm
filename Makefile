# Argo CD install helpers (Kustomize + Helm inflator). Run from repo root.
# Requires: kubectl 1.26+ with `kubectl kustomize --enable-helm`, and Helm 3 on PATH.

KUBECTL ?= kubectl
NS ?= argocd
# Extra flags for kubectl apply (e.g. --force-conflicts once after client-side apply)
APPLY_FLAGS ?=

KUSTOMIZE := $(KUBECTL) kustomize --enable-helm
APPLY := $(KUBECTL) apply --server-side $(APPLY_FLAGS) -f -

.PHONY: help
help:
	@echo "Targets:"
	@echo "  ns-create          Ensure namespace $(NS) exists (idempotent)"
	@echo "  bootstrap-prod     First install: Argo CD core only (overlays/prod-bootstrap)"
	@echo "  bootstrap-test     First install: Argo CD core only (overlays/test-bootstrap)"
	@echo "  wait-rollouts      Wait for Argo CD core workloads"
	@echo "  apply-prod         Apply steady-state overlays/prod (includes apps/)"
	@echo "  apply-test         Apply steady-state overlays/test (includes apps/)"
	@echo "  apply-git          One-shot: kubectl apply bootstrap/root-application.yaml"
	@echo "  render-prod / render-test            Print steady-state manifests (no apply)"
	@echo "  render-prod-bootstrap / render-test-bootstrap  Print bootstrap manifests (no apply)"

.PHONY: ns-create
ns-create:
	$(KUBECTL) create namespace $(NS) --dry-run=client -o yaml | $(KUBECTL) apply -f -

.PHONY: bootstrap-prod bootstrap-test
bootstrap-prod: ns-create
	$(KUSTOMIZE) overlays/prod-bootstrap | $(APPLY)

bootstrap-test: ns-create
	$(KUSTOMIZE) overlays/test-bootstrap | $(APPLY)

.PHONY: apply-prod apply-test
apply-prod: ns-create
	$(KUSTOMIZE) overlays/prod | $(APPLY)

apply-test: ns-create
	$(KUSTOMIZE) overlays/test | $(APPLY)

.PHONY: wait-rollouts
wait-rollouts:
	$(KUBECTL) -n $(NS) rollout status deployment/argocd-server
	$(KUBECTL) -n $(NS) rollout status deployment/argocd-repo-server
	$(KUBECTL) -n $(NS) rollout status statefulset/argocd-application-controller

.PHONY: apply-git
apply-git:
	$(KUBECTL) apply -f bootstrap/root-application.yaml

.PHONY: render-prod render-prod-bootstrap render-test render-test-bootstrap
render-prod:
	$(KUSTOMIZE) overlays/prod

render-prod-bootstrap:
	$(KUSTOMIZE) overlays/prod-bootstrap

render-test:
	$(KUSTOMIZE) overlays/test

render-test-bootstrap:
	$(KUSTOMIZE) overlays/test-bootstrap
