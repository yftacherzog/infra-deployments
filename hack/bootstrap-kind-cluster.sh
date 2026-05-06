#!/bin/bash -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"/..
ARGOCD_NS="${ARGOCD_NS:-openshift-gitops}"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
log_info() { echo "[$(timestamp)] [INFO] $*"; }
log_success() { echo "[$(timestamp)] [SUCCESS] $*"; }
log_warn() { echo "[$(timestamp)] [WARN] $*"; }
log_step() {
  echo ""
  echo "============================================================================="
  echo "[$(timestamp)] [STEP] $*"
  echo "============================================================================="
}

print_help() {
  echo "Usage: $0 MODE [--repo-url <url>] [--revision <branch-or-tag>] [--clean-argocd] [-h|--help]"
  echo "  MODE: preview/upstream/preview-operator (default: preview-operator)"
}

resolve_preview_defaults() {
  if [[ -z "$REPO_URL" ]]; then
    local remote_name
    remote_name="${MY_GIT_FORK_REMOTE:-origin}"
    REPO_URL="$(git ls-remote --get-url "$remote_name" 2>/dev/null | sed 's|^git@github.com:|https://github.com/|')"
    if [[ -z "$REPO_URL" ]]; then
      REPO_URL="https://github.com/redhat-appstudio/infra-deployments.git"
    fi
  fi
  if [[ -z "$REVISION" ]]; then
    REVISION="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  fi

  # ArgoCD can only sync revisions resolvable by the remote repository.
  # If the local branch does not exist remotely, fall back to main.
  if ! git ls-remote --heads "$REPO_URL" "$REVISION" | grep -q "$REVISION"; then
    log_warn "Revision '$REVISION' not found in '$REPO_URL'; falling back to 'main'"
    REVISION="main"
  fi
}

render_root_app_manifest() {
  local mode="$1"
  local appset_path="$ROOT/argo-cd-apps/app-of-app-sets/staging"
  if [[ "$mode" == "preview" ]]; then
    appset_path="$ROOT/argo-cd-apps/app-of-app-sets/development"
  elif [[ "$mode" == "preview-operator" ]]; then
    appset_path="$ROOT/argo-cd-apps/app-of-app-sets/development-operator"
  fi

  RENDERED_MANIFEST="$(mktemp)"
  kubectl kustomize "$appset_path" > "$RENDERED_MANIFEST"

  if [[ "$mode" == "preview" || "$mode" == "preview-operator" ]]; then
    resolve_preview_defaults
    log_info "Preview overrides: repoURL=$REPO_URL, revision=$REVISION"
    REPO_URL="$REPO_URL" REVISION="$REVISION" yq -i '
      with(select(.kind == "Application");
        .spec.source.repoURL = strenv(REPO_URL) |
        .spec.source.targetRevision = strenv(REVISION)
      )
    ' "$RENDERED_MANIFEST"

    REPO_URL="$REPO_URL" REVISION="$REVISION" yq -i '
      with(select(.kind == "ApplicationSet" and .spec.template.spec.source != null);
        .spec.template.spec.source.repoURL = strenv(REPO_URL) |
        .spec.template.spec.source.targetRevision = strenv(REVISION)
      )
    ' "$RENDERED_MANIFEST"

    REPO_URL="$REPO_URL" REVISION="$REVISION" yq -i '
      with(select(.kind == "ApplicationSet" and .spec.template.spec.sources != null);
        .spec.template.spec.sources[1].repoURL = strenv(REPO_URL) |
        .spec.template.spec.sources[1].targetRevision = strenv(REVISION)
      )
    ' "$RENDERED_MANIFEST"
  fi
}

wait_for_root_application() {
  local root_app="all-application-sets"
  local elapsed=0
  local timeout_sec=300
  until kubectl -n "$ARGOCD_NS" get application "$root_app" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      log_warn "Root Application '$root_app' not found after ${timeout_sec}s"
      return 0
    fi
  done
  log_success "Root Application '$root_app' created"
}

patch_operator_appset_source() {
  local appset_name="konflux-operator"
  local timeout_sec=180
  local elapsed=0

  log_step "Patching operator ApplicationSet source for fork testing"
  log_info "Waiting for ApplicationSet '$appset_name' to appear"

  until kubectl -n "$ARGOCD_NS" get applicationset "$appset_name" >/dev/null 2>&1; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      log_warn "ApplicationSet '$appset_name' not found after ${timeout_sec}s"
      return 0
    fi
  done

  kubectl -n "$ARGOCD_NS" patch applicationset "$appset_name" --type merge -p "{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"source\": {
            \"repoURL\": \"${REPO_URL}\",
            \"targetRevision\": \"${REVISION}\"
          }
        }
      }
    }
  }"
  log_success "Patched ApplicationSet '$appset_name' to repoURL=$REPO_URL revision=$REVISION"
}

clean_argocd_workloads() {
  log_step "Cleaning existing ArgoCD workloads"
  kubectl -n "$ARGOCD_NS" delete applications.argoproj.io --all --ignore-not-found --wait=false
  kubectl -n "$ARGOCD_NS" delete applicationsets.argoproj.io --all --ignore-not-found --wait=false

  local timeout_sec=180
  local elapsed=0
  while true; do
    local app_count appset_count
    app_count="$(kubectl -n "$ARGOCD_NS" get applications.argoproj.io --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    appset_count="$(kubectl -n "$ARGOCD_NS" get applicationsets.argoproj.io --no-headers 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$app_count" == "0" && "$appset_count" == "0" ]]; then
      break
    fi

    sleep 5
    elapsed=$((elapsed + 5))
    if [[ "$elapsed" -ge "$timeout_sec" ]]; then
      log_warn "Timed out waiting for ArgoCD workload cleanup (${app_count} apps, ${appset_count} appsets remain)"
      break
    fi
  done
}

main() {
  MODE="preview-operator"
  REPO_URL=""
  REVISION=""
  CLEAN_ARGOCD=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      preview|upstream|preview-operator) MODE="$1"; shift ;;
      --repo-url) REPO_URL="$2"; shift 2 ;;
      --revision) REVISION="$2"; shift 2 ;;
      --clean-argocd) CLEAN_ARGOCD=true; shift ;;
      -h|--help) print_help; exit 0 ;;
      *) shift ;;
    esac
  done

  log_step "Starting Kind bootstrap (mode=$MODE)"
  log_step "Phase 1: Deploying ArgoCD on Kind"
  "$ROOT/hack/deploy-argocd-kind.sh"

  log_step "Phase 2: Rendering app-of-apps manifests"
  render_root_app_manifest "$MODE"
  trap 'rm -f "$RENDERED_MANIFEST"' EXIT

  if [[ "$MODE" == "preview-operator" ]]; then
    CLEAN_ARGOCD=true
  fi
  if [[ "$CLEAN_ARGOCD" == "true" ]]; then
    clean_argocd_workloads
  fi

  log_step "Phase 3: Applying app-of-apps manifests"
  kubectl apply -f "$RENDERED_MANIFEST"
  wait_for_root_application

  if [[ "$MODE" == "preview-operator" ]]; then
    patch_operator_appset_source
  fi

  log_success "Kind bootstrap complete"
  log_info "ArgoCD namespace: $ARGOCD_NS"
  log_info "Use: kubectl -n $ARGOCD_NS get applications"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
