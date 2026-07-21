$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$baselineRoot = Split-Path -Parent $scriptRoot

& (Join-Path $scriptRoot 'verify-unlinked.ps1')

Write-Host 'Parando exclusivamente o Supabase local isolado.'
& supabase stop --workdir $baselineRoot
if ($LASTEXITCODE -ne 0) {
  throw "supabase stop local falhou com exit code $LASTEXITCODE."
}
