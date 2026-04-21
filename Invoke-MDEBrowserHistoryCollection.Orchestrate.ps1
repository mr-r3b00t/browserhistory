<#
.SYNOPSIS
    Orchestrates a Live Response browser-history collection against an MDE device,
    chaining RunScript + GetFile so the zip is auto-retrieved.

.DESCRIPTION
    Uses the MDE Live Response API to:
      1. Acquire a bearer token (client-credentials flow).
      2. POST /api/machines/{id}/runliveresponse with a Commands array:
         [ RunScript(Invoke-MDEBrowserHistoryCollection.ps1),
           GetFile(C:\temp\BrowserHistory\browser_history.zip) ]
      3. Poll /api/machineactions/{id} until the action completes.
      4. Download the GetFile result via /api/machineactions/{id}/GetLiveResponseResultDownloadLink.

    Prerequisites (one-time, tenant-admin):
      * Upload Invoke-MDEBrowserHistoryCollection.ps1 to the MDE Live Response
        script library (Endpoints -> Settings -> Live response -> Upload file).
      * Azure AD app registration with API permission
        WindowsDefenderATP/Machine.LiveResponse (Application) - admin consented.
      * AV exclusion for BrowsingHistoryView.exe or its SHA-256, otherwise the
        dropped binary will be quarantined before it runs.

.PARAMETER DeviceId
    MDE device GUID (from the device page URL or Advanced Hunting DeviceInfo table).

.PARAMETER TenantId
    Azure AD tenant GUID.

.PARAMETER ClientId
    App registration (client) ID.

.PARAMETER ClientSecret
    App registration client secret. Prefer passing as a SecureString from a vault;
    plaintext is accepted for interactive use but discouraged in pipelines.

.PARAMETER OutputDir
    Local folder to drop the retrieved zip into. Defaults to .\collected.

.PARAMETER RemoteZipPath
    Path on the endpoint that the collector writes. Must match what the endpoint
    script produces. Default: C:\temp\BrowserHistory\browser_history.zip

.PARAMETER ScriptName
    Filename as uploaded to the Live Response library. Default:
    Invoke-MDEBrowserHistoryCollection.ps1

.EXAMPLE
    .\Invoke-MDEBrowserHistoryCollection.Orchestrate.ps1 `
        -DeviceId '11111111-2222-3333-4444-555555555555' `
        -TenantId $env:MDE_TENANT_ID `
        -ClientId $env:MDE_CLIENT_ID `
        -ClientSecret $env:MDE_CLIENT_SECRET
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DeviceId,
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $ClientSecret,

    [string] $OutputDir     = (Join-Path (Get-Location) 'collected'),
    [string] $RemoteZipPath = 'C:\temp\BrowserHistory\browser_history.zip',
    [string] $ScriptName    = 'Invoke-MDEBrowserHistoryCollection.ps1',
    [string] $Comment       = 'Automated browser history DFIR collection',

    [int]    $PollSeconds   = 15,
    [int]    $TimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ApiBase  = 'https://api.securitycenter.microsoft.com/api'
$Resource = 'https://api.securitycenter.microsoft.com'

# -----------------------------------------------------------------------------
# 1. Token
# -----------------------------------------------------------------------------
Write-Host "[*] Acquiring token for tenant $TenantId..."
$tokenResp = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/token" `
    -Body @{
        resource      = $Resource
        client_id     = $ClientId
        client_secret = $ClientSecret
        grant_type    = 'client_credentials'
    }
$headers = @{
    Authorization = "Bearer $($tokenResp.access_token)"
    'Content-Type' = 'application/json'
}

# -----------------------------------------------------------------------------
# 2. Queue Live Response: RunScript + GetFile in a single action
# -----------------------------------------------------------------------------
$body = @{
    Commands = @(
        @{
            type   = 'RunScript'
            params = @(
                @{ key = 'ScriptName'; value = $ScriptName }
            )
        },
        @{
            type   = 'GetFile'
            params = @(
                @{ key = 'Path'; value = $RemoteZipPath }
            )
        }
    )
    Comment = $Comment
} | ConvertTo-Json -Depth 5

Write-Host "[*] Submitting Live Response action to device $DeviceId..."
try {
    $action = Invoke-RestMethod -Method Post `
        -Uri "$ApiBase/machines/$DeviceId/runliveresponse" `
        -Headers $headers -Body $body
} catch {
    # 429 = existing LR session or concurrent action on this machine.
    Write-Host "[!] Submission failed: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    throw
}

$actionId = $action.id
Write-Host "[+] ActionId: $actionId"

# -----------------------------------------------------------------------------
# 3. Poll until the action finishes
# -----------------------------------------------------------------------------
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
do {
    Start-Sleep -Seconds $PollSeconds
    $status = Invoke-RestMethod -Method Get `
        -Uri "$ApiBase/machineactions/$actionId" -Headers $headers
    Write-Host ("[~] {0,-10} commands={1}" -f $status.status, `
        (($status.commands | ForEach-Object { "$($_.command.type)=$($_.commandStatus)" }) -join ', '))
    if ($status.status -in 'Succeeded','Failed','Cancelled','TimedOut') { break }
} while ((Get-Date) -lt $deadline)

if ($status.status -ne 'Succeeded') {
    throw "Live Response action ended with status '$($status.status)'. See MDE portal for details."
}

# -----------------------------------------------------------------------------
# 4. Download the GetFile result
# -----------------------------------------------------------------------------
$getFileCmd = $status.commands | Where-Object { $_.command.type -eq 'GetFile' } | Select-Object -First 1
if (-not $getFileCmd) { throw "No GetFile command in completed action." }
if ($getFileCmd.commandStatus -ne 'Completed') {
    throw "GetFile step status is '$($getFileCmd.commandStatus)', not Completed."
}

# MDE wraps the collected file in an outer zip (GZIP over the RLR transport).
$linkResp = Invoke-RestMethod -Method Get `
    -Uri "$ApiBase/machineactions/$actionId/GetLiveResponseResultDownloadLink(index=1)" `
    -Headers $headers
$downloadUrl = $linkResp.value

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$localFile = Join-Path $OutputDir ("{0}_{1}_browser_history.gz" -f $DeviceId, (Get-Date -Format 'yyyyMMdd-HHmmss'))

Write-Host "[*] Downloading wrapped payload to $localFile..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $localFile -UseBasicParsing
$size = (Get-Item $localFile).Length

Write-Host ""
Write-Host "=== Done ==="
Write-Host "ActionId  : $actionId"
Write-Host "Local file: $localFile ($size bytes)"
Write-Host ""
Write-Host "The download is MDE's GZIP wrapper containing browser_history.zip."
Write-Host "Extract with:"
Write-Host "    [IO.Compression.GZipStream]::new([IO.File]::OpenRead('$localFile'),'Decompress').CopyTo([IO.File]::Create('$($localFile -replace '\.gz$','.zip')'))"
