#requires -Version 5.1
<#
.SYNOPSIS
  Securely inject the Stripe billing secrets into the in-cluster Secret.

.DESCRIPTION
  The secret/webhook values are typed at MASKED prompts, so they never appear in
  the shell history, on screen, in git, or in any persisted file. They are
  written to the cluster Secret (etcd, RBAC-protected) via a short-lived temp
  patch file that is deleted immediately afterwards.

  RUN THIS ONLY AFTER ROLLING THE KEY IN THE STRIPE DASHBOARD
  (Developers -> API keys -> Roll). Any sk_live_... that was ever pasted into a
  chat / ticket / log must be considered compromised and rolled first.

.EXAMPLE
  ./set-stripe-secrets.ps1
  ./set-stripe-secrets.ps1 -Namespace colorforge -SecretName mycolorforge-secrets
#>
param(
  [string]$Namespace  = "colorforge",
  [string]$SecretName = "mycolorforge-secrets"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Error "kubectl not found in PATH."; exit 1
}

Write-Host "Setting Stripe secrets -> $Namespace/$SecretName" -ForegroundColor Cyan
Write-Host "Secret key + webhook secret are masked. Price IDs are not secret." -ForegroundColor Yellow
Write-Host ""

# --- Sensitive values: single masked prompt (Read-Host -AsSecureString) ------
function Read-Secret([string]$Prompt) {
  $secure = Read-Host -Prompt $Prompt -AsSecureString
  return [System.Net.NetworkCredential]::new('', $secure).Password
}

$sk = Read-Secret 'Paste the Stripe API key (rk_live_... preferred, or sk_live_...)'
$wh = Read-Secret 'Paste the Stripe WEBHOOK SIGNING SECRET (whsec_...)'

# Accept a restricted key (rk_, recommended, least-privilege) or a full secret key (sk_).
if ([string]::IsNullOrWhiteSpace($sk) -or -not ($sk.StartsWith('rk_') -or $sk.StartsWith('sk_'))) {
  Write-Error "API key looks invalid (must start with 'rk_' or 'sk_')."; exit 1
}
if ([string]::IsNullOrWhiteSpace($wh) -or -not $wh.StartsWith('whsec_')) {
  Write-Error "Webhook secret looks invalid (must start with 'whsec_')."; exit 1
}

# --- Non-secret values: plain prompt (Stripe price IDs are public ids) --------
$pmEur = Read-Host 'Price ID monthly EUR (price_...)'
$pmBrl = Read-Host 'Price ID monthly BRL (price_...)  [Enter to skip]'
$paEur = Read-Host 'Price ID annual  EUR (price_...)'
$paBrl = Read-Host 'Price ID annual  BRL (price_...)  [Enter to skip]'

$stringData = @{
  'stripe-secret-key'        = $sk
  'stripe-webhook-secret'    = $wh
  'stripe-price-monthly-eur' = $pmEur
  'stripe-price-annual-eur'  = $paEur
}
if ($pmBrl) { $stringData['stripe-price-monthly-brl'] = $pmBrl }
if ($paBrl) { $stringData['stripe-price-annual-brl']  = $paBrl }

$patch = @{ stringData = $stringData } | ConvertTo-Json -Compress

# Write to a short-lived temp file (avoids quoting issues + arg exposure).
$tmp = Join-Path $env:TEMP ("stripe-patch-{0}.json" -f ([guid]::NewGuid()))
try {
  $patch | Set-Content -Path $tmp -Encoding utf8
  kubectl -n $Namespace patch secret $SecretName --type merge --patch-file $tmp
  if ($LASTEXITCODE -ne 0) { Write-Error "kubectl patch failed."; exit 1 }
  Write-Host "Secret updated. Restarting API to pick up new values..." -ForegroundColor Green
  kubectl -n $Namespace rollout restart deployment/api
} finally {
  if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  # Scrub in-memory copies.
  $sk = $null; $wh = $null; $patch = $null; $stringData = $null
  [System.GC]::Collect()
}

Write-Host ""
Write-Host "Done. Verify: kubectl -n $Namespace get secret $SecretName -o jsonpath='{.data.stripe-secret-key}' | (decode to confirm it is set, do NOT print in shared terminals)." -ForegroundColor Cyan
