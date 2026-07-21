param(
  [Parameter(Mandatory = $true)]
  [string]$SnapshotPath
)

$ErrorActionPreference = 'Stop'

$expectedSnapshotHash = '04B39BF486C7AFB6380A6845C31A18F1B1BCF74FEFA14910A53B8A7A55B2B97F'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$baselineRoot = Split-Path -Parent $scriptRoot
$repoRoot = Split-Path -Parent $baselineRoot
$migrationPath = Join-Path $baselineRoot 'supabase\migrations\20260716145224_production_schema_baseline.sql'
$sourceMigrations = Join-Path $repoRoot 'supabase\migrations'

if (-not (Test-Path -LiteralPath $SnapshotPath -PathType Leaf)) {
  throw "Snapshot não encontrado: $SnapshotPath"
}

$actualSnapshotHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SnapshotPath).Hash
if ($actualSnapshotHash -ne $expectedSnapshotHash) {
  throw "Hash do snapshot divergente. Esperado $expectedSnapshotHash; recebido $actualSnapshotHash."
}

function Get-PrivateFunctionDefinitions {
  param(
    [Parameter(Mandatory = $true)]
    [string]$MigrationFile,
    [Parameter(Mandatory = $true)]
    [string]$FunctionName
  )

  $path = Join-Path $sourceMigrations $MigrationFile
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Migration-fonte ausente: $MigrationFile"
  }

  $content = Get-Content -Raw -LiteralPath $path
  $escapedName = [regex]::Escape($FunctionName)
  $startPattern = "(?im)^[ \t]*create[ \t]+(?:or[ \t]+replace[ \t]+)?function[ \t]+(?:private\.|`"private`"\.`")?`"?$escapedName`"?[ \t]*\("
  $matches = [regex]::Matches($content, $startPattern)
  if ($matches.Count -eq 0) {
    throw "Função private.$FunctionName não encontrada em $MigrationFile"
  }

  $blocks = New-Object System.Collections.Generic.List[string]
  foreach ($match in $matches) {
    $bodyStart = [regex]::Match(
      $content.Substring($match.Index),
      '(?is)\bAS\s+(\$[A-Za-z0-9_]*\$)'
    )
    if (-not $bodyStart.Success) {
      throw "Delimitador do corpo de private.$FunctionName não encontrado em $MigrationFile"
    }

    $tag = $bodyStart.Groups[1].Value
    $absoluteBodyStart = $match.Index + $bodyStart.Index
    $firstTagIndex = $content.IndexOf($tag, $absoluteBodyStart, [System.StringComparison]::Ordinal)
    $closingTagIndex = $content.IndexOf(
      $tag,
      $firstTagIndex + $tag.Length,
      [System.StringComparison]::Ordinal
    )
    if ($closingTagIndex -lt 0) {
      throw "Fim do corpo de private.$FunctionName não encontrado em $MigrationFile"
    }

    $semicolonIndex = $content.IndexOf(
      ';',
      $closingTagIndex + $tag.Length,
      [System.StringComparison]::Ordinal
    )
    if ($semicolonIndex -lt 0) {
      throw "Fim da definição de private.$FunctionName não encontrado em $MigrationFile"
    }

    $blocks.Add($content.Substring($match.Index, $semicolonIndex - $match.Index + 1).Trim())
  }

  return $blocks
}

$privateSources = [ordered]@{
  'app_release_required_ready'           = '20260707013008_app_release_contract_hardening.sql'
  'capture_admin_display_name_change'    = '20260714175906_operator_display_name_moderation.sql'
  'challenge_answer_definition_is_valid' = '20260714233203_operator_challenge_answer_feedback_v2_contract.sql'
  'challenge_payload'                    = '20260714233203_operator_challenge_answer_feedback_v2_contract.sql'
  'challenge_rules'                      = '20260714120000_challenge_runtime_contract.sql'
  'challenge_schedule_at'                = '20260714150000_add_challenge_daily_window.sql'
  'current_operator_challenge'           = '20260714180000_harden_challenge_idle_session_isolation.sql'
  'defer_challenge_after_call'            = '20260714130000_align_challenge_rule_timings.sql'
  'enforce_principal_track_limit'         = '20260710093540_secure_operator_playlist_management.sql'
  'enforce_track_duration_limit'          = '20260710093540_secure_operator_playlist_management.sql'
  'log_app_release_audit'                 = '20260706202732_app_release_approval_flow.sql'
  'normalize_operator_display_name'       = '20260714175906_operator_display_name_moderation.sql'
  'operator_playlist_capabilities'        = '20260710095019_complete_operator_playlist_contract_v2.sql'
  'operator_runtime_payload'              = '20260708014906_local_call_operational_events.sql'
  'require_admin_for_backend'             = '20260708015001_admin_backend_hardening.sql'
  'require_available_track_link'          = '20260710095019_complete_operator_playlist_contract_v2.sql'
  'require_release_admin'                 = '20260706202732_app_release_approval_flow.sql'
  'set_challenge_operator_state'          = '20260714170000_fix_challenge_idle_and_response_window.sql'
  'statistics_reset_at'                   = '20260714190000_statistics_reset_and_challenge_leaderboard.sql'
  'try_uuid'                              = '20260710095019_complete_operator_playlist_contract_v2.sql'
}

$snapshot = Get-Content -Raw -LiteralPath $SnapshotPath

if (
  [regex]::IsMatch($snapshot, '(?im)^[ \t]*COPY[ \t]+.+[ \t]+FROM[ \t]+stdin;') -or
  [regex]::IsMatch($snapshot, '(?im)^[ \t]*INSERT[ \t]+INTO[ \t]+"[^"]+"\."[^"]+"[ \t]+VALUES\b')
) {
  throw 'O snapshot contém bloco de dados do pg_dump; a baseline não será gerada.'
}

if ([regex]::IsMatch($snapshot, '(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}')) {
  throw 'O snapshot contém endereço de e-mail; revise antes de continuar.'
}

$sanitized = [regex]::Replace(
  $snapshot,
  '(?im)^[ \t]*ALTER[ \t]+[^\r\n]+[ \t]+OWNER[ \t]+TO[ \t]+[^\r\n]+;[ \t]*\r?\n?',
  ''
)

$privateDefinitions = New-Object System.Collections.Generic.List[string]
foreach ($entry in $privateSources.GetEnumerator()) {
  foreach ($definition in (Get-PrivateFunctionDefinitions -MigrationFile $entry.Value -FunctionName $entry.Key)) {
    $privateDefinitions.Add($definition)
  }
}

$privateSection = @"

-- Private functions referenced by the authoritative public-schema snapshot.
-- Their final definitions are sourced from the deployed local migration history.
$($privateDefinitions -join "`r`n`r`n")

REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE ALL ON SCHEMA private FROM anon, authenticated;

"@

$triggerMarker = 'CREATE OR REPLACE TRIGGER'
$triggerIndex = $sanitized.IndexOf($triggerMarker, [System.StringComparison]::OrdinalIgnoreCase)
if ($triggerIndex -lt 0) {
  throw 'Ponto de inserção anterior aos triggers não encontrado.'
}

$sanitized = $sanitized.Insert($triggerIndex, $privateSection)

$setup = @"
-- PTM Admin local-only compacted Supabase baseline.
-- Source: production public-schema snapshot captured 2026-07-16.
-- Source SHA-256: $expectedSnapshotHash
-- Supabase CLI used for the snapshot: 2.107.0
-- Deployment commit base: d28246d5a68572f00883650777e411d458869afe
-- Deliberate sanitization: ownership commands removed; required extensions and
-- private dependencies reconstructed from the final local migration contracts.
-- This migration contains schema only and must never be linked or pushed remotely.

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE ALL ON SCHEMA private FROM anon, authenticated;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA extensions;

"@

$baseline = $setup + $sanitized

if ([regex]::IsMatch($baseline, '(?im)^[ \t]*ALTER[ \t]+[^\r\n]+[ \t]+OWNER[ \t]+TO\b')) {
  throw 'A baseline sanitizada ainda contém comando OWNER.'
}

if (
  [regex]::IsMatch($baseline, '(?im)^[ \t]*COPY[ \t]+.+[ \t]+FROM[ \t]+stdin;') -or
  [regex]::IsMatch($baseline, '(?im)^[ \t]*INSERT[ \t]+INTO[ \t]+"[^"]+"\."[^"]+"[ \t]+VALUES\b')
) {
  throw 'A baseline sanitizada contém bloco de dados do pg_dump.'
}

$requiredPrivateNames = $privateSources.Keys
foreach ($name in $requiredPrivateNames) {
  if (-not [regex]::IsMatch($baseline, "(?i)function[ \t]+(?:private\.|`"private`"\.`")?`"?$([regex]::Escape($name))`"?[ \t]*\(")) {
    throw "A baseline não contém a definição esperada de private.$name."
  }
}

