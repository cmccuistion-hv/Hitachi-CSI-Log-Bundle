#!/usr/bin/env bash
# =============================================================================
# Hitachi HSPC CSI Driver Log Bundle Collector v1.5.1
# - --kubeconfig is completely optional (uses default or $KUBECONFIG if present)
# - Full OpenShift auto-detect + smart fallback to ./oc
# - All manifests with status (deployments, daemonsets, replicasets)
# - Collects logs from ALL containers in each pod
# - Pod ownership chain
# - Events, describes, version, HSPC CR
# - Python zip fallback (always works)
# - Parallel collection
# =============================================================================

set -euo pipefail

# Script version
SCRIPT_VERSION="1.5.1"

# Helper functions
log() { echo "[$(date +'%H:%M:%S')] $*"; }
die() { echo "ERROR: $*"; exit 1; }

# Prefer local binaries if present, otherwise fall back to system PATH
KUBECTL_CMD=$(command -v ./kubectl 2>/dev/null || command -v kubectl || echo "")
OC_CMD=$(command -v ./oc 2>/dev/null || command -v oc || echo "")

# Ensure at least one command is available (prefer kubectl, fall back to oc)
if [[ -n "$KUBECTL_CMD" ]]; then
    CMD="$KUBECTL_CMD"
elif [[ -n "$OC_CMD" ]]; then
    CMD="$OC_CMD"
    log "kubectl not found, using oc command"
else
    die "Neither kubectl nor oc found. Please install kubectl/oc or configure PATH with location, or place it in the current directory."
fi

KUBECONFIG_ARG=""
NAMESPACE=""
OUTPUT_DIR="./hspc-csi-logs-$(date +%Y%m%d-%H%M%S)"
PARALLEL_JOBS=4
COMPRESS=true
TIMEOUT_SEC=300

CRD_NAME="hspcs.csi.hitachi.com"
KIND="HSPC"
SERVICE_ACCOUNT="hspc-csi-sa"

KUBE() {
    if [[ -n "$KUBECONFIG_ARG" ]]; then
        "$CMD" $KUBECONFIG_ARG "$@"
    else
        "$CMD" "$@"
    fi
}

detect_openshift() {
    # Check if any of these API groups return actual resources (more than just header line)
    # kubectl api-resources returns a header line even when no resources exist, so check for >1 line
    local line_count
    line_count=$(KUBE api-resources --api-group=route.openshift.io 2>/dev/null | wc -l)
    [[ $line_count -gt 1 ]] && return 0
    
    line_count=$(KUBE api-resources --api-group=security.openshift.io 2>/dev/null | wc -l)
    [[ $line_count -gt 1 ]] && return 0
    
    line_count=$(KUBE api-resources --api-group=console.openshift.io 2>/dev/null | wc -l)
    [[ $line_count -gt 1 ]] && return 0
    
    return 1
}

get_pods() {
    KUBE get pods -n "$NAMESPACE" \
        -o jsonpath='{range .items[?(@.spec.serviceAccountName=="'"$SERVICE_ACCOUNT"'")]}{.metadata.name}{"\n"}{end}'
}

collect_pod_logs() {
    local pod="$1"
    log "Collecting logs from pod $pod ..."
    
    # Get all containers in the pod
    local containers
    containers=$(timeout "$TIMEOUT_SEC" "$CMD" ${KUBECONFIG_ARG:-} get pod "$pod" -n "$NAMESPACE" \
        -o jsonpath='{.spec.containers[*].name}' 2>>"$OUTPUT_DIR/errors.log")
    
    if [[ -z "$containers" ]]; then
        echo "$pod (no containers found)" >> "$OUTPUT_DIR/failed-pods.txt"
        log "FAILED $pod - no containers found"
        return
    fi
    
    # Collect logs from each container
    for container in $containers; do
        local file="$OUTPUT_DIR/${pod}_${container}.log"
        if timeout "$TIMEOUT_SEC" "$CMD" ${KUBECONFIG_ARG:-} logs "$pod" -n "$NAMESPACE" -c "$container" \
            --limit-bytes=200000000 > "$file" 2>>"$OUTPUT_DIR/errors.log"; then
            log "  ✓ Saved $pod/$container"
        else
            echo "$pod/$container" >> "$OUTPUT_DIR/failed-pods.txt"
            log "  ✗ FAILED $pod/$container - see errors.log"
        fi
    done
}

export -f collect_pod_logs
export CMD KUBECONFIG_ARG NAMESPACE OUTPUT_DIR TIMEOUT_SEC

while [[ $# -gt 0 ]]; do
    case $1 in
        --kubeconfig) KUBECONFIG_ARG="--kubeconfig=$2"; shift 2 ;;
        --oc)         [[ -n "$OC_CMD" ]] || die "oc binary not found"; CMD="$OC_CMD"; shift ;;
        -n|--namespace) NAMESPACE="$2"; shift 2 ;;
        -d|--dir)     OUTPUT_DIR="$2"; shift 2 ;;
        -j|--jobs)    PARALLEL_JOBS="$2"; shift 2 ;;
        --no-compress) COMPRESS=false; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: ./hspclogbundlecollectionscript.sh [options]
  --kubeconfig <file>   (optional)
  --oc                  Force ./oc or system oc
  -n <ns>               Force namespace
  -d <dir>              Output dir
  -j <N>                Parallel jobs
  --no-compress         No zip
EOF
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
done

log "Using: $CMD ${KUBECONFIG_ARG:- (default kubeconfig)}"

if [[ "$CMD" == "$KUBECTL_CMD" ]] && detect_openshift; then
    if [[ -n "$OC_CMD" ]]; then
        log "OpenShift detected → switching to oc"
        CMD="$OC_CMD"
    else
        log "OpenShift detected but 'oc' binary not found → continuing with kubectl"
    fi
