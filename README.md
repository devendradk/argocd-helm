# argocd-helm

Install [Argo CD](https://argo-cd.readthedocs.io/) with the upstream [argo-cd Helm chart](https://artifacthub.io/packages/helm/argo/argo-cd) using **Kustomize’s Helm chart inflator** (`base/` + `overlays/`, like a typical Kustomize-wrapped Helm setup).

Use this to run a **hub** Argo CD that can manage **this cluster and others** (register additional clusters in Settings or via Git). The default in-cluster destination remains available for **self-managed** GitOps (Argo CD managing its own manifests) once you add an `Application` for this install.

## Prerequisites

- A Kubernetes cluster and a kubecontext with permission to install cluster-scoped CRDs and RBAC.
- `kubectl` **1.26+** with built-in Kustomize that supports Helm (`kubectl kustomize --help` should mention `--enable-helm`), **or** standalone [Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) v5+ with the same flag.
- Network access on the machine running the command so Kustomize can download the Helm chart the first time (cached under `base/charts/`; that path is gitignored).

## Configure before install

1. Edit `base/values.yaml` (or add an overlay) and set a real hostname in `global.domain`, and uncomment/set `configs.cm.url` if you use ingress/TLS/SSO so callbacks and links are correct.
2. Keep `configs.cm` **`kustomize.buildOptions: --enable-helm`** (already set in `base/values.yaml`). Argo CD’s repo-server needs this to build this repo’s Kustomize layouts that use the Helm chart inflator; it is applied with the rest of the chart on every fresh install—no extra bootstrap patch.
3. Choose an overlay:
   - `overlays/test` — smaller `argocd-server` resources.
   - `overlays/prod` — `argocd-server` and `argocd-repo-server` scaled to 2 replicas with higher resources.

## Install

From the repository root:

```bash
kubectl create namespace argocd
```

Render and apply (pick one overlay or `base`). Use **`--server-side`** so large CRDs (for example `applicationsets.argoproj.io`) do not hit Kubernetes’ **256KiB limit** on `metadata.annotations` from client-side `kubectl apply` (the `last-applied-configuration` annotation).

```bash
# Production-oriented overlay
kubectl kustomize --enable-helm overlays/prod | kubectl apply --server-side -f -

# Or test overlay
# kubectl kustomize --enable-helm overlays/test | kubectl apply --server-side -f -

# Or base only (no overlay patches)
# kubectl kustomize --enable-helm base | kubectl apply --server-side -f -
```

**Field-manager conflicts** (for example `conflict with "kubectl-client-side-apply"` on a `Deployment` env var) happen when the same objects were **previously applied client-side** (`kubectl apply` without `--server-side`). Server-side apply uses a different field manager, so Kubernetes refuses to overwrite those fields until you opt in. Run **once** with `--force-conflicts` so your server-side apply becomes the owner (safe when you intend to replace the manifest from this repo):

```bash
kubectl kustomize --enable-helm overlays/test | kubectl apply --server-side --force-conflicts -f -
```

Use the same overlay you use for normal installs (`overlays/prod`, `base`, etc.). Later applies can stay `--server-side` only if nothing else is mixing client-side apply on the same resources.

Wait for workloads to be ready:

```bash
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
```

### Git-managed Argo CD (after a new cluster)

Once the install above has finished, you can let Argo CD sync **this same repo** from Git:

1. Push this repository to GitHub (for example `https://github.com/devendradk/argocd-helm`).
2. In `bootstrap/root-application.yaml`, set `spec.source.path` to the **same overlay** you used in the install command (`overlays/prod` or `overlays/test`).
3. Apply the bootstrap Application **once**:

```bash
kubectl apply -f bootstrap/root-application.yaml
```

Because `argocd-cm` already includes `kustomize.buildOptions` from the Helm values applied in the install step, the `argocd-platform` app can render `kustomize build` on first sync without any manual ConfigMap patch.

### Initial login (bootstrap UI / CLI)

The chart creates a one-time **admin** password in a Secret:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
```

User name is `admin`. After you change the password or adopt SSO, you can remove that Secret per Argo CD documentation.

### Quick access without Ingress

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Open `https://localhost:8080` (accept the self-signed cert) and log in as `admin` with the password above.

### Ingress / TLS

Expose `argocd-server` with your cluster’s Ingress or Gateway; align `global.domain` and `configs.cm.url` with the public URL. Follow [Argo CD ingress TLS documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/) for termination and `insecure` / `server.insecure` options as needed.

## Upgrades

1. Bump the chart `version` in `base/kustomization.yaml` if you want a newer [argo-cd chart](https://github.com/argoproj/argo-helm/releases).
2. Re-run the same `kubectl kustomize --enable-helm … | kubectl apply --server-side -f -` command. CRDs are included from the chart; take the usual care with CRD upgrades in production.

## Alternative: Helm only

If you prefer not to use Kustomize, you can install the same chart directly:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  --version 9.4.17 \
  --namespace argocd \
  --create-namespace \
  -f base/values.yaml
```

Overlay-specific tweaks (replicas, resources) would need to be merged into that values file or supplied with extra `-f` files.
