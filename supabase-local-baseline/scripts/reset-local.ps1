$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$baselineRoot = Split-Path -Parent $scriptRoot

& (Join-Path $scriptRoot 'verify-unlinked.ps1')

Write-Host 'Resetando exclusivamente o banco local isolado.'
& supabase db reset --local --workdir $baselineRoot
if ($LASTEXITCODE -ne 0) {
  throw "supabase db reset local falhou com exit code $LASTEXITCODE."
}
