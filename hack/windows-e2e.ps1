<#
.SYNOPSIS
    Standalone Windows E2E for the "manager emits Windows ImageJob pods" change.

.DESCRIPTION
    Upstream has no Windows CI, so this validates the manager change end to end
    on a real AKS Windows node. Unlike the pkg/cri transport spike, this drives
    the actual controller path:

        ImageList (manual job) -> imagejob controller ->
        copyAndFillTemplateSpec (Windows branch) -> a HostProcess pod on the
        Windows node -> remover connects to containerd over the named pipe and
        deletes the requested image.

    The manager and remover images are built from the PR head. The remover pod
    is what this PR shapes: HostProcess securityContext (NT AUTHORITY\SYSTEM),
    hostNetwork, no CRI hostPath mount, Windows shared/imagelist paths, and an
    explicit %CONTAINER_SANDBOX_MOUNT_POINT%\remover.exe command.

    Prerequisites: an AKS cluster with a Linux system pool and a Windows node
    pool, kubectl context set to it, helm, and an attached ACR. Set the env
    vars below to match your environment.

.NOTES
    Env:
      ACR         registry name (e.g. myregistry)
      MANAGER_IMG manager image ref built from PR head
      REMOVER_IMG windows remover image ref built from PR head
      SEED_IMAGE  an unused image to plant on the Windows node and delete
#>

[CmdletBinding()]
param(
    [string]$Namespace   = "eraser-system",
    [string]$WindowsNode = $env:WINDOWS_NODE,
    [string]$ManagerImg  = $env:MANAGER_IMG,
    [string]$RemoverImg  = $env:REMOVER_IMG,
    [string]$SeedImage   = $(if ($env:SEED_IMAGE) { $env:SEED_IMAGE } else { "mcr.microsoft.com/windows/nanoserver:ltsc2022" })
)

$ErrorActionPreference = "Stop"
function Section($t) { Write-Host "`n=== $t ===" }
$helm = if ($env:HELM_BIN) { $env:HELM_BIN } else { "helm" }

try {
    Section "code under test"
    git log -1 --format="%h %s" | Write-Host

    Section "target windows node"
    if (-not $WindowsNode) {
        $WindowsNode = (kubectl get nodes -l kubernetes.io/os=windows -o jsonpath="{.items[0].metadata.name}")
    }
    $img = kubectl get node $WindowsNode -o jsonpath="{.status.nodeInfo.osImage}"
    $rt  = kubectl get node $WindowsNode -o jsonpath="{.status.nodeInfo.containerRuntimeVersion}"
    Write-Host "  node    : $WindowsNode"
    Write-Host "  osImage : $img"
    Write-Host "  runtime : $rt"

    Section "deploy manager from PR head (windows node filter)"
    & $helm upgrade --install eraser charts/eraser --namespace $Namespace --create-namespace `
        --set "deploy.image.repo=$($ManagerImg.Split(':')[0])" `
        --set "deploy.image.tag=$($ManagerImg.Split(':')[-1])" `
        --set "deploy.image.pullPolicy=Always" `
        --set "runtimeConfig.manager.nodeFilter.type=include" `
        --set "runtimeConfig.manager.nodeFilter.selectors={kubernetes.io/os=windows}" `
        --set "runtimeConfig.components.collector.enabled=false" `
        --set "runtimeConfig.components.scanner.enabled=false" `
        --set "runtimeConfig.components.remover.image.repo=$($RemoverImg.Split(':')[0])" `
        --set "runtimeConfig.components.remover.image.tag=$($RemoverImg.Split(':')[-1])" `
        --set "runtimeConfig.manager.imageJob.cleanup.delayOnSuccess=1h" `
        --set "runtimeConfig.manager.imageJob.cleanup.delayOnFailure=1h" | Out-Null
    kubectl rollout restart deploy/eraser-controller-manager -n $Namespace | Out-Null
    kubectl rollout status  deploy/eraser-controller-manager -n $Namespace --timeout=120s | Out-Null
    Write-Host "  manager : $(kubectl get deploy eraser-controller-manager -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].image}')"

    Section "seed an unused image on the windows node"
    kubectl delete pod winseed -n $Namespace --ignore-not-found | Out-Null
    $seedManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: winseed
  namespace: $Namespace
spec:
  nodeName: $WindowsNode
  restartPolicy: Never
  containers:
  - name: seed
    image: $SeedImage
    command: ["cmd.exe","/c","ver"]
"@
    $seedManifest | kubectl apply -f - | Out-Null
    kubectl wait --for=jsonpath="{.status.phase}"=Succeeded pod/winseed -n $Namespace --timeout=180s | Out-Null
    kubectl delete pod winseed -n $Namespace --ignore-not-found | Out-Null
    # Let containerd garbage-collect the exited seed container so the image is
    # no longer referenced; otherwise the remover correctly skips it as in-use.
    Write-Host "  seeded  : $SeedImage (waiting for the exited container to be reclaimed)"
    Start-Sleep 40

    Section "trigger an ImageList job for the seeded image"
    kubectl delete imagelist imagelist -n $Namespace --ignore-not-found | Out-Null
    $il = @"
apiVersion: eraser.sh/v1
kind: ImageList
metadata:
  name: imagelist
spec:
  images:
    - $SeedImage
"@
    $il | kubectl apply -f - | Out-Null

    Section "wait for the Windows HostProcess remover pod"
    $pod = $null
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep 10
        $pod = kubectl get pods -n $Namespace -l eraser.sh/type=manual `
            --field-selector spec.nodeName=$WindowsNode -o jsonpath="{.items[0].metadata.name}" 2>$null
        if ($pod) {
            $phase = kubectl get pod $pod -n $Namespace -o jsonpath="{.status.phase}" 2>$null
            if ($phase -eq "Succeeded" -or $phase -eq "Failed") { break }
        }
    }
    if (-not $pod) { throw "no remover pod was scheduled onto $WindowsNode" }

    Section "emitted pod shape (what this PR produces)"
    Write-Host "  hostNetwork    : $(kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.hostNetwork}')"
    Write-Host "  os.name        : $(kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.os.name}')"
    Write-Host "  hostProcess    : $(kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.securityContext.windowsOptions.hostProcess}')"
    Write-Host "  runAsUserName  : $(kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.securityContext.windowsOptions.runAsUserName}')"
    Write-Host "  command        : $(kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.containers[0].command[0]}')"
    Write-Host "  imagelist arg  : $(kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.containers[0].args[0]}')"
    Write-Host "  has CRI mount  : $((kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.volumes[*].name}') -match 'runtime-sock-volume')"

    Section "remover result over the named pipe"
    $phase = kubectl get pod $pod -n $Namespace -o jsonpath="{.status.phase}"
    $exit  = kubectl get pod $pod -n $Namespace -o jsonpath="{.status.containerStatuses[0].state.terminated.exitCode}"
    kubectl logs $pod -n $Namespace 2>$null | Write-Host
    Write-Host "  pod phase : $phase (exit $exit)"

    Section "result"
    if ($phase -eq "Succeeded" -and $exit -eq "0") {
        Write-Host "RESULT: PASS"
    } else {
        Write-Host "RESULT: FAIL"
        exit 1
    }
}
finally {
    kubectl delete imagelist imagelist -n $Namespace --ignore-not-found | Out-Null
    kubectl delete pod winseed -n $Namespace --ignore-not-found | Out-Null
}
