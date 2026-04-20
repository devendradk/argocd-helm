# argocd-helm

Install [Argo CD](https://argo-cd.readthedocs.io/) with the upstream [argo-cd Helm chart](https://artifacthub.io/packages/helm/argo/argo-cd) using **Kustomize’s Helm chart inflator** (`base/` + `overlays/`, like a typical Kustomize-wrapped Helm setup).

Use this to run a **hub** Argo CD that can manage **this cluster and others** (register additional clusters in Settings or via Git). The default in-cluster destination remains available for **self-managed** GitOps (Argo CD managing its own manifests) once you add an `Application` for this install.

## Prerequisites

- A Kubernetes cluster and a kubecontext with permission to install cluster-scoped CRDs and RBAC.
- `kubectl` **1.26+** with built-in Kustomize that supports Helm (`kubectl kustomize --help` should mention `--enable-helm`), **or** standalone [Kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/) v5+ with the same flag.
- Network access on the machine running the command so Kustomize can download the Helm chart the first time (cached under `base/charts/`; that path is gitignored).

## Repository layout

```text
argocd-helm/
├── base/                    # Argo CD only: Helm chart + shared values.yaml
├── apps/                    # GitOps resources Argo CD reconciles (e.g. ApplicationSet)
├── overlays/
│   ├── prod/                # Steady state: base + prod patches + apps
│   ├── test/                # Steady state: base + test patches + apps
│   ├── prod-bootstrap/      # First install: base + prod patches (no apps/)
│   └── test-bootstrap/      # First install: base + test patches (no apps/)
├── bootstrap/               # One-shot YAML (root Application); not part of base kustomization
├── Makefile                 # make bootstrap-prod, apply-prod, etc.
└── README.md
```

- **`base/`** — Installs the Argo CD control plane from the upstream chart. Same chart for every environment; environment tweaks live in overlays.
- **`apps/`** — Manifests that **require** Argo CD CRDs (for example `ApplicationSet`). Referenced from steady-state overlays so they are not applied in the same `kubectl apply` wave as brand-new CRDs.
- **`overlays/<env>/`** — **Steady state**: composes `../../base`, `../../apps`, and strategic-merge patches for that environment (`server-patch.yaml`, and for prod also `repo-server-patch.yaml`).
- **`overlays/<env>-bootstrap/`** — **New cluster only**: same patches as prod/test, but **only** `../../base` (no `apps/`). Apply this first so CRDs exist before Git (or a second apply) adds `ApplicationSet` objects.
- **`bootstrap/`** — `root-application.yaml` is applied **once** by you so Argo CD syncs the repo from Git at `spec.source.path` (typically `overlays/prod` or `overlays/test`). It is intentionally **not** listed under `base/` so you avoid self-recursive packaging.

Build mental model:

```text
overlays/prod-bootstrap  →  base + prod patches
overlays/prod            →  base + prod patches + apps
```

## Configure before install

1. Edit `base/values.yaml` (or add an overlay) and set a real hostname in `global.domain`, and uncomment/set `configs.cm.url` if you use ingress/TLS/SSO so callbacks and links are correct.
2. Keep `configs.cm` **`kustomize.buildOptions: --enable-helm`** (already set in `base/values.yaml`). Argo CD’s repo-server needs this to build this repo’s Kustomize layouts that use the Helm chart inflator; it is applied with the rest of the chart on every fresh install—no extra bootstrap patch.
3. Choose an overlay:
   - `overlays/test` — smaller `argocd-server` resources.
   - `overlays/prod` — `argocd-server` and `argocd-repo-server` scaled to 2 replicas with higher resources.
4. For **new cluster bootstrap**, use `overlays/test-bootstrap` or `overlays/prod-bootstrap` first. These install Argo CD core only (no `ApplicationSet`) to avoid first-apply CRD registration races.

## Install

From the repository root:

```bash
kubectl create namespace argocd
```

Render and apply a **bootstrap overlay first**. Use **`--server-side`** so large CRDs (for example `applicationsets.argoproj.io`) do not hit Kubernetes’ **256KiB limit** on `metadata.annotations` from client-side `kubectl apply` (the `last-applied-configuration` annotation).

```bash
# Production-oriented bootstrap overlay (recommended for first install on a new cluster)
kubectl kustomize --enable-helm overlays/prod-bootstrap | kubectl apply --server-side -f -

# Or test bootstrap overlay
# kubectl kustomize --enable-helm overlays/test-bootstrap | kubectl apply --server-side -f -

# Or base only (no overlay patches)
# kubectl kustomize --enable-helm base | kubectl apply --server-side -f -
```

Equivalent **Make** targets (from repo root):

```bash
make bootstrap-prod      # or: make bootstrap-test
make wait-rollouts
make apply-git           # after editing bootstrap/root-application.yaml if needed
```

For a full local apply of the steady-state overlay (includes `apps/`), use `make apply-prod` or `make apply-test`. `make help` lists all targets.

**Field-manager conflicts** (for example `conflict with "kubectl-client-side-apply"` on a `Deployment` env var) happen when the same objects were **previously applied client-side** (`kubectl apply` without `--server-side`). Server-side apply uses a different field manager, so Kubernetes refuses to overwrite those fields until you opt in. Run **once** with `--force-conflicts` so your server-side apply becomes the owner (safe when you intend to replace the manifest from this repo):

```bash
kubectl kustomize --enable-helm overlays/test | kubectl apply --server-side --force-conflicts -f -
```

Use the same bootstrap overlay you use for normal installs (`overlays/prod-bootstrap`, etc.). Later applies can stay `--server-side` only if nothing else is mixing client-side apply on the same resources.

Wait for workloads to be ready:

```bash
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd rollout status deployment/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
```

### Git-managed Argo CD (after a new cluster)

Once the install above has finished, you can let Argo CD sync **this same repo** from Git:

1. Push this repository to GitHub (for example `https://github.com/devendradk/argocd-helm`).
2. In `bootstrap/root-application.yaml`, set `spec.source.path` to the **steady-state overlay** (`overlays/prod` or `overlays/test`).
3. Apply the bootstrap Application **once**:

```bash
kubectl apply -f bootstrap/root-application.yaml
```

Because `argocd-cm` already includes `kustomize.buildOptions` from the Helm values applied in the install step, the `argocd-platform` app can render `kustomize build` on first sync without any manual ConfigMap patch. The steady-state overlays include `apps/` (ApplicationSet), so CRD-dependent app resources are created by Argo CD after core is up.

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