fi

if ! KUBE get crd "$CRD_NAME" >/dev/null 2>&1; then
    if [[ "$CMD" == "$KUBECTL_CMD" ]] && [[ -n "$OC_CMD" ]]; then
        log "CRD not visible with kubectl → forcing oc"
        CMD="$OC_CMD"
    fi
fi

KUBE get crd "$CRD_NAME" >/dev/null || die "CRD $CRD_NAME not found"

if [[ -z "$NAMESPACE" ]]; then
    log "Discovering HSPC namespace..."
    NAMESPACE=$(KUBE get "$KIND" --all-namespaces -o jsonpath='{.items[0].metadata.namespace}')
    [[ -n "$NAMESPACE" ]] || die "No HSPC CR found"
    log "HSPC namespace: $NAMESPACE"
fi

mkdir -p "$OUTPUT_DIR"

mapfile -t PODS < <(get_pods)
[[ ${#PODS[@]} -gt 0 ]] || die "No HSPC pods found"

log "Found ${#PODS[@]} pods: ${PODS[*]}"

if command -v parallel >/dev/null 2>&1; then
    log "Collecting in parallel ($PARALLEL_JOBS jobs)..."
    printf '%s\n' "${PODS[@]}" | parallel -j "$PARALLEL_JOBS" collect_pod_logs
else
    log "Collecting sequentially..."
    for pod in "${PODS[@]}"; do collect_pod_logs "$pod"; done
fi

{
    echo "=== Log Collection Script Version ==="
    echo "Script Version: $SCRIPT_VERSION"
    echo "Collection Date: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    
    echo -e "\n=== Cluster Version ==="
    KUBE version

    echo -e "\n=== Orchestration Platform ==="
    if detect_openshift; then
        echo "Platform: OpenShift"
        KUBE version -o json 2>/dev/null | grep -E '"gitVersion"|"platform"' || true
    else
        echo "Platform: Kubernetes"
    fi

    echo -e "\n=== Node OS & Runtime Information ==="
    KUBE get nodes -o wide
    echo -e "\n--- Detailed Node Info ---"
    KUBE get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}  OS: {.status.nodeInfo.osImage}{"\n"}  Kernel: {.status.nodeInfo.kernelVersion}{"\n"}  Architecture: {.status.nodeInfo.architecture}{"\n"}  Container Runtime: {.status.nodeInfo.containerRuntimeVersion}{"\n"}  Kubelet: {.status.nodeInfo.kubeletVersion}{"\n"}{"\n"}{end}'

    echo -e "\n=== HSPC CR ==="
    KUBE get hspc -n "$NAMESPACE" -o yaml

    echo -e "\n=== Deployments ==="
    KUBE get deploy -n "$NAMESPACE" -o yaml 2>/dev/null || echo "No deployments found"

    echo -e "\n=== DaemonSets ==="
    KUBE get daemonset -n "$NAMESPACE" -o yaml 2>/dev/null || echo "No DaemonSets found"

    echo -e "\n=== ReplicaSets ==="
    KUBE get rs -n "$NAMESPACE" -o yaml 2>/dev/null || echo "No ReplicaSets found"

    echo -e "\n=== HSPC StorageClasses ==="
    sc_names=$(KUBE get storageclass -o jsonpath='{range .items[?(@.provisioner=="hspc.csi.hitachi.com")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -v '^$' || true)
    if [[ -n "$sc_names" ]]; then
        echo "$sc_names" | while read -r sc; do
            [[ -n "$sc" ]] && KUBE get storageclass "$sc" -o yaml 2>/dev/null || true
        done
    else
        echo "No HSPC StorageClasses found"
    fi

    echo -e "\n=== Pod Ownership Chain ==="
    for pod in "${PODS[@]}"; do
        owner_kind=$(KUBE get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || echo "None")
        owner_name=$(KUBE get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "None")
        if [[ "$owner_kind" == "ReplicaSet" ]]; then
            deploy=$(KUBE get rs "$owner_name" -n "$NAMESPACE" -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || echo "unknown")
            echo "$pod → ReplicaSet/$owner_name → Deployment/$deploy"
        else
            echo "$pod → $owner_kind/$owner_name"
        fi
    done

    echo -e "\n=== Pod Descriptions ==="
    for pod in "${PODS[@]}"; do
        echo "=== $pod ==="
        KUBE describe pod "$pod" -n "$NAMESPACE"
        echo
    done

    echo -e "\n=== Recent Events ==="
    KUBE get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -100 || KUBE get events -n "$NAMESPACE" 2>/dev/null | tail -100 || echo "No events available"

} > "$OUTPUT_DIR/cluster-context.txt"

log "Collection complete → $OUTPUT_DIR"

if $COMPRESS; then
    zipfile="${OUTPUT_DIR}.zip"
    if command -v zip >/dev/null 2>&1; then
        zip -r -q "$zipfile" "$OUTPUT_DIR"
        log "Zip created (system zip): $zipfile"
    elif command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
        python_cmd=$(command -v python3 || command -v python)
        log "Creating zip with Python"
        "$python_cmd" -c "
import zipfile, os, sys
zip_path, dir_path = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(dir_path):
        for file in files:
            full = os.path.join(root, file)
            arcname = os.path.relpath(full, os.path.dirname(dir_path))
            z.write(full, arcname)
" "$zipfile" "$OUTPUT_DIR"
        log "Zip created (Python): $zipfile"
    else
        log "No zip/python → folder only"
    fi
fi

log "Hitachi CSI support bundle ready."