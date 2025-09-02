#!/usr/bin/env bash
set -euo pipefail

# Turnkey local setup for:
# - k3s (single-node Kubernetes)
# - Argo CD (GitOps)
# - Argo Rollouts (blue-green/canary)
# - Argo CD Application pointing to a repo path with manifests
#
# Usage:
#   bash scripts/setup_k3s_argo.sh [REPO_URL] [REVISION] [PATH]
# Defaults:
#   REPO_URL: https://github.com/adhikarS/blue-green.git
#   REVISION: main
#   PATH: manifests

REPO_URL=${1:-"https://github.com/adhikarS/blue-green.git"}
REVISION=${2:-"main"}
APP_PATH=${3:-"manifests"}

echo "[info] Using repo: ${REPO_URL} rev: ${REVISION} path: ${APP_PATH}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

apt_install() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "[ok] $pkg already installed"
  else
    echo "[info] Installing $pkg"
    sudo apt-get update -y
    sudo apt-get install -y "$pkg"
  fi
}

echo "[step] Ensuring prerequisites (curl, git)"
apt_install curl
apt_install git

echo "[step] Installing k3s if missing"
if systemctl is-active --quiet k3s; then
  echo "[ok] k3s is already running"
else
  curl -sfL https://get.k3s.io | sh -
fi

echo "[step] Configuring kubectl access in ~/.kube/config"
mkdir -p "$HOME/.kube"
if [ -f "$HOME/.kube/config" ] && ! grep -q "k3s" "$HOME/.kube/config"; then
  cp "$HOME/.kube/config" "$HOME/.kube/config.backup.$(date +%s)" || true
fi
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$USER:$USER" "$HOME/.kube/config"

echo "[step] Waiting for node to be Ready"
kubectl wait node --all --for=condition=Ready --timeout=180s || true
kubectl get nodes -o wide

echo "[step] Installing Argo CD"
kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "[step] Waiting for Argo CD deployments to be Available"
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-application-controller --timeout=300s

echo "[step] Installing Argo Rollouts"
kubectl get ns argo-rollouts >/dev/null 2>&1 || kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

echo "[step] Waiting for Argo Rollouts controller"
kubectl -n argo-rollouts rollout status deploy/argo-rollouts --timeout=300s

echo "[step] Creating Argo CD Application for your repo"
cat <<EOF | kubectl apply -n argocd -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${REVISION}
    path: ${APP_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

echo "[step] Waiting for initial sync (this may take ~1 minute)"
sleep 15
kubectl -n argocd get applications my-app || true

echo "[info] Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "<could-not-read-yet>"
echo

cat <<EONOTE
Done!

Next steps:
1) Argo CD UI:
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   # Open https://localhost:8080 (ignore warning)
   # Username: admin | Password: printed above

2) App access (active service):
   kubectl port-forward svc/my-app-service 8081:80
   # http://localhost:8081 should show "Version 1 - Blue"

3) Preview (after switching to Rollouts):
   kubectl port-forward svc/my-app-preview 8082:80

If you change the repo URL/path, re-run this script with new values or edit the Application in Argo CD.
EONOTE

