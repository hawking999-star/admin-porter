$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$baselineRoot = Split-Path -Parent $scriptRoot

& (Join-Path $scriptRoot 'verify-unlinked.ps1')

Write-Host 'Executando lint exclusivamente no schema public local isolado.'
& supabase db lint --local --schema public --workdir $baselineRoot
if ($LASTEXITCODE -ne 0) {
  throw "supabase db lint local falhou com exit code $LASTEXITCODE."
}
