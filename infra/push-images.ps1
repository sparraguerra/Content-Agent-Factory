<#
.SYNOPSIS
  Builds all container images from source and pushes them to a target ACR.

.DESCRIPTION
  Uses 'az acr build' to build each service on the ACR's native x86_64
  infrastructure (no local Docker required). Updates the pre-built images
  at the target registry under the 2026-mvp-lab/ repository prefix.

.EXAMPLE
  .\push-images.ps1 acateam
  .\push-images.ps1 acateam.azurecr.io
#>
param(
    [Parameter(Mandatory)][string]$TargetAcr
)

$TargetAcr = $TargetAcr -replace '\.azurecr\.io$', ''
$repo = "2026-mvp-lab"
$root = Join-Path $PSScriptRoot ".."

$services = @(
    @{ Name = "agent-research";  Context = "$root\Lab\src\agent-research";  Dockerfile = "Dockerfile" }
    @{ Name = "agent-creator";   Context = "$root\Lab\src\agent-creator";   Dockerfile = "Dockerfile" }
    @{ Name = "agent-podcaster"; Context = "$root\Lab\src\agent-podcaster"; Dockerfile = "Dockerfile" }
    @{ Name = "dev-ui";          Context = "$root\Lab\src\dev-ui";          Dockerfile = "Dockerfile" }
    @{ Name = "express-dev-ui";  Context = "$root\Lab\src\express-dev-ui";  Dockerfile = "Dockerfile" }
    # @{ Name = "tts-server";      Context = "$root\Lab\src\tts-server";      Dockerfile = "Dockerfile" }
)

Write-Host "Building and pushing images to $TargetAcr.azurecr.io ..." -ForegroundColor Cyan

foreach ($svc in $services) {
    $image = "${repo}/$($svc.Name):latest"
    Write-Host "`n  $($svc.Name) ... " -NoNewline
    az acr build --registry $TargetAcr --image $image --platform linux/amd64 `
        --file "$($svc.Context)\$($svc.Dockerfile)" $svc.Context
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ $($svc.Name) pushed" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $($svc.Name) FAILED" -ForegroundColor Red
    }
}

Write-Host "`nDone. Images available at:" -ForegroundColor Cyan
foreach ($svc in $services) {
    Write-Host "  $TargetAcr.azurecr.io/${repo}/$($svc.Name):latest"
}
