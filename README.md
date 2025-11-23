# Hitachi CSI Log Bundle Collector

A comprehensive log collection tool for Hitachi CSI drivers running in Kubernetes or OpenShift environments. This tool automatically discovers your HSPC installation, collects logs from all our CSI's pods and containers, gathers cluster context, and packages everything into a convenient bundle for troubleshooting and support.

## Features

- 🔍 **Auto-Discovery**: Automatically detects HSPC namespace and resources
- 🎯 **Platform-Aware**: Detects OpenShift vs Kubernetes and uses appropriate tooling
- 📦 **Complete Collection**: Gathers logs from all containers in each pod
- 🏗️ **Full Context**: Captures cluster version, node info, manifests, events, and resource descriptions
- ⚡ **Parallel Processing**: Bash script supports parallel log collection (optional)
- 🗜️ **Auto-Compression**: Creates zip archives automatically (optional)
- 🛡️ **Robust**: Handles timeouts, errors gracefully, and provides fallback mechanisms
- 💻 **Cross-Platform**: Both Bash and PowerShell versions available

## Requirements

### Bash Script (`hspclogbundlecollectionscript.sh`)

- Linux or macOS
- Bash 4.0+
- `kubectl` or `oc` binary (can be local or in PATH)
- Valid kubeconfig with access to the cluster
- Optional: `parallel` for faster collection
- Optional: `zip` or `python3` for compression

### PowerShell Script (`hspclogbundlecollectionscript.ps1`)

- Windows, Linux, or macOS
- PowerShell 5.1+ or PowerShell Core 7+
- `kubectl.exe`/`kubectl` or `oc.exe`/`oc` binary
- Valid kubeconfig with access to the cluster

## Installation

1. Download the appropriate script for your platform:
   ```bash
   # Clone the repository
   git clone https://github.com/cmccuistion-hv/Hitachi-CSI-Log-Bundle.git
   cd Hitachi-CSI-Log-Bundle
   ```

2. Make the bash script executable (Linux/macOS):
   ```bash
   chmod +x hspclogbundlecollectionscript.sh
   ```

3. (Optional) Place `kubectl` or `oc` binary in the same directory, or ensure it's in your PATH

## Usage

### Bash Script Examples

**Basic usage** (uses default kubeconfig):
```bash
./hspclogbundlecollectionscript.sh
```

**With specific kubeconfig**:
```bash
./hspclogbundlecollectionscript.sh --kubeconfig /path/to/kubeconfig
```

**Force OpenShift oc binary**:
```bash
./hspclogbundlecollectionscript.sh --oc
```

**Specify namespace** (if auto-detection fails):
```bash
./hspclogbundlecollectionscript.sh -n hspc-system
```

**Custom output directory**:
```bash
./hspclogbundlecollectionscript.sh -d /tmp/my-logs
```

**Parallel collection with 8 jobs**:
```bash
./hspclogbundlecollectionscript.sh -j 8
```

**Skip compression**:
```bash
./hspclogbundlecollectionscript.sh --no-compress
```

**Combined options**:
```bash
./hspclogbundlecollectionscript.sh --kubeconfig ./kubeconfig --oc -n hspc-system -j 8
```

### PowerShell Script Examples

**Basic usage**:
```powershell
.\hspclogbundlecollectionscript.ps1
```

**With specific kubeconfig**:
```powershell
.\hspclogbundlecollectionscript.ps1 -Kubeconfig C:\path\to\kubeconfig
```

**Force OpenShift oc binary**:
```powershell
.\hspclogbundlecollectionscript.ps1 -Oc
```

**Specify namespace**:
```powershell
.\hspclogbundlecollectionscript.ps1 -Namespace hspc-system
```

**Custom output directory**:
```powershell
.\hspclogbundlecollectionscript.ps1 -Dir C:\temp\my-logs
```

**Parallel jobs** (note: PowerShell script uses sequential collection by default for reliability):
```powershell
.\hspclogbundlecollectionscript.ps1 -Jobs 8
```

**Skip compression**:
```powershell
.\hspclogbundlecollectionscript.ps1 -NoCompress
```

**Combined options**:
```powershell
.\hspclogbundlecollectionscript.ps1 -Kubeconfig .\kubeconfig -Oc -Namespace hspc-system -Dir .\logs
```

## Command-Line Options

### Bash Script

| Option | Description | Default |
|--------|-------------|---------|
| `--kubeconfig <file>` | Path to kubeconfig file | Uses `$KUBECONFIG` or default |
| `--oc` | Force use of OpenShift `oc` binary | Auto-detect |
| `-n, --namespace <ns>` | Target namespace | Auto-discover from HSPC CR |
| `-d, --dir <path>` | Output directory | `./hspc-csi-logs-YYYYMMDD-HHMMSS` |
| `-j, --jobs <N>` | Number of parallel jobs | `4` |
| `--no-compress` | Skip zip creation | Creates zip |
| `-h, --help` | Show help message | - |

### PowerShell Script

| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Kubeconfig <file>` | Path to kubeconfig file | Uses default kubeconfig |
| `-Oc` | Force use of OpenShift `oc` binary | Auto-detect |
| `-Namespace <ns>` | Target namespace | Auto-discover from HSPC CR |
| `-Dir <path>` | Output directory | `.\hspc-csi-logs-YYYYMMDD-HHMMSS` |
| `-Jobs <N>` | Number of parallel jobs | `4` (sequential by default) |
| `-NoCompress` | Skip zip creation | Creates zip |

## Output

The script creates a directory (and optionally a zip file) containing:

### Log Files
- `<pod-name>_<container-name>.log` - Logs from each container in each pod
- Logs are limited to 200MB per container to prevent excessive collection times

### Cluster Context File (`cluster-context.txt`)
Contains comprehensive cluster and application information:

1. **Cluster Version**: Kubernetes/OpenShift version details
2. **Platform Detection**: Identifies if running on Kubernetes or OpenShift
3. **Node Information**: OS, kernel, architecture, container runtime for all nodes
4. **HSPC Custom Resource**: Full YAML of HSPC CR configuration
5. **Deployments**: All deployment manifests in the namespace
6. **DaemonSets**: All DaemonSet manifests in the namespace
7. **ReplicaSets**: All ReplicaSet manifests in the namespace
8. **Pod Ownership Chain**: Shows which Deployments/DaemonSets own which pods
9. **Pod Descriptions**: Detailed `kubectl describe` output for each pod
10. **Recent Events**: Last 100 events in the namespace

### Error Tracking
- `errors.log` - Any errors encountered during collection
- `failed-pods.txt` - List of pods/containers that failed to collect

## How It Works

1. **Binary Detection**: Looks for `kubectl` or `oc` in current directory, then PATH
2. **Platform Detection**: Checks for OpenShift-specific API resources
3. **CRD Verification**: Confirms `hspcs.csi.hitachi.com` CRD exists
4. **Namespace Discovery**: Finds namespace containing HSPC custom resources
5. **Pod Discovery**: Identifies all pods using the `hspc-csi-sa` service account
6. **Log Collection**: Collects logs from all containers in each discovered pod
7. **Context Gathering**: Captures cluster state, manifests, and event history
8. **Compression**: Packages everything into a zip file

## Troubleshooting

### "kubectl not found"
- Ensure `kubectl` is in your PATH or place the binary in the script directory
- On Windows, ensure `kubectl.exe` is available

### "CRD hspcs.csi.hitachi.com not found"
- Verify you're connected to the correct cluster
- Check that HSPC CSI driver is installed: `kubectl get crd`
- Verify your kubeconfig has proper authentication

### "No HSPC pods found"
- Check that pods are running: `kubectl get pods -A | grep hspc`
- Verify the service account name matches: `hspc-csi-sa`
- Try specifying the namespace manually with `-n` or `-Namespace`

### Collection is slow
- Use the `-j` option (bash) to increase parallel jobs
- Check network connectivity to the cluster
- Some pods may have very large logs (limited to 200MB per container)

### Permission denied errors
- Ensure your kubeconfig has appropriate RBAC permissions
- You need at least read access to pods, logs, events, and CRDs in the target namespace
- Try running with cluster-admin privileges if available

## Log Viewer

This repository also includes an HTML-based log viewer (`Hitachi-CSI-log-Bundle-Viewer.html`) for easy analysis of collected logs. Simply open the HTML file in a browser and load your log bundle directory.

## Support

For issues, questions, or contributions:
- Open an issue on [GitHub](https://github.com/cmccuistion-hv/Hitachi-CSI-Log-Bundle/issues)
- For Hitachi CSI driver support, contact your Hitachi Vantara representative

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Version History

### v1.2.1 (Current)
- Multi-container support: Collects logs from all containers in each pod
- Enhanced error handling and reporting
- Improved output organization with container names in filenames
- Better cross-platform compatibility

### v1.1
- Full OpenShift auto-detection with smart fallback
- Comprehensive manifest collection (deployments, daemonsets, replicasets)
- Pod ownership chain tracking
- Enhanced cluster context with node OS and runtime information
- Python zip fallback for systems without zip utility
- Parallel collection support (bash version)

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

