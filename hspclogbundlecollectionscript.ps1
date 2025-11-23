<#
.SYNOPSIS
    Hitachi HSPC CSI Driver Log Bundle Collector v1.2.1 - PowerShell Edition
    -Kubeconfig optional · auto-detect OpenShift · full manifests
    -Collects logs from ALL containers in each pod.
    -Oc optional 
    -help optional · show usage
.EXAMPLE
    ./hspclogbundlecollectionscript.ps1 -Oc
    ./hspclogbundlecollectionscript.ps1 -Oc -Namespace my-namespace
    ./hspclogbundlecollectionscript.ps1 -Oc -Namespace my-namespace -Dir ./my-output-dir
    ./hspclogbundlecollectionscript.ps1 -Oc -Namespace my-namespace -Dir ./my-output-dir -Jobs 10
    ./hspclogbundlecollectionscript.ps1 -Oc -Namespace my-namespace -Dir ./my-output-dir -Jobs 10 -NoCompress
    ./hspclogbundlecollectionscript.ps1 -Kubeconfig ./kubeconfig
    ./hspclogbundlecollectionscript.ps1 -Kubeconfig ./kubeconfig -Namespace my-namespace
    ./hspclogbundlecollectionscript.ps1 -Kubeconfig ./kubeconfig -Namespace my-namespace -Dir ./my-output-dir
    ./hspclogbundlecollectionscript.ps1 -Kubeconfig ./kubeconfig -Namespace my-namespace -Dir ./my-output-dir -Jobs 10
    ./hspclogbundlecollectionscript.ps1 -Kubeconfig ./kubeconfig -Namespace my-namespace -Dir ./my-output-dir -Jobs 10 -NoCompress
    ./hspclogbundlecollectionscript.ps1 -Kubeconfig ./kubeconfig -Namespace my-namespace
#>

param(
    [string]$Kubeconfig = "",
    [switch]$Oc,
    [string]$Namespace = "",
    [string]$Dir = "",
    [int]$Jobs = 4,
    [switch]$NoCompress
)

$ErrorActionPreference = "Stop"

# Prefer local binaries if present, otherwise system PATH
$Kubectl = if (Test-Path "./kubectl.exe") { "./kubectl.exe" } elseif (Test-Path "./kubectl") { "./kubectl" } elseif (Get-Command "kubectl" -ErrorAction SilentlyContinue) { "kubectl" } else { "" }
$OcCmd   = if (Test-Path "./oc.exe") { "./oc.exe" } elseif (Test-Path "./oc") { "./oc" } elseif (Get-Command "oc" -ErrorAction SilentlyContinue) { "oc" } else { "" }

# Ensure at least one command is available
if ($Oc -and -not $OcCmd) {
    Die "oc binary not found (required when -Oc flag is used)"
}

if (-not $Oc) {
    # Not explicitly using -Oc flag, prefer kubectl but fall back to oc
    if ($Kubectl) {
        $Cmd = $Kubectl
    } elseif ($OcCmd) {
        $Cmd = $OcCmd
        Log "kubectl not found, using oc command"
    } else {
        Die "Neither kubectl nor oc found. Please install kubectl/oc or configure PATH with location, or place it in the current directory."
    }
} else {
    # Explicitly using -Oc flag
    $Cmd = $OcCmd
}

