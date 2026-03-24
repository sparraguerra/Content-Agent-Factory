<#
.SYNOPSIS
    Deploy the Agentic Content Factory to Azure Container Apps.
    Designed for repeatable deployment to 50+ environments.
.PARAMETER ResourceGroup
    Target resource group name (will be created if missing).
.PARAMETER Location
    Azure region (default: eastus2).
.PARAMETER BaseName
    Prefix for all resource names. Must be lowercase alphanumeric + hyphens.
.PARAMETER AzureOpenAiEndpoint
    Azure OpenAI endpoint URL (optional -- Foundry account is created either way).
.PARAMETER AzureOpenAiApiKey
    Azure OpenAI API key (optional).
.PARAMETER AzureOpenAiDeployment
    Azure OpenAI model deployment name (default: gpt-4o).
.EXAMPLE
    .\deploy.ps1 -ResourceGroup rg-mvp-lab-001 -BaseName mvplab001
    .\deploy.ps1 -ResourceGroup rg-mvp-lab-002 -BaseName mvplab002 -AzureOpenAiEndpoint "https://..." -AzureOpenAiApiKey "sk-..."
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [string]$Location = "eastus2",
    [Parameter(Mandatory)][string]$BaseName,
    [string]$AzureOpenAiEndpoint = "",
    [string]$AzureOpenAiApiKey = "",
    [string]$AzureOpenAiDeployment = "gpt-5"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$InfraDir = $PSScriptRoot
$LabDir = Join-Path $RepoRoot "Lab"

# Common Bicep parameters (reused for both deploys)
$bicepParams = @(
    "baseName=$BaseName",
    "azureOpenAiEndpoint=$AzureOpenAiEndpoint",
    "azureOpenAiDeployment=$AzureOpenAiDeployment"
)

# ── Step 1: Resource group ──
Write-Host "`n=== Step 1: Create resource group ($ResourceGroup) ===" -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none

# ── Step 2: Deploy infrastructure ──
Write-Host "`n=== Step 2: Deploy infrastructure (Foundry + App Insights + ACR + ACA) ===" -ForegroundColor Cyan
$deployArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroup,
    "--template-file", "$InfraDir\main.bicep",
    "--query", "properties.outputs",
    "-o", "json"
)
foreach ($p in $bicepParams) { $deployArgs += "--parameters"; $deployArgs += $p }
if ($AzureOpenAiApiKey) { $deployArgs += "--parameters"; $deployArgs += "azureOpenAiApiKey=$AzureOpenAiApiKey" }

$deployment = & az @deployArgs | ConvertFrom-Json
if (!$deployment) { throw "Infrastructure deployment failed" }

$acrServer = $deployment.acrLoginServer.value
$acrName = $acrServer -replace '\.azurecr\.io',''
Write-Host "  ACR:           $acrServer"
Write-Host "  ACA Env:       $BaseName-env"
Write-Host "  App Insights:  $BaseName-appinsights"
Write-Host "  Foundry:       $BaseName-foundry"

# ── Step 3: Ensure OTEL telemetry is wired (belt-and-suspenders) ──
Write-Host "`n=== Step 3: Verify OTEL collector -> App Insights ===" -ForegroundColor Cyan
$appInsightsConnStr = $deployment.appInsightsConnectionString.value
az containerapp env telemetry app-insights set `
    --name "$BaseName-env" `
    --resource-group $ResourceGroup `
    --connection-string $appInsightsConnStr `
    --enable-open-telemetry-traces true `
    --enable-open-telemetry-logs true `
    --output none 2>$null
Write-Host "  OTEL traces + logs -> App Insights: enabled"

# ── Step 4: Build container images (ACR cloud build) ──
Write-Host "`n=== Step 4: Build and push container images ===" -ForegroundColor Cyan

Write-Host "  Building agent-research..."
az acr build --registry $acrName --image agent-research:latest "$LabDir\src\agent-research"

Write-Host "  Building agent-creator..."
az acr build --registry $acrName --image agent-creator:latest --file "$LabDir\src\agent-creator\Dockerfile" "$LabDir\src\agent-creator"

Write-Host "  Building dev-ui..."
az acr build --registry $acrName --image dev-ui:latest "$LabDir\src\dev-ui"

# ── Step 5: Redeploy containers with built images ──
Write-Host "`n=== Step 5: Redeploy container apps with new images ===" -ForegroundColor Cyan
$redeployArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroup,
    "--template-file", "$InfraDir\main.bicep",
    "--output", "none"
)
foreach ($p in $bicepParams) { $redeployArgs += "--parameters"; $redeployArgs += $p }
if ($AzureOpenAiApiKey) { $redeployArgs += "--parameters"; $redeployArgs += "azureOpenAiApiKey=$AzureOpenAiApiKey" }

& az @redeployArgs
if ($LASTEXITCODE -ne 0) { throw "Container app deployment failed" }

# ── Summary ──
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Deployment complete: $BaseName" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "  Endpoints:" -ForegroundColor White
Write-Host "    Agent 1 (Research): $($deployment.agentResearchUrl.value)"
Write-Host "    Agent 2 (Creator):  $($deployment.agentCreatorUrl.value)"
Write-Host "    Dev UI:             $($deployment.devUiUrl.value)"
Write-Host ""
Write-Host "  Observability:" -ForegroundColor White
Write-Host "    App Insights:       $BaseName-appinsights"
Write-Host "    OTEL Agent IDs:     research-agent, content-creator-agent"
Write-Host ""
Write-Host "  Foundry:" -ForegroundColor White
Write-Host "    Endpoint:           $($deployment.foundryEndpoint.value)"
Write-Host "    Project:            $($deployment.foundryProjectName.value)"
Write-Host ""
Write-Host "  A2A Agent Cards:" -ForegroundColor White
Write-Host "    $($deployment.agentResearchUrl.value)/.well-known/agent.json"
Write-Host "    $($deployment.agentCreatorUrl.value)/.well-known/agent.json"
Write-Host ""
