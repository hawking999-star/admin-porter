$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$baselineRoot = Split-Path -Parent $scriptRoot
$testsRoot = Join-Path $baselineRoot 'supabase\tests'
$databaseContainer = 'supabase_db_ptm-admin-local-baseline'

& (Join-Path $scriptRoot 'verify-unlinked.ps1')

$tests = @(
  'challenge_rules_reschedule_concurrency.sql',
  'operator_challenge_answer_feedback_v2.sql',
  'operator_display_name_contract.sql',
  'operator_playlist_contract_consolidated.sql'
)

foreach ($test in $tests) {
  $testPath = Join-Path $testsRoot $test
  if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
    throw "Teste local ausente: $test"
  }

  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  Write-Host "Executando $test em transação com rollback."
  Get-Content -Raw -LiteralPath $testPath |
    & docker exec -i $databaseContainer psql -U postgres -d postgres -v ON_ERROR_STOP=1
  if ($LASTEXITCODE -ne 0) {
    throw "$test falhou com exit code $LASTEXITCODE."
  }
  $stopwatch.Stop()
  Write-Host ("PASS {0} ({1:N2}s)" -f $test, $stopwatch.Elapsed.TotalSeconds)
}