$OutputDir = if ($Dir) { $Dir } else { "./hspc-csi-logs-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
$Compress = -not $NoCompress

$CRD_NAME = "hspcs.csi.hitachi.com"
$KIND = "HSPC"
$SERVICE_ACCOUNT = "hspc-csi-sa"

function Log { param([string]$msg) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }

function Die { param([string]$msg) Write-Error "ERROR: $msg"; exit 1 }

function Kube {
    $fullArgs = @()
    if ($Kubeconfig) {
        $fullArgs += "--kubeconfig"
        $fullArgs += $Kubeconfig
    }
    $fullArgs += $args
    & $Cmd @fullArgs
}

function Test-OpenShift {
    try { Kube api-resources --api-group=route.openshift.io | Out-Null; return $true } catch {}
    try { Kube api-resources --api-group=security.openshift.io | Out-Null; return $true } catch {}
    try { Kube api-resources --api-group=console.openshift.io | Out-Null; return $true } catch {}
    return $false
}

Log "Using: $Cmd $(if ($Kubeconfig) { "--kubeconfig=$Kubeconfig" } else { '(default kubeconfig)' })"

if (($Cmd -like "*kubectl*") -and (Test-OpenShift)) {
    if ($OcCmd) {
        Log "OpenShift detected → switching to oc"
        $Cmd = $OcCmd
    } else {
        Log "OpenShift detected but 'oc' binary not found → continuing with kubectl"
    }
}

# Final safety net
$null = Kube get crd $CRD_NAME 2>&1
if (-not $?) {
    if (($Cmd -like "*kubectl*") -and $OcCmd -and (Get-Command $OcCmd -ErrorAction SilentlyContinue)) {
        Log "CRD not visible with kubectl → forcing oc"
        $Cmd = $OcCmd
    }
}

$null = Kube get crd $CRD_NAME 2>&1
if (-not $?) {
    Die "CRD $CRD_NAME not found - wrong cluster or auth issue"
}
Log "Found HSPC CRD"

if (-not $Namespace) {
    Log "Discovering HSPC namespace..."
    $Namespace = (Kube get $KIND --all-namespaces -o jsonpath='{.items[0].metadata.namespace}')
    if (-not $Namespace) { Die "No HSPC CR found" }
    Log "HSPC namespace: $Namespace"
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$pods = (Kube get pods -n $Namespace -o jsonpath="{range .items[?(@.spec.serviceAccountName=='$SERVICE_ACCOUNT')]}{.metadata.name}{'\n'}{end}").Trim() -split "`n" | Where-Object { $_.Length -gt 0 }

if ($pods.Count -eq 0) { Die "No HSPC pods found" }

Log "Found $($pods.Count) pods: $($pods -join ' ')"

Log "Collecting logs sequentially (reliable on all PS versions)..."
foreach ($pod in $pods) {
    Log "Collecting logs from pod $pod ..."
    
    # Get all containers in the pod
    try {
        $containers = (Kube get pod $pod -n $Namespace -o jsonpath='{.spec.containers[*].name}' 2>> "$OutputDir/errors.log").Trim() -split '\s+' | Where-Object { $_.Length -gt 0 }
        
        if ($containers.Count -eq 0) {
            "$pod (no containers found)" | Out-File -Append "$OutputDir/failed-pods.txt"
            Log "FAILED $pod - no containers found"
            continue
        }
        
        # Collect logs from each container
        foreach ($container in $containers) {
            $file = "$OutputDir/${pod}_${container}.log"
            try {
                Kube logs $pod -n $Namespace -c $container --limit-bytes=200000000 > $file 2>> "$OutputDir/errors.log"
                Log "  `u{2713} Saved $pod/$container"
            } catch {
                "$pod/$container" | Out-File -Append "$OutputDir/failed-pods.txt"
                Log "  `u{2717} FAILED $pod/$container - see errors.log"
            }
        }
    } catch {
        "$pod (error getting containers)" | Out-File -Append "$OutputDir/failed-pods.txt"
        Log "FAILED $pod - error getting containers"
    }
}

# Full context dump - clean output
$contextFile = "$OutputDir/cluster-context.txt"

"=== Cluster Version ===" | Out-File -Encoding utf8 $contextFile
Kube version | Out-File -Encoding utf8 -Append $contextFile

"`n=== Orchestration Platform ===" | Out-File -Encoding utf8 -Append $contextFile
if (Test-OpenShift) {
    "Platform: OpenShift" | Out-File -Encoding utf8 -Append $contextFile
    try {
        Kube version -o json | Out-File -Encoding utf8 -Append $contextFile
    } catch {
        "OpenShift (version details unavailable)" | Out-File -Encoding utf8 -Append $contextFile
    }
} else {
    "Platform: Kubernetes" | Out-File -Encoding utf8 -Append $contextFile
}

"`n=== Node OS & Runtime Information ===" | Out-File -Encoding utf8 -Append $contextFile
Kube get nodes -o wide | Out-File -Encoding utf8 -Append $contextFile
"`n--- Detailed Node Info ---" | Out-File -Encoding utf8 -Append $contextFile
Kube get nodes -o jsonpath="{range .items[*]}{.metadata.name}{'\n'}  OS: {.status.nodeInfo.osImage}{'\n'}  Kernel: {.status.nodeInfo.kernelVersion}{'\n'}  Architecture: {.status.nodeInfo.architecture}{'\n'}  Container Runtime: {.status.nodeInfo.containerRuntimeVersion}{'\n'}  Kubelet: {.status.nodeInfo.kubeletVersion}{'\n'}{'\n'}{end}" | Out-File -Encoding utf8 -Append $contextFile

"`n=== HSPC CR ===" | Out-File -Encoding utf8 -Append $contextFile
Kube get hspc -n $Namespace -o yaml | Out-File -Encoding utf8 -Append $contextFile

"`n=== All Deployments ===" | Out-File -Encoding utf8 -Append $contextFile
try {
    Kube get deploy -n $Namespace -o yaml | Out-File -Encoding utf8 -Append $contextFile
} catch {
    "No deployments found" | Out-File -Encoding utf8 -Append $contextFile
}

"`n=== All DaemonSets ===" | Out-File -Encoding utf8 -Append $contextFile
try {
    Kube get daemonset -n $Namespace -o yaml | Out-File -Encoding utf8 -Append $contextFile
} catch {
    "No DaemonSets found" | Out-File -Encoding utf8 -Append $contextFile
}

"`n=== All ReplicaSets ===" | Out-File -Encoding utf8 -Append $contextFile
try {
    Kube get rs -n $Namespace -o yaml | Out-File -Encoding utf8 -Append $contextFile
} catch {
    "No ReplicaSets found" | Out-File -Encoding utf8 -Append $contextFile
}

"`n=== HSPC StorageClasses ===" | Out-File -Encoding utf8 -Append $contextFile
try {
    $scNames = (Kube get storageclass -o jsonpath='{range .items[?(@.provisioner=="hspc.csi.hitachi.com")]}{.metadata.name}{"\n"}{end}' 2>$null).Trim() -split "`n" | Where-Object { $_.Length -gt 0 }
    if ($scNames.Count -gt 0) {
        foreach ($sc in $scNames) {
            Kube get storageclass $sc -o yaml | Out-File -Encoding utf8 -Append $contextFile
        }
    } else {
        "No HSPC StorageClasses found" | Out-File -Encoding utf8 -Append $contextFile
    }
} catch {
    "Error retrieving HSPC StorageClasses" | Out-File -Encoding utf8 -Append $contextFile
}

"`n=== Pod Ownership Chain ===" | Out-File -Encoding utf8 -Append $contextFile
foreach ($pod in $pods) {
    $ErrorActionPreference = 'SilentlyContinue'
    $ownerKind = (Kube get pod $pod -n $Namespace -o jsonpath='{.metadata.ownerReferences[0].kind}') ?? "None"
    $ownerName = (Kube get pod $pod -n $Namespace -o jsonpath='{.metadata.ownerReferences[0].name}') ?? "None"
    if ($ownerKind -eq "ReplicaSet") {
        $deploy = (Kube get rs $ownerName -n $Namespace -o jsonpath='{.metadata.ownerReferences[0].name}') ?? "unknown"
        "$pod → ReplicaSet/$ownerName → Deployment/$deploy" | Out-File -Encoding utf8 -Append $contextFile
    } else {
        "$pod → $ownerKind/$ownerName" | Out-File -Encoding utf8 -Append $contextFile
    }
    $ErrorActionPreference = 'Continue'
}

"`n=== Pod Descriptions ===" | Out-File -Encoding utf8 -Append $contextFile
foreach ($pod in $pods) {
    "=== $pod ===" | Out-File -Encoding utf8 -Append $contextFile
    Kube describe pod $pod -n $Namespace | Out-File -Encoding utf8 -Append $contextFile
    "" | Out-File -Encoding utf8 -Append $contextFile
}

"`n=== Recent Events ===" | Out-File -Encoding utf8 -Append $contextFile
Kube get events -n $Namespace --sort-by='.lastTimestamp' | Select-Object -Last 100 | Out-File -Encoding utf8 -Append $contextFile

Log "Collection complete → $OutputDir"

if ($Compress) {
    $zipfile = "$OutputDir.zip"
    Compress-Archive -Path "$OutputDir\*" -DestinationPath $zipfile -Force
    Log "Zip created (built-in): $zipfile"
}

Log "HSPC CSI support bundle ready."