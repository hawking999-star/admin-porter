$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$baselineRoot = Split-Path -Parent $scriptRoot

& (Join-Path $scriptRoot 'verify-unlinked.ps1')

Write-Host 'Iniciando exclusivamente o Supabase local isolado.'
& supabase start --workdir $baselineRoot
if ($LASTEXITCODE -ne 0) {
  throw "supabase start falhou com exit code $LASTEXITCODE."
}
