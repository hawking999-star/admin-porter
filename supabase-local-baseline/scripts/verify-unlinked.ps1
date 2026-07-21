$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$baselineRoot = Split-Path -Parent $scriptRoot
$supabaseRoot = Join-Path $baselineRoot 'supabase'
$configPath = Join-Path $supabaseRoot 'config.toml'
$tempPath = Join-Path $supabaseRoot '.temp'

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
  throw "Configuração local isolada não encontrada: $configPath"
}

$resolvedBaseline = (Resolve-Path -LiteralPath $baselineRoot).Path
$resolvedSupabase = (Resolve-Path -LiteralPath $supabaseRoot).Path
if (-not $resolvedSupabase.StartsWith($resolvedBaseline, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw 'O workdir Supabase saiu do diretório isolado.'
}

$config = Get-Content -Raw -LiteralPath $configPath
if ($config -notmatch 'project_id\s*=\s*"ptm-admin-local-baseline"') {
  throw 'project_id local divergente ou ausente.'
}

if ($config -match '(?i)https?://[^"''\s]+\.supabase\.co') {
  throw 'URL de Supabase remoto encontrada na configuração local.'
}

$remoteMarkers = @(
  'project-ref',
  'linked-project.json',
  'pooler-url'
)
foreach ($marker in $remoteMarkers) {
  $path = Join-Path $tempPath $marker
  if (Test-Path -LiteralPath $path) {
    throw "Marcador de vínculo remoto encontrado: $path"
  }
}

$forbiddenFragments = @(
  ('-' + '-linked'),
  ('db ' + 'push'),
  ('db ' + 'pull'),
  ('migration ' + 'repair')
)

$scriptFiles = Get-ChildItem -LiteralPath $scriptRoot -Filter '*.ps1' -File
foreach ($file in $scriptFiles) {
  $content = Get-Content -Raw -LiteralPath $file.FullName
  foreach ($fragment in $forbiddenFragments) {
    if ($content.IndexOf($fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
      throw "Comando ou flag proibida encontrada em $($file.Name)."
    }
  }
  if ($content -match '(?i)https?://[^"''\s]+\.supabase\.co') {
    throw "URL remota encontrada em $($file.Name)."
  }
}

Write-Host 'Verificação concluída: workdir local isolado, sem marcadores de vínculo remoto.'
