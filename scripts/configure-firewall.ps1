#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Opens firewall ports required by exo. Run as Administrator.

.PARAMETER ApiPort
    exo API port. Default: 52415

.PARAMETER LibP2PPort
    libp2p TCP port. Default: 4001

.EXAMPLE
    Right-click > Run as Administrator
    powershell -ExecutionPolicy Bypass -File .\configure-firewall.ps1
#>
param(
    [int]$ApiPort    = 52415,
    [int]$LibP2PPort = 4001
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rules = @(
    @{ Name = "exo API";    Port = $ApiPort;    Proto = "TCP"; Desc = "exo dashboard and OpenAI-compatible API" },
    @{ Name = "exo libp2p"; Port = $LibP2PPort; Proto = "TCP"; Desc = "exo peer-to-peer cluster communication" }
)

foreach ($r in $rules) {
    $existing = Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  [OK] Rule '$($r.Name)' already exists — skipping" -ForegroundColor Yellow
    } else {
        New-NetFirewallRule `
            -DisplayName $r.Name `
            -Description $r.Desc `
            -Direction   Inbound `
            -Action      Allow `
            -Protocol    $r.Proto `
            -LocalPort   $r.Port `
            -Profile     Private | Out-Null
        Write-Host "  [+] Created: $($r.Name) ($($r.Proto)/$($r.Port))" -ForegroundColor Green
    }
}

Write-Host "`nFirewall configured. Current exo rules:" -ForegroundColor Cyan
Get-NetFirewallRule | Where-Object { $_.DisplayName -like "exo*" } | ForEach-Object {
    $port = ($_ | Get-NetFirewallPortFilter).LocalPort
    Write-Host "  $($_.DisplayName)  $($_.Direction)  $($_.Action)  port=$port  enabled=$($_.Enabled)"
}