$operatorBlocksPattern = '(?is)CREATE TABLE IF NOT EXISTS "public"\."operator_blocks"\s*\((.*?)\);'
$operatorBlocksMatch = [regex]::Match($baseline, $operatorBlocksPattern)
if (-not $operatorBlocksMatch.Success) {
  throw 'Tabela public.operator_blocks não encontrada.'
}

$operatorBlocksDefinition = $operatorBlocksMatch.Groups[1].Value
foreach ($forbiddenColumn in @('"metadata"', '"ended_at"')) {
  if ($operatorBlocksDefinition.Contains($forbiddenColumn)) {
    throw "Contrato inválido de operator_blocks: coluna proibida $forbiddenColumn."
  }
}
foreach ($requiredColumn in @(
  '"id"', '"operator_id"', '"session_id"', '"challenge_log_id"', '"reason_code"',
  '"status"', '"started_at"', '"blocked_until"', '"finished_at"', '"revoked_at"',
  '"revoked_by"', '"revision"'
)) {
  if (-not $operatorBlocksDefinition.Contains($requiredColumn)) {
    throw "Contrato inválido de operator_blocks: coluna ausente $requiredColumn."
  }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($migrationPath, $baseline, $utf8NoBom)

$baselineHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $migrationPath).Hash
Write-Host "Baseline local gerada: $migrationPath"
Write-Host "SHA-256: $baselineHash"
