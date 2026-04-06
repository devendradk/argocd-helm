#!/usr/bin/env bash
# One-time (or after manual CM edits): make argocd-repo-server run `kustomize build --enable-helm`
# so Applications that use Kustomize’s helmCharts generator (this repo’s base/) can render.
#
# Run when you see: "must specify --enable-helm" on the argocd-platform Application.
# Safe to run again; restarts repo-server so the new CM is picked up.
set -euo pipefail
NS="${ARGOCD_NAMESPACE:-argocd}"

patch_cm() {
  if kubectl -n "$NS" patch configmap argocd-cm --type=json -p='[
    {"op":"add","path":"/data/kustomize.buildOptions","value":"--enable-helm"}
  ]' 2>/dev/null; then
    return 0
  fi
  kubectl -n "$NS" patch configmap argocd-cm --type=json -p='[
    {"op":"replace","path":"/data/kustomize.buildOptions","value":"--enable-helm"}
  ]'
}

patch_cm
kubectl -n "$NS" rollout restart deployment/argocd-repo-server
kubectl -n "$NS" rollout status deployment/argocd-repo-server --timeout=120s
echo "argocd-cm has kustomize.buildOptions=--enable-helm; argocd-repo-server restarted."
