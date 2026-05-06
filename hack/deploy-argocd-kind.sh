#!/bin/bash -e

ARGOCD_NS="${ARGOCD_NS:-openshift-gitops}"
ARGOCD_INSTALL_URL="${ARGOCD_INSTALL_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_info() {
    echo "[$(timestamp)] [INFO] $*"
}

log_success() {
    echo "[$(timestamp)] [SUCCESS] $*"
}

log_warn() {
    echo "[$(timestamp)] [WARN] $*"
}

log_step() {
    echo ""
    echo "============================================================================="
    echo "[$(timestamp)] [STEP] $*"
    echo "============================================================================="
}

main() {
    log_step "Deploying ArgoCD on Kind"
    log_info "Namespace: $ARGOCD_NS"
    log_info "Install source: $ARGOCD_INSTALL_URL"

    kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -

    local install_file
    install_file="$(mktemp)"
    trap 'rm -f "$install_file"' EXIT

    curl -fsSL "$ARGOCD_INSTALL_URL" -o "$install_file"

    # CRDs in the upstream bundle can exceed client-side apply annotation limits.
    # Use server-side apply to avoid creating the large last-applied annotation.
    kubectl -n "$ARGOCD_NS" apply --server-side=true --force-conflicts=true -f "$install_file"

    log_info "Waiting for ArgoCD core deployments"
    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-repo-server --timeout=300s
    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-server --timeout=300s
    kubectl -n "$ARGOCD_NS" rollout status deployment/argocd-applicationset-controller --timeout=300s

    log_info "Applying Kind compatibility RBAC and project defaults"
    patch_subject_namespaces
    patch_flowcontrol_permissions
    ensure_default_appproject
    ensure_incluster_secret

    log_success "ArgoCD is ready in namespace '$ARGOCD_NS'"
    log_info "Tip: kubectl -n $ARGOCD_NS port-forward svc/argocd-server 8080:443"
}

patch_subject_namespaces() {
    local rb
    for rb in argocd-application-controller argocd-applicationset-controller argocd-dex-server argocd-notifications-controller argocd-redis argocd-server; do
        kubectl -n "$ARGOCD_NS" patch rolebinding "$rb" --type='json' -p="[{\"op\":\"replace\",\"path\":\"/subjects/0/namespace\",\"value\":\"${ARGOCD_NS}\"}]"
    done

    local crb
    for crb in argocd-application-controller argocd-applicationset-controller argocd-server; do
        kubectl patch clusterrolebinding "$crb" --type='json' -p="[{\"op\":\"replace\",\"path\":\"/subjects/0/namespace\",\"value\":\"${ARGOCD_NS}\"}]"
    done
}

patch_flowcontrol_permissions() {
    kubectl patch clusterrole argocd-application-controller --type='json' -p='[
      {"op":"add","path":"/rules/-","value":{"apiGroups":["flowcontrol.apiserver.k8s.io"],"resources":["prioritylevelconfigurations","flowschemas"],"verbs":["get","list","watch"]}}
    ]' || true
}

ensure_default_appproject() {
    kubectl -n "$ARGOCD_NS" apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: default
spec:
  sourceRepos:
    - '*'
  destinations:
    - namespace: '*'
      server: '*'
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
EOF
}

ensure_incluster_secret() {
    kubectl -n "$ARGOCD_NS" apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: in-cluster
  labels:
    argocd.argoproj.io/secret-type: cluster
    appstudio.redhat.com/member-cluster: "true"
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
  config: |
    {"tlsClientConfig":{"insecure":false}}
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
