#requires -Version 5.1
<#
.SYNOPSIS
  memrotate: mantiene un fichero de memoria "vigente" con los ultimos N dias
  y archiva lo anterior en salvas mensuales comprimidas (.md.gz) consultables.

.MODES
  init    Prepara el proyecto (fichero vigente, carpeta de salvas, bloque en CLAUDE.md)
  auto    Lo usa el hook SessionStart: rota como maximo una vez al dia y devuelve contexto
  now     Fuerza una rotacion
  status  Muestra configuracion y estado
  set     Cambia la configuracion del proyecto (-Days, -Transcripts on|off)
  list    Muestra el indice de salvas
  search  Busca texto en las salvas y en el fichero vigente (-Query)
  read    Imprime una salva completa (-Month AAAA-MM)
  stop    Lo usa el hook Stop: si se ha trabajado sin tocar la memoria, pide a Claude que guarde lo aprendido
  remember  Anade una entrada con la fecha de hoy (-Text "..." o por stdin; -Pin para fijarla)
  doctor  Diagnostico de la instalacion y del proyecto
  backup  Copia la memoria (vigente, salvas y Auto Memory) a un repo git y/o a una carpeta (Google Drive...)
          -Quiet: solo si hubo cambios y sin salida (lo usan los hooks)
  restore Recupera la memoria desde la copia, sin sobrescribir lo que ya existe (-From <clave> si hay varias)

.PINNED
  Las entradas marcadas con [pin] nunca rotan:  - [AAAA-MM-DD] [pin] texto   o   - [pin] texto
#>
[CmdletBinding()]
param(
  [ValidateSet('init', 'auto', 'now', 'status', 'set', 'list', 'search', 'read', 'stop', 'remember', 'doctor', 'backup', 'restore')]
  [string]$Mode = 'status',
  [int]$Days = 0,
  [string]$Transcripts = '',
  [string]$Reminder = '',
  [int]$ReminderTools = 0,
  [string]$Query = '',
  [string]$Text = '',
  [switch]$Pin,
  [string]$BackupGit = '',
  [string]$BackupDir = '',
  [int]$BackupEvery = -1,
  [string]$From = '',
  [switch]$Quiet,
  [string]$Month = '',
  [string]$ProjectDir = '',
  # Carpeta de datos del plugin (${CLAUDE_PLUGIN_DATA}). El hook guarda ahi las opciones de /config
  # para que las ejecuciones desde la skill (que no reciben CLAUDE_PLUGIN_OPTION_*) las lean.
  [string]$DataDir = '',
  # Compatibilidad: valores pasados a mano. Se ignoran si llegan sin sustituir (contienen '${' o '$').
  [string]$DefaultDays = '',
  [string]$DefaultTranscripts = '',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8 } catch { }
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$EntryRegex = '^\s*[-*]\s*\[(\d{4}-\d{2}-\d{2})\]'
$PinRegex = '^\s*[-*]\s*(\[\d{4}-\d{2}-\d{2}\]\s*)?\[pin\]'
$PrefixRegex = '^\s*([-*]\s*)?(\[\d{4}-\d{2}-\d{2}\]\s*)?(\[pin\]\s*)?'
$BulletRegex = '^\s*[-*]\s+\S'
$Tag = '[memrotate]'

# ---------------------------------------------------------------- helpers

function Test-Truthy([string]$v) { return ($v -match '^(?i)(true|1|yes|on|si)$') }
function Test-Falsy([string]$v) { return ($v -match '^(?i)(false|0|no|off)$') }

function Get-ProjectRoot {
  if ($ProjectDir) { return (Resolve-Path -LiteralPath $ProjectDir).Path }
  if ($env:CLAUDE_PROJECT_DIR) { return $env:CLAUDE_PROJECT_DIR }
  return (Get-Location).Path
}

function Read-Text([string]$path) { return [IO.File]::ReadAllText($path, $Utf8) }

function Write-Text([string]$path, [string]$text) {
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = "$path.tmp"
  [IO.File]::WriteAllText($tmp, $text, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Read-Gz([string]$path) {
  $fs = [IO.File]::OpenRead($path)
  try {
    $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object IO.StreamReader($gz, $Utf8)
    try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
  } finally { $fs.Dispose() }
}

function Write-Gz([string]$path, [string]$text) {
  $tmp = "$path.tmp"
  $fs = [IO.File]::Create($tmp)
  try {
    $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionLevel]::Optimal)
    $bytes = $Utf8.GetBytes($text)
    $gz.Write($bytes, 0, $bytes.Length)
    $gz.Dispose()
  } finally { $fs.Dispose() }
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Split-Lines([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return @() }
  return ($text -replace "`r`n", "`n").TrimEnd("`n").Split("`n")
}

function Test-Pinned([string]$line) { return [regex]::IsMatch($line, $PinRegex, [Text.RegularExpressions.RegexOptions]::IgnoreCase) }

# JSON determinista e igual en PowerShell 5.1 y 7 (ConvertTo-Json cambia el formato y escapa ' como \u0027).
# Solo objetos planos: cadenas, numeros, booleanos y null. Mismo formato que json.dumps de Python.
function ConvertTo-JsonString([string]$v) {
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $v.ToCharArray()) {
    switch ($ch) {
      '"' { [void]$sb.Append('\"') }
      '\' { [void]$sb.Append('\\') }
      "`n" { [void]$sb.Append('\n') }
      "`r" { [void]$sb.Append('\r') }
      "`t" { [void]$sb.Append('\t') }
      "`b" { [void]$sb.Append('\b') }
      "`f" { [void]$sb.Append('\f') }
      default {
        if ([int]$ch -lt 0x20) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) } else { [void]$sb.Append($ch) }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function ConvertTo-FlatJson($obj, [switch]$Compress) {
  $parts = @()
  foreach ($k in $obj.Keys) {
    $v = $obj[$k]
    if ($null -eq $v) { $js = 'null' }
    elseif ($v -is [bool]) { $js = $(if ($v) { 'true' } else { 'false' }) }
    elseif ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal]) { $js = ([string]::Format($Invariant, '{0}', $v)) }
    else { $js = ConvertTo-JsonString ([string]$v) }
    if ($Compress) { $parts += ((ConvertTo-JsonString $k) + ':' + $js) } else { $parts += ('  ' + (ConvertTo-JsonString $k) + ': ' + $js) }
  }
  if ($Compress) { return '{' + ($parts -join ',') + '}' }
  if ($parts.Count -eq 0) { return '{}' }
  return "{`n" + ($parts -join ",`n") + "`n}"
}

function Get-EntryDate([string]$line) {
  $m = [regex]::Match($line, $EntryRegex)
  if (-not $m.Success) { return $null }
  $d = [datetime]::MinValue
  if ([datetime]::TryParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $Invariant, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
  return $null
}

# ---------------------------------------------------------------- configuracion

# Un valor es util solo si Claude Code lo sustituyo (no quedan restos de plantilla)
function Test-Substituted([string]$v) { return ($v -and $v -notmatch '\$|\{|\}') }

function Get-PluginDataDir {
  if ($env:CLAUDE_PLUGIN_DATA) { return $env:CLAUDE_PLUGIN_DATA }
  if (Test-Substituted $DataDir) { return $DataDir }
  return $null
}

function Get-Config([string]$root) {
  $cfg = [ordered]@{
    retentionDays      = 30
    memoryFile         = 'notes/MEMORY-current.md'
    archiveDir         = 'notes/archive'
    archiveTranscripts = $false
    saveReminder       = $true
    reminderEveryTools = 15
    backupGit          = ''
    backupDir          = ''
    backupIntervalHours = 0
    source             = 'defaults'
  }
  # 1) Valores globales del plugin (userConfig).
  #    a) En hooks llegan como variables de entorno -> se cachean en la carpeta de datos del plugin.
  #    b) Desde la skill no llegan -> se leen de esa cache.
  $envDays = $env:CLAUDE_PLUGIN_OPTION_RETENTION_DAYS
  $envTr = $env:CLAUDE_PLUGIN_OPTION_ARCHIVE_TRANSCRIPTS
  $envRem = $env:CLAUDE_PLUGIN_OPTION_SAVE_REMINDER
  $envBGit = $env:CLAUDE_PLUGIN_OPTION_BACKUP_GIT
  $envBDir = $env:CLAUDE_PLUGIN_OPTION_BACKUP_DIR
  $envBInt = $env:CLAUDE_PLUGIN_OPTION_BACKUP_INTERVAL_HOURS
  $dataDir = Get-PluginDataDir
  $cache = $null
  if ($dataDir) { $cache = Join-Path $dataDir 'options.json' }
  if (($envDays -or $envTr -or $envRem -or $envBGit -or $envBDir -or $envBInt) -and $cache) {
    try {
      Write-Text $cache ((ConvertTo-FlatJson ([ordered]@{ retention_days = "$envDays"; archive_transcripts = "$envTr"; save_reminder = "$envRem"; backup_git = "$envBGit"; backup_dir = "$envBDir"; backup_interval_hours = "$envBInt"; savedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', $Invariant) })) + "`n")
    } catch { }
  }
  if ($cache -and (Test-Path -LiteralPath $cache) -and -not ($envDays -and $envTr -and $envRem)) {
    try {
      $c = (Read-Text $cache) | ConvertFrom-Json
      if (-not $envDays) { $envDays = [string]$c.retention_days }
      if (-not $envTr) { $envTr = [string]$c.archive_transcripts }
      if (-not $envRem) { $envRem = [string]$c.save_reminder }
      if (-not $envBGit) { $envBGit = [string]$c.backup_git }
      if (-not $envBDir) { $envBDir = [string]$c.backup_dir }
      if (-not $envBInt) { $envBInt = [string]$c.backup_interval_hours }
    } catch { }
  }
  if (-not $envDays -and (Test-Substituted $DefaultDays)) { $envDays = $DefaultDays }
  if (-not $envTr -and (Test-Substituted $DefaultTranscripts)) { $envTr = $DefaultTranscripts }
  $n = 0
  if ($envDays -or $envTr -or $envRem) { $cfg.source = 'plugin options (/config)' }
  if ($envDays -and [int]::TryParse(([string]$envDays).Split('.')[0], [ref]$n) -and $n -gt 0) { $cfg.retentionDays = $n }
  if ($envTr) { if (Test-Truthy $envTr) { $cfg.archiveTranscripts = $true } elseif (Test-Falsy $envTr) { $cfg.archiveTranscripts = $false } }
  if ($envRem) { if (Test-Truthy $envRem) { $cfg.saveReminder = $true } elseif (Test-Falsy $envRem) { $cfg.saveReminder = $false } }
  if (Test-Substituted $envBGit) { $cfg.backupGit = $envBGit }
  if (Test-Substituted $envBDir) { $cfg.backupDir = $envBDir }
  $bi = 0
  if ($envBInt -and [int]::TryParse(([string]$envBInt).Split('.')[0], [ref]$bi) -and $bi -ge 0) { $cfg.backupIntervalHours = $bi }

  # 2) Configuracion del proyecto (.claude/memrotate.json) tiene prioridad
  $p = Get-ProjectConfigPath $root
  if ($p) {
    $cfg.source = (Split-Path -Leaf $p)
    $j = (Read-Text $p) | ConvertFrom-Json
    foreach ($k in @('retentionDays', 'memoryFile', 'archiveDir', 'archiveTranscripts', 'saveReminder', 'reminderEveryTools', 'backupGit', 'backupDir', 'backupIntervalHours')) {
      if ($j.PSObject.Properties.Name -contains $k -and $null -ne $j.$k) { $cfg[$k] = $j.$k }
    }
  }
  $cfg.retentionDays = [int]$cfg.retentionDays
  $cfg.archiveTranscripts = [bool]$cfg.archiveTranscripts
  $cfg.saveReminder = [bool]$cfg.saveReminder
  $cfg.reminderEveryTools = [math]::Max(1, [int]$cfg.reminderEveryTools)
  $cfg.backupIntervalHours = [math]::Max(0, [int]$cfg.backupIntervalHours)
  foreach ($k in @('backupGit', 'backupDir')) {
    $v = ([string]$cfg[$k]).Trim()
    if (Test-Falsy $v) { $v = '' }
    $cfg[$k] = $v
  }
  return $cfg
}

# Fichero de configuracion del proyecto. Admite el nombre antiguo (memory-rotate, hasta 0.2.x).
function Get-ProjectConfigPath([string]$root) {
  foreach ($n in @('.claude/memrotate.json', '.claude/memory-rotate.json')) {
    $p = Join-Path $root $n
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Save-ProjectConfig([string]$root, $changes) {
  $p = Join-Path $root '.claude/memrotate.json'
  $legacy = Join-Path $root '.claude/memory-rotate.json'
  $obj = [ordered]@{}
  $src = Get-ProjectConfigPath $root
  if ($src) {
    $j = (Read-Text $src) | ConvertFrom-Json
    foreach ($prop in $j.PSObject.Properties) { $obj[$prop.Name] = $prop.Value }
  }
  foreach ($k in $changes.Keys) { $obj[$k] = $changes[$k] }
  # Claves ordenadas alfabeticamente: mismo fichero en Windows, Linux y macOS
  $sorted = [ordered]@{}
  $keys = [string[]]@($obj.Keys)
  [Array]::Sort($keys, [StringComparer]::Ordinal)
  foreach ($k in $keys) { $sorted[$k] = $obj[$k] }
  Write-Text $p ((ConvertTo-FlatJson $sorted) + "`n")
  # Migracion: el fichero antiguo ya esta copiado en el nuevo
  if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Force }
}

function Get-StatePath($root, $cfg) { return Join-Path (Join-Path $root $cfg.archiveDir) '.state.json' }

function Get-State($root, $cfg) {
  $p = Get-StatePath $root $cfg
  if (Test-Path -LiteralPath $p) { try { return (Read-Text $p) | ConvertFrom-Json } catch { } }
  return $null
}

function Save-State($root, $cfg, $result) {
  $state = [ordered]@{
    lastRun       = (Get-Date).ToString('yyyy-MM-dd', $Invariant)
    lastRunAt     = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Invariant)
    lastMoved     = $result.moved
    lastTrMoved   = $result.transcripts
    retentionDays = $cfg.retentionDays
  }
  Write-Text (Get-StatePath $root $cfg) ((ConvertTo-FlatJson $state) + "`n")
}

# ---------------------------------------------------------------- rotacion de memoria

function Invoke-MemoryRotation($root, $cfg) {
  $mem = Join-Path $root $cfg.memoryFile
  $arch = Join-Path $root $cfg.archiveDir
  $cutoff = (Get-Date).Date.AddDays( - $cfg.retentionDays)
  $result = @{ moved = 0; months = @() }
  if (-not (Test-Path -LiteralPath $mem)) { return $result }

  $lines = Split-Lines (Read-Text $mem)
  $keep = New-Object System.Collections.Generic.List[string]
  $moved = @{}
  $lastKey = $null
  foreach ($l in $lines) {
    if (Test-Pinned $l) { $lastKey = $null; $keep.Add($l); continue }
    $d = Get-EntryDate $l
    if ($null -ne $d) {
      if ($d -lt $cutoff) {
        $lastKey = $d.ToString('yyyy-MM', $Invariant)
        if (-not $moved.ContainsKey($lastKey)) { $moved[$lastKey] = New-Object System.Collections.Generic.List[string] }
        $moved[$lastKey].Add($l)
        $result.moved++
        continue
      }
      $lastKey = $null
      $keep.Add($l); continue
    }
    # Lineas de continuacion (indentadas) viajan con su entrada
    if ($lastKey -and $l -match '^\s{2,}\S' -and $l -notmatch '^\s*[-*]\s') { $moved[$lastKey].Add($l); continue }
    $lastKey = $null
    $keep.Add($l)
  }
  if ($result.moved -eq 0 -or $DryRun) { $result.months = @($moved.Keys | Sort-Object); return $result }

  if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
  # 1) Primero se escriben las salvas (si algo falla, el vigente queda intacto)
  foreach ($key in ($moved.Keys | Sort-Object)) {
    $gzPath = Join-Path $arch "MEMORY-$key.md.gz"
    $existing = @()
    if (Test-Path -LiteralPath $gzPath) { $existing = Split-Lines (Read-Gz $gzPath) }
    else { $existing = @("# Archived memory - $key", '') }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $existing) { [void]$seen.Add($e) }
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange([string[]]$existing)
    foreach ($m in $moved[$key]) { if ($seen.Add($m) -or $m -match '^\s{2,}\S') { $out.Add($m) } }
    Write-Gz $gzPath (($out -join "`n") + "`n")
  }
  # 2) Despues se reescribe el vigente solo con lo reciente
  Write-Text $mem (($keep -join "`n") + "`n")
  $result.months = @($moved.Keys | Sort-Object)
  return $result
}

# ---------------------------------------------------------------- transcripts (opcional)

function Get-ClaudeConfigDir {
  if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
  $h = $env:USERPROFILE
  if (-not $h) { $h = $HOME }
  return Join-Path $h '.claude'
}

function Get-TranscriptDir([string]$root) {
  $projects = Join-Path (Get-ClaudeConfigDir) 'projects'
  if (-not (Test-Path -LiteralPath $projects)) { return $null }
  $encoded = ($root -replace '[^A-Za-z0-9]', '-')
  $candidate = Join-Path $projects $encoded
  if (Test-Path -LiteralPath $candidate) { return $candidate }
  $match = Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ieq $encoded } | Select-Object -First 1
  if ($match) { return $match.FullName }
  return $null
}

function Get-CleanupPeriodDays {
  $p = Join-Path (Get-ClaudeConfigDir) 'settings.json'
  if (Test-Path -LiteralPath $p) {
    try {
      $j = (Read-Text $p) | ConvertFrom-Json
      if ($j.PSObject.Properties.Name -contains 'cleanupPeriodDays') { return [int]$j.cleanupPeriodDays }
    } catch { }
  }
  return 30
}

function Invoke-TranscriptArchive($root, $cfg) {
  $count = 0
  if (-not $cfg.archiveTranscripts) { return $count }
  $dir = Get-TranscriptDir $root
  if (-not $dir) { return $count }
  $cutoff = (Get-Date).Date.AddDays( - $cfg.retentionDays)
  $old = Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $cutoff }
  if (-not $old -or $DryRun) { return @($old).Count }

  Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
  $arch = Join-Path $root $cfg.archiveDir
  if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }

  foreach ($group in ($old | Group-Object { $_.LastWriteTime.ToString('yyyy-MM', $Invariant) })) {
    $zipPath = Join-Path $arch "transcripts-$($group.Name).zip"
    $zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Update)
    $archived = @()
    try {
      $names = @{}
      foreach ($e in $zip.Entries) { $names[$e.FullName] = $true }
      foreach ($f in $group.Group) {
        if (-not $names.ContainsKey($f.Name)) {
          [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $f.Name, [IO.Compression.CompressionLevel]::Optimal)
        }
        $archived += $f
      }
    } finally { $zip.Dispose() }
    # Solo se elimina el original cuando ya esta dentro del zip
    $check = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
      $inZip = @{}
      foreach ($e in $check.Entries) { $inZip[$e.FullName] = $true }
      foreach ($f in $archived) { if ($inZip.ContainsKey($f.Name)) { Remove-Item -LiteralPath $f.FullName -Force; $count++ } }
    } finally { $check.Dispose() }
  }
  return $count
}

# ---------------------------------------------------------------- indice

function Update-Index($root, $cfg) {
  $arch = Join-Path $root $cfg.archiveDir
  if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# Archived memory index')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("Current file: ``$($cfg.memoryFile)`` (last $($cfg.retentionDays) days).")
  [void]$sb.AppendLine("Updated: $((Get-Date).ToString('yyyy-MM-dd HH:mm', $Invariant))")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('| Archive | Period | Entries |')
  [void]$sb.AppendLine('|---|---|---|')
  $files = Get-ChildItem -LiteralPath $arch -Filter 'MEMORY-*.md.gz' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending
  foreach ($f in $files) {
    $dates = @(Split-Lines (Read-Gz $f.FullName) | ForEach-Object { Get-EntryDate $_ } | Where-Object { $null -ne $_ } | Sort-Object)
    $period = '-'
    if ($dates.Count -gt 0) { $period = "$($dates[0].ToString('yyyy-MM-dd', $Invariant)) to $($dates[-1].ToString('yyyy-MM-dd', $Invariant))" }
    [void]$sb.AppendLine("| $($f.Name) | $period | $($dates.Count) |")
  }
  if (-not $files) { [void]$sb.AppendLine('| (no archives yet) | - | 0 |') }
  $zips = Get-ChildItem -LiteralPath $arch -Filter 'transcripts-*.zip' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending
  if ($zips) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Archived transcripts')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| File | Sessions |')
    [void]$sb.AppendLine('|---|---|')
    foreach ($z in $zips) {
      $za = [IO.Compression.ZipFile]::OpenRead($z.FullName)
      try { $n = $za.Entries.Count } finally { $za.Dispose() }
      [void]$sb.AppendLine("| $($z.Name) | $n |")
    }
  }
  # Saltos de linea LF en todos los sistemas; solo se reescribe si cambia algo mas que 'Updated:'
  $text = $sb.ToString().Replace("`r`n", "`n")
  $idx = Join-Path $arch 'INDEX.md'
  $strip = { param($t) [regex]::Replace(([string]$t).Replace("`r`n", "`n"), '(?m)^Updated: .*$', '') }
  if ((Test-Path -LiteralPath $idx) -and ((& $strip (Read-Text $idx)) -ceq (& $strip $text))) { return }
  Write-Text $idx $text
}

# ---------------------------------------------------------------- init

function Get-GitignoreLines($cfg) { return @("$($cfg.archiveDir)/.state.json", "$($cfg.archiveDir)/.sessions/", "$($cfg.archiveDir)/.backup.json") }

$ClaudeMdStart = '<!-- memrotate:start -->'
$ClaudeMdEnd = '<!-- memrotate:end -->'
# Marcadores del nombre antiguo (memory-rotate, hasta 0.2.x): init los sustituye por los nuevos
$LegacyMdStart = '<!-- memory-rotate:start -->'
$LegacyMdEnd = '<!-- memory-rotate:end -->'

function Invoke-Init($root, $cfg) {
  $mem = Join-Path $root $cfg.memoryFile
  $created = @()
  if (-not (Test-Path -LiteralPath $mem)) {
    $header = @(
      '# Project memory',
      '',
      '<!-- memrotate: one entry per line, always dated. Format: - [YYYY-MM-DD] text -->',
      '<!-- Entries older than the retention period are moved automatically to the archive folder. -->',
      '<!-- Pinned entries never rotate. Format: - [YYYY-MM-DD] [pin] text -->',
      ''
    ) -join "`n"
    Write-Text $mem ($header + "`n")
    $created += $cfg.memoryFile
  }
  Update-Index $root $cfg
  $created += "$($cfg.archiveDir)/INDEX.md"

  $claudeMd = Join-Path $root 'CLAUDE.md'
  $block = @(
    $ClaudeMdStart,
    '## Project memory (memrotate)',
    '',
    "@$($cfg.memoryFile)",
    '',
    "- The current memory file is ``$($cfg.memoryFile)``, loaded above. It only holds recent entries.",
    '- When you learn something durable (a decision, finding, configuration or solved problem), append it to the END of that file as one line `- [YYYY-MM-DD] text` with today''s date. One idea per line.',
    '- If the fact stays true long-term (architecture, hostnames, ports, credentials locations, conventions), pin it so it never rotates: `- [YYYY-MM-DD] [pin] text`. Use [pin] sparingly; time-bound notes must not be pinned.',
    '- Do not rewrite or delete existing entries; if something changes, append a new entry that corrects it. If a pinned fact becomes false, remove its [pin] marker and append the correction.',
    "- Older entries are archived, compressed, in ``$($cfg.archiveDir)/``. If something is not in the current file, use the ``memrotate:archive`` skill.",
    $ClaudeMdEnd
  ) -join "`n"
  if (Test-Path -LiteralPath $claudeMd) {
    $txt = Read-Text $claudeMd
    $legacyPattern = [regex]::Escape($LegacyMdStart) + '[\s\S]*?' + [regex]::Escape($LegacyMdEnd)
    if ($txt.Contains($LegacyMdStart) -and -not $txt.Contains($ClaudeMdStart)) {
      $txt = [regex]::Replace($txt, $legacyPattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block })
    } elseif ($txt.Contains($ClaudeMdStart)) {
      $pattern = [regex]::Escape($ClaudeMdStart) + '[\s\S]*?' + [regex]::Escape($ClaudeMdEnd)
      $txt = [regex]::Replace($txt, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $block })
      if ($txt.Contains($LegacyMdStart)) { $txt = [regex]::Replace($txt, '\n*' + $legacyPattern, '') }
    } else {
      $txt = $txt.TrimEnd() + "`n`n" + $block + "`n"
    }
    Write-Text $claudeMd $txt
  } else {
    Write-Text $claudeMd ($block + "`n")
    $created += 'CLAUDE.md'
  }

  # Ignorar ficheros temporales del plugin en git, si hay .gitignore
  $gi = Join-Path $root '.gitignore'
  if (Test-Path -LiteralPath $gi) {
    $g = Read-Text $gi
    foreach ($line in (Get-GitignoreLines $cfg)) {
      if (-not $g.Contains($line)) { $g = $g.TrimEnd() + "`n" + $line + "`n" }
    }
    Write-Text $gi $g
  }
  return $created
}

# ---------------------------------------------------------------- salida

function Get-EntryCount($root, $cfg) {
  $mem = Join-Path $root $cfg.memoryFile
  if (-not (Test-Path -LiteralPath $mem)) { return 0 }
  return @(Split-Lines (Read-Text $mem) | Where-Object { ($null -ne (Get-EntryDate $_)) -or (Test-Pinned $_) }).Count
}

function Get-PinnedCount($root, $cfg) {
  $mem = Join-Path $root $cfg.memoryFile
  if (-not (Test-Path -LiteralPath $mem)) { return 0 }
  return @(Split-Lines (Read-Text $mem) | Where-Object { Test-Pinned $_ }).Count
}

# ---------------------------------------------------------------- copia de seguridad

function Get-BytesHash([byte[]]$bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

function Get-ProjectKey([string]$root) {
  # Carpeta del proyecto en la copia: nombre + huella corta de la ruta (evita choques entre repos)
  $slash = ($root -replace '\\', '/').TrimEnd('/')
  $norm = $slash.ToLowerInvariant()
  $leaf = $slash.Substring($slash.LastIndexOf('/') + 1)
  $name = [regex]::Replace($leaf, '[^A-Za-z0-9._-]', '-')
  if (-not $name) { $name = 'project' }
  $sha1 = [Security.Cryptography.SHA1]::Create()
  try { $hex = [BitConverter]::ToString($sha1.ComputeHash($Utf8.GetBytes($norm))).Replace('-', '').ToLowerInvariant() } finally { $sha1.Dispose() }
  return "$name-$($hex.Substring(0, 8))"
}

function Get-AutoMemoryDir([string]$root) {
  $td = Get-TranscriptDir $root
  if ($td) { return (Join-Path $td 'memory') }
  return (Join-Path (Join-Path (Join-Path (Get-ClaudeConfigDir) 'projects') ($root -replace '[^A-Za-z0-9]', '-')) 'memory')
}

function Sort-Ordinal([string[]]$items) {
  $arr = [string[]]@($items)
  [Array]::Sort($arr, [StringComparer]::Ordinal)
  return , $arr
}

function Get-BackupFiles($root, $cfg) {
  # Lista de @{ Src; Rel } de todo lo que se copia, ordenada por Rel
  $map = @{}
  $mem = Join-Path $root $cfg.memoryFile
  if (Test-Path -LiteralPath $mem -PathType Leaf) { $map['memrotate/' + (Split-Path -Leaf $mem)] = $mem }
  $arch = Join-Path $root $cfg.archiveDir
  if (Test-Path -LiteralPath $arch -PathType Container) {
    foreach ($f in (Get-ChildItem -LiteralPath $arch -File)) {
      if ($f.Name -ceq 'INDEX.md' -or $f.Name -match '^MEMORY-.*\.md\.gz$') { $map['memrotate/archive/' + $f.Name] = $f.FullName }
    }
  }
  $am = Get-AutoMemoryDir $root
  if (Test-Path -LiteralPath $am -PathType Container) {
    $amFull = (Get-Item -LiteralPath $am).FullName.TrimEnd('\', '/')
    foreach ($f in (Get-ChildItem -LiteralPath $am -File -Recurse)) {
      $rel = $f.FullName.Substring($amFull.Length + 1) -replace '\\', '/'
      $map['auto-memory/' + $rel] = $f.FullName
    }
  }
  $out = @()
  foreach ($rel in (Sort-Ordinal @($map.Keys))) { if ($rel) { $out += [pscustomobject]@{ Src = $map[$rel]; Rel = $rel } } }
  return , $out
}

function Get-Fingerprint($files) {
  $ms = New-Object IO.MemoryStream
  try {
    foreach ($f in $files) {
      $b = $Utf8.GetBytes($f.Rel); $ms.Write($b, 0, $b.Length); $ms.WriteByte(0)
      $d = [IO.File]::ReadAllBytes($f.Src); $ms.Write($d, 0, $d.Length); $ms.WriteByte(0)
    }
    return (Get-BytesHash $ms.ToArray())
  } finally { $ms.Dispose() }
}

function Get-BackupStatePath($root, $cfg) { return Join-Path (Join-Path $root $cfg.archiveDir) '.backup.json' }

function Test-SameContent([string]$a, [string]$b) {
  if (-not (Test-Path -LiteralPath $a -PathType Leaf) -or -not (Test-Path -LiteralPath $b -PathType Leaf)) { return $false }
  if ((Get-Item -LiteralPath $a).Length -ne (Get-Item -LiteralPath $b).Length) { return $false }
  return (Get-BytesHash ([IO.File]::ReadAllBytes($a))) -eq (Get-BytesHash ([IO.File]::ReadAllBytes($b)))
}

function Copy-BackupFiles($files, [string]$dest) {
  # Copia solo lo que cambia. Nunca borra nada en el destino. Devuelve cuantos ficheros escribio.
  $changed = 0
  foreach ($f in $files) {
    $target = $dest
    foreach ($part in $f.Rel.Split('/')) { $target = Join-Path $target $part }
    if (Test-SameContent $f.Src $target) { continue }
    $dir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$target.tmp"
    [IO.File]::WriteAllBytes($tmp, [IO.File]::ReadAllBytes($f.Src))
    Move-Item -LiteralPath $tmp -Destination $target -Force
    $changed++
  }
  return $changed
}

function Write-Manifest([string]$dest, [string]$root, [int]$count) {
  $m = [ordered]@{ project = $root; host = [System.Net.Dns]::GetHostName(); files = $count; updated = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Invariant) }
  Write-Text (Join-Path $dest 'backup.json') ((ConvertTo-FlatJson $m) + "`n")
}

function ConvertTo-ArgString([string[]]$items) {
  $parts = foreach ($a in $items) {
    if ($a -eq '') { '""' }
    elseif ($a -notmatch '[\s"]') { $a }
    else { '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
  }
  return ($parts -join ' ')
}

function Invoke-Git([string]$repo, [string[]]$gitArgs, [int]$timeoutSec = 120) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ConvertTo-ArgString (@('-C', $repo) + $gitArgs)
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $Utf8
  $psi.StandardErrorEncoding = $Utf8
  $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  try { [void]$p.Start() } catch { return @{ Code = 127; Out = 'git not found' } }
  $errTask = $p.StandardError.ReadToEndAsync()
  $stdout = $p.StandardOutput.ReadToEnd()
  if (-not $p.WaitForExit($timeoutSec * 1000)) { try { $p.Kill() } catch { }; return @{ Code = 124; Out = 'timeout' } }
  $p.WaitForExit()
  return @{ Code = $p.ExitCode; Out = ($stdout + $errTask.Result).Trim() }
}

function Get-FirstLine([string]$text) {
  foreach ($l in (Split-Lines $text)) { if ($l.Trim()) { return $l.Trim() } }
  return 'unknown error'
}

function Test-GitReady([string]$repo) {
  if (-not (Test-Path -LiteralPath $repo -PathType Container)) { return 'folder does not exist' }
  $r = Invoke-Git $repo @('rev-parse', '--is-inside-work-tree')
  if ($r.Code -ne 0 -or $r.Out -ne 'true') { return 'not a git repository (clone your private backup repo there)' }
  return $null
}

function Test-GitUpstream([string]$repo) { return (Invoke-Git $repo @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')).Code -eq 0 }

function Invoke-BackupGit([string]$repo, [string]$key, $files, [string]$root) {
  $err = Test-GitReady $repo
  if ($err) { return @('fail', $err) }
  $upstream = Test-GitUpstream $repo
  if ($upstream) { [void](Invoke-Git $repo @('pull', '--rebase', '--autostash', '-q')) }
  $dest = Join-Path $repo $key
  $n = Copy-BackupFiles $files $dest
  if ($n -or -not (Test-Path -LiteralPath (Join-Path $dest 'backup.json'))) { Write-Manifest $dest $root $files.Count }
  [void](Invoke-Git $repo @('add', '-A', '--', $key))
  if ((Invoke-Git $repo @('diff', '--cached', '--quiet', '--', $key)).Code -eq 0) { return @('ok', 'up to date') }
  $msg = "memrotate: $key ($([System.Net.Dns]::GetHostName())) $((Get-Date).ToString('yyyy-MM-dd HH:mm', $Invariant))"
  $r = Invoke-Git $repo @('commit', '-q', '-m', $msg, '--', $key)
  if ($r.Code -ne 0) { return @('fail', "commit failed: $(Get-FirstLine $r.Out)") }
  if (-not $upstream) { return @('warn', 'committed, but the branch has no remote to push to') }
  $r = Invoke-Git $repo @('push', '-q')
  if ($r.Code -ne 0) { return @('warn', "committed, push failed: $(Get-FirstLine $r.Out)") }
  return @('ok', 'committed and pushed')
}

function Invoke-BackupDir([string]$folder, [string]$key, $files, [string]$root) {
  if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return @('fail', 'folder does not exist') }
  $dest = Join-Path $folder $key
  $n = Copy-BackupFiles $files $dest
  if ($n -or -not (Test-Path -LiteralPath (Join-Path $dest 'backup.json'))) { Write-Manifest $dest $root $files.Count }
  if ($n) { return @('ok', "$n files updated") }
  return @('ok', 'up to date')
}

function Get-BackupTargets($cfg) {
  $t = @()
  if ($cfg.backupGit) { $t += , @('git', $cfg.backupGit) }
  if ($cfg.backupDir) { $t += , @('folder', $cfg.backupDir) }
  return , $t
}

function Read-JsonFile([string]$path) {
  if (Test-Path -LiteralPath $path) { try { return ((Read-Text $path) | ConvertFrom-Json) } catch { } }
  return $null
}

function Invoke-Backup($root, $cfg) {
  $targets = Get-BackupTargets $cfg
  if ($targets.Count -eq 0) {
    if (-not $Quiet) { "$Tag backup: no destination configured. Set it in /config (memrotate options) or run /memrotate:rotate backup git <path> | backup folder <path>" }
    return
  }
  if (-not (Test-Path -LiteralPath (Join-Path $root $cfg.memoryFile))) {
    if (-not $Quiet) { "$Tag not initialized in this project. Run first: /memrotate:rotate init" }
    return
  }
  $files = Get-BackupFiles $root $cfg
  $fp = Get-Fingerprint $files
  $sp = Get-BackupStatePath $root $cfg
  $state = Read-JsonFile $sp
  $sig = ($targets | ForEach-Object { "$($_[0])=$($_[1])" }) -join '|'
  if ($Quiet -and $state -and [string]$state.fingerprint -eq $fp -and [string]$state.targets -eq $sig -and $state.ok) { return }
  # Intervalo de sincronizacion: en automatico, como mucho una copia cada N horas
  if ($Quiet -and $cfg.backupIntervalHours -gt 0 -and $state -and $state.ok -and [string]$state.targets -eq $sig) {
    $last = [datetime]::MinValue
    if ([datetime]::TryParseExact([string]$state.lastBackup, 'yyyy-MM-dd HH:mm', $Invariant, [Globalization.DateTimeStyles]::None, [ref]$last)) {
      if (((Get-Date) - $last).TotalHours -lt $cfg.backupIntervalHours) { return }
    }
  }
  $key = Get-ProjectKey $root
  $lines = @("$Tag backup: $($files.Count) files from $root -> $key")
  $allOk = $true
  foreach ($t in $targets) {
    try {
      if ($t[0] -eq 'git') { $res = Invoke-BackupGit $t[1] $key $files $root } else { $res = Invoke-BackupDir $t[1] $key $files $root }
    } catch { $res = @('fail', $_.Exception.Message) }
    if ($res[0] -ne 'ok') { $allOk = $false }
    $lines += ('  {0,-6} {1} {2}: {3}' -f "[$($res[0])]", $t[0], $t[1], $res[1])
  }
  Write-Text $sp ((ConvertTo-FlatJson ([ordered]@{ fingerprint = $fp; targets = $sig; ok = $allOk; lastBackup = (Get-Date).ToString('yyyy-MM-dd HH:mm', $Invariant) })) + "`n")
  if ($Quiet) {
    if (-not $allOk) { [Console]::Error.WriteLine(($lines -join "`n")) }
  } else { $lines }
}

function Get-BackupList([string]$base) {
  $res = @()
  if (Test-Path -LiteralPath $base -PathType Container) {
    $names = @(Get-ChildItem -LiteralPath $base -Directory | ForEach-Object { $_.Name })
    foreach ($n in (Sort-Ordinal $names)) {
      if (-not $n) { continue }
      $mf = Join-Path (Join-Path $base $n) 'backup.json'
      if (Test-Path -LiteralPath $mf -PathType Leaf) { $res += , @($n, (Read-JsonFile $mf)) }
    }
  }
  return , $res
}

function Invoke-Restore($root, $cfg) {
  $targets = Get-BackupTargets $cfg
  if ($targets.Count -eq 0) { throw 'no backup destination configured. Set it in /config (memrotate options) or with /memrotate:rotate backup git <path> | backup folder <path>' }
  $key = Get-ProjectKey $root
  $baseName = $key.Substring(0, $key.LastIndexOf('-'))
  $source = $null; $chosen = $null; $available = @()
  foreach ($t in $targets) {
    if ($t[0] -eq 'git' -and -not (Test-GitReady $t[1]) -and (Test-GitUpstream $t[1])) { [void](Invoke-Git $t[1] @('pull', '--rebase', '--autostash', '-q')) }
    $backups = Get-BackupList $t[1]
    foreach ($b in $backups) { $available += , @($t[0], $t[1], $b[0], $b[1]) }
    $names = @($backups | ForEach-Object { $_[0] })
    if ($From) {
      if ($names -ccontains $From) { $source = $t; $chosen = $From; break }
      continue
    }
    if ($names -ccontains $key) { $source = $t; $chosen = $key; break }
    $similar = @($names | Where-Object { $_.Substring(0, $_.LastIndexOf('-')) -ceq $baseName })
    if ($similar.Count -eq 1) { $source = $t; $chosen = $similar[0]; break }
  }
  if (-not $source) {
    $suffix = ''
    if ($From) { $suffix = " (-From $From)" }
    $lines = @("$Tag restore: no backup found for $key$suffix")
    if ($available.Count -gt 0) {
      $lines += '  available backups (use /memrotate:rotate restore <key>):'
      foreach ($a in $available) {
        $u = '?'; $pr = '?'
        if ($a[3]) { if ($a[3].updated) { $u = $a[3].updated }; if ($a[3].project) { $pr = $a[3].project } }
        $lines += "    $($a[2])  ($($a[0]), $u, from $pr)"
      }
    }
    return $lines
  }

  $srcDir = Join-Path $source[1] $chosen
  $meta = Read-JsonFile (Join-Path $srcDir 'backup.json')
  $srcFull = (Get-Item -LiteralPath $srcDir).FullName.TrimEnd('\', '/')
  $map = @{}
  foreach ($f in (Get-ChildItem -LiteralPath $srcDir -File -Recurse)) {
    $rel = $f.FullName.Substring($srcFull.Length + 1) -replace '\\', '/'
    $dst = $null
    if ($rel.StartsWith('memrotate/archive/')) { $dst = Join-Path (Join-Path $root $cfg.archiveDir) $rel.Substring('memrotate/archive/'.Length) }
    elseif ($rel.StartsWith('memrotate/')) { $dst = Join-Path $root $cfg.memoryFile }
    elseif ($rel.StartsWith('auto-memory/')) {
      $dst = Get-AutoMemoryDir $root
      foreach ($part in $rel.Substring('auto-memory/'.Length).Split('/')) { $dst = Join-Path $dst $part }
    }
    if ($dst) { $map[$rel] = @($f.FullName, $dst) }
  }
  $restored = @(); $kept = 0
  foreach ($rel in (Sort-Ordinal @($map.Keys))) {
    if (-not $rel) { continue }
    $src = $map[$rel][0]; $dst = $map[$rel][1]
    if (Test-Path -LiteralPath $dst) {
      if (-not (Test-SameContent $dst $src)) { $kept++ }
      continue
    }
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst
    $restored += $rel
  }
  if (Test-Path -LiteralPath (Join-Path $root $cfg.memoryFile)) {
    $cmd = Join-Path $root 'CLAUDE.md'
    if (-not ((Test-Path -LiteralPath $cmd) -and (Read-Text $cmd).Contains($ClaudeMdStart))) {
      [void](Invoke-Init $root $cfg)
      $restored += 'CLAUDE.md block'
    }
    Update-Index $root $cfg
  }
  $u = '?'; $h = '?'
  if ($meta) { if ($meta.updated) { $u = $meta.updated }; if ($meta.host) { $h = $meta.host } }
  $lines = @("$Tag restore from $($source[0]) $($source[1]): $chosen (backup of $u from $h)")
  foreach ($r in $restored) { $lines += "  + $r" }
  if ($kept) { $lines += "  = $kept files differ locally: kept the local version" }
  if ($restored.Count -eq 0 -and -not $kept) { $lines += '  nothing to restore: everything is already here' }
  return $lines
}

function Get-BackupSummary($root, $cfg) {
  $t = @()
  if ($cfg.backupGit) { $t += "git $($cfg.backupGit)" }
  if ($cfg.backupDir) { $t += "folder $($cfg.backupDir)" }
  if ($t.Count -eq 0) { return 'off' }
  $last = 'never'
  $st = Read-JsonFile (Get-BackupStatePath $root $cfg)
  if ($st -and $st.lastBackup) { $last = [string]$st.lastBackup }
  $every = 'every session with changes'
  if ($cfg.backupIntervalHours) { $every = "every $($cfg.backupIntervalHours) h" }
  return "$($t -join ', '), $every (last $last)"
}

# ---------------------------------------------------------------- stdin (hooks y remember)

function Read-StdinText {
  try {
    if ([Console]::IsInputRedirected) {
      try { [Console]::InputEncoding = $Utf8 } catch { }
      return [Console]::In.ReadToEnd()
    }
  } catch { }
  return ''
}

function Read-HookInput {
  # En Windows sin Git Bash, el hook lee stdin en PowerShell y lo pasa en esta variable
  # (en Windows PowerShell 5.1, $input llega vacio con -Command y la tuberia cambia la codificacion)
  $raw = $env:MEMROTATE_HOOK_INPUT
  if (-not $raw) { $raw = Read-StdinText }
  if ($raw -and $raw.Trim()) { try { return ($raw | ConvertFrom-Json) } catch { } }
  return $null
}

# ---------------------------------------------------------------- remember

function Get-EntryBody([string]$line) { return ([regex]::Replace($line, $PrefixRegex, '', [Text.RegularExpressions.RegexOptions]::IgnoreCase)).Trim() }

function Invoke-Remember($root, $cfg) {
  $raw = $Text
  if (-not $raw) { $raw = Read-StdinText }
  $pinIt = [bool]$Pin
  $body = ([regex]::Replace([string]$raw, '\s+', ' ')).Trim()
  if ([regex]::IsMatch($body, '^\s*([-*]\s*)?(\[\d{4}-\d{2}-\d{2}\]\s*)?\[pin\]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $pinIt = $true }
  $body = Get-EntryBody $body
  if (-not $body) { throw 'Nothing to remember. Use -Text "..." or pass the text on stdin.' }

  $mem = Join-Path $root $cfg.memoryFile
  $notes = @()
  if (-not (Test-Path -LiteralPath $mem)) {
    [void](Invoke-Init $root $cfg)
    $notes += "$Tag initialized in $root"
  }
  foreach ($l in (Split-Lines (Read-Text $mem))) {
    if (($null -ne (Get-EntryDate $l) -or (Test-Pinned $l)) -and (Get-EntryBody $l) -ieq $body) {
      $notes += "$Tag already in memory: $($l.Trim())"
      return $notes
    }
  }
  $line = "- [$((Get-Date).ToString('yyyy-MM-dd', $Invariant))] "
  if ($pinIt) { $line += '[pin] ' }
  $line += $body
  $txt = Read-Text $mem
  if ($txt.Length -gt 0 -and -not $txt.EndsWith("`n")) { $txt += "`n" }
  Write-Text $mem ($txt + $line + "`n")
  $notes += "$Tag saved to $($cfg.memoryFile): $line"
  return $notes
}

# ---------------------------------------------------------------- doctor

function Get-PluginVersion {
  $pj = Join-Path (Split-Path -Parent $PSScriptRoot) '.claude-plugin/plugin.json'
  try { return ((Read-Text $pj) | ConvertFrom-Json).version } catch { return 'unknown' }
}

function Invoke-Doctor($root, $cfg) {
  $script:errors = 0; $script:warns = 0
  $lines = New-Object System.Collections.Generic.List[string]
  function Add-Check([string]$level, [string]$msg) {
    if ($level -eq 'fail') { $script:errors++ } elseif ($level -eq 'warn') { $script:warns++ }
    $lines.Add(('  {0,-6} {1}' -f "[$level]", $msg))
  }
  $lines.Add("$Tag doctor")
  Add-Check 'ok' "plugin $(Get-PluginVersion) (rotate.ps1, PowerShell $($PSVersionTable.PSVersion.ToString()))"
  Add-Check 'ok' "project: $root"
  Add-Check 'ok' "settings: $($cfg.source) (retention $($cfg.retentionDays) days)"
  if (Test-Path -LiteralPath (Join-Path $root '.claude/memory-rotate.json')) {
    Add-Check 'warn' 'old settings file .claude/memory-rotate.json: it is migrated on the next /memrotate:rotate days|transcripts|reminder'
  }

  $mem = Join-Path $root $cfg.memoryFile
  if (-not (Test-Path -LiteralPath $mem)) {
    Add-Check 'fail' 'not initialized in this project: run /memrotate:rotate init'
  } else {
    $size = (Get-Item -LiteralPath $mem).Length
    $memLines = @(Split-Lines (Read-Text $mem))
    $entries = @($memLines | Where-Object { ($null -ne (Get-EntryDate $_)) -or (Test-Pinned $_) }).Count
    $pinned = @($memLines | Where-Object { Test-Pinned $_ }).Count
    $undated = @($memLines | Where-Object { ($_ -match $BulletRegex) -and ($null -eq (Get-EntryDate $_)) -and -not (Test-Pinned $_) }).Count
    Add-Check 'ok' "current file: $($cfg.memoryFile) ($entries entries, $pinned pinned, $([math]::Round($size / 1KB, 1)) KB)"
    if ($size -gt 40KB) { Add-Check 'warn' "current file is $([math]::Round($size / 1KB, 0)) KB and is loaded in every session: lower the retention or unpin entries" }
    if ($undated -gt 0) { Add-Check 'warn' "$undated bullet lines without a date never rotate (format: - [YYYY-MM-DD] text)" }
    if ($pinned -gt 30) { Add-Check 'warn' "$pinned pinned entries: pinned entries never rotate, review if all still matter" }

    $cmd = Join-Path $root 'CLAUDE.md'
    $cmdTxt = ''
    if (Test-Path -LiteralPath $cmd) { $cmdTxt = Read-Text $cmd }
    if ($cmdTxt.Contains($ClaudeMdStart)) {
      if ($cmdTxt.Contains("@$($cfg.memoryFile)")) { Add-Check 'ok' "CLAUDE.md loads $($cfg.memoryFile)" }
      else { Add-Check 'warn' "CLAUDE.md block does not load $($cfg.memoryFile): run /memrotate:rotate init" }
    } elseif ($cmdTxt.Contains($LegacyMdStart)) {
      Add-Check 'warn' 'CLAUDE.md has the old memory-rotate block: restart Claude Code or run /memrotate:rotate init'
    } else {
      Add-Check 'fail' 'CLAUDE.md has no memrotate block: run /memrotate:rotate init'
    }

    $state = Get-State $root $cfg
    if (-not $state) {
      Add-Check 'warn' 'no rotation recorded yet: restart Claude Code so the SessionStart hook runs'
    } else {
      $last = [datetime]::ParseExact([string]$state.lastRun, 'yyyy-MM-dd', $Invariant)
      $ago = ((Get-Date).Date - $last).Days
      if ($ago -le 1) { Add-Check 'ok' "SessionStart hook: last rotation $($state.lastRunAt)" }
      else { Add-Check 'warn' "last rotation was $ago days ago ($($state.lastRunAt)): the SessionStart hook may not be running, check /plugin > Errors" }
    }

    if ($cfg.saveReminder) {
      $sdir = Join-Path (Join-Path $root $cfg.archiveDir) '.sessions'
      $seen = Get-ChildItem -LiteralPath $sdir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($seen) { Add-Check 'ok' "Stop hook: save reminder every $($cfg.reminderEveryTools) tool calls, last seen $($seen.LastWriteTime.ToString('yyyy-MM-dd HH:mm', $Invariant))" }
      else { Add-Check 'warn' 'Stop hook has not run in this project yet (normal right after installing; it runs when Claude ends a turn)' }
    } else {
      Add-Check 'ok' 'save reminder: off'
    }

    $arch = Join-Path $root $cfg.archiveDir
    $gzCount = @(Get-ChildItem -LiteralPath $arch -Filter 'MEMORY-*.md.gz' -File -ErrorAction SilentlyContinue).Count
    Add-Check 'ok' "archives: $gzCount in $($cfg.archiveDir)"

    $gi = Join-Path $root '.gitignore'
    if (Test-Path -LiteralPath $gi) {
      $g = Read-Text $gi
      if (@(Get-GitignoreLines $cfg | Where-Object { -not $g.Contains($_) }).Count -eq 0) { Add-Check 'ok' '.gitignore ignores the plugin state files' }
      else { Add-Check 'warn' '.gitignore does not ignore the plugin state files: run /memrotate:rotate init' }
    }
  }

  if ($cfg.archiveTranscripts) {
    $w = Get-TranscriptWarning $cfg
    if ($w) { Add-Check 'warn' $w } else { Add-Check 'ok' "transcript archiving on (cleanupPeriodDays=$(Get-CleanupPeriodDays))" }
  }
  if (-not $cfg.backupGit -and -not $cfg.backupDir) {
    Add-Check 'ok' 'backup: off (optional: /memrotate:rotate backup git <path> | backup folder <path>)'
  } else {
    if ($cfg.backupGit) {
      $err = Test-GitReady $cfg.backupGit
      if ($err) { Add-Check 'fail' "backup git $($cfg.backupGit): $err" }
      elseif (-not (Test-GitUpstream $cfg.backupGit)) { Add-Check 'warn' "backup git $($cfg.backupGit): the branch has no remote, copies stay on this computer" }
      else { Add-Check 'ok' "backup git $($cfg.backupGit)" }
    }
    if ($cfg.backupDir) {
      if (Test-Path -LiteralPath $cfg.backupDir -PathType Container) { Add-Check 'ok' "backup folder $($cfg.backupDir)" }
      else { Add-Check 'fail' "backup folder $($cfg.backupDir): folder does not exist" }
    }
    $bs = Read-JsonFile (Get-BackupStatePath $root $cfg)
    if (-not $bs -or -not $bs.lastBackup) { Add-Check 'warn' 'no backup made yet: run /memrotate:rotate backup' }
    elseif (-not $bs.ok) { Add-Check 'warn' "last backup ($($bs.lastBackup)) had errors: run /memrotate:rotate backup to see them" }
    else { Add-Check 'ok' "last backup $($bs.lastBackup)" }
  }
  $lines.Add("  -> $($script:errors) errors, $($script:warns) warnings")
  return $lines
}

# ---------------------------------------------------------------- recordatorio de guardado (hook Stop)

function Get-ToolUseCount([string]$path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 0 }
  $rx = New-Object Text.RegularExpressions.Regex('"type"\s*:\s*"tool_use"')
  $n = 0
  # FileShare.ReadWrite: Claude Code tiene el transcript abierto mientras escribe
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try {
    $sr = New-Object IO.StreamReader($fs, $Utf8)
    try { while ($null -ne ($line = $sr.ReadLine())) { $n += $rx.Matches($line).Count } } finally { $sr.Dispose() }
  } finally { $fs.Dispose() }
  return $n
}

function Invoke-StopHook($root, $cfg) {
  $in = Read-HookInput
  # Evitar bucles: si Claude ya esta continuando por un Stop hook, no volver a bloquear
  if ($in -and $in.stop_hook_active) { return }
  if (-not $cfg.saveReminder) { return }
  $mem = Join-Path $root $cfg.memoryFile
  if (-not (Test-Path -LiteralPath $mem)) { return }

  $sid = 'default'
  if ($in -and $in.session_id) { $sid = ([string]$in.session_id) -replace '[^A-Za-z0-9_-]', '' }
  $tpath = $null
  if ($in) { $tpath = [string]$in.transcript_path }
  $tools = Get-ToolUseCount $tpath

  $sdir = Join-Path (Join-Path $root $cfg.archiveDir) '.sessions'
  $sp = Join-Path $sdir "$sid.json"
  $memTicks = (Get-Item -LiteralPath $mem).LastWriteTimeUtc.Ticks
  $st = $null
  if (Test-Path -LiteralPath $sp) { try { $st = (Read-Text $sp) | ConvertFrom-Json } catch { } }
  $base = 0; $lastMem = $memTicks
  if ($st) { $base = [int]$st.baseTools; $lastMem = [long]$st.memTicks }

  $remind = $false
  if ($memTicks -ne $lastMem) {
    $base = $tools   # Claude ha guardado algo: se reinicia el contador
  } elseif (($tools - $base) -ge $cfg.reminderEveryTools) {
    $remind = $true
    $since = $tools - $base
    $base = $tools
  }
  Write-Text $sp ((ConvertTo-FlatJson ([ordered]@{ baseTools = $base; memTicks = $memTicks; updated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', $Invariant) }) -Compress) + "`n")

  # Limpieza de estados de sesiones antiguas
  Get-ChildItem -LiteralPath $sdir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue

  if ($remind) {
    $reason = "$Tag Memory checkpoint: $since tool calls since the memory file was last updated. " +
      "If this work produced durable knowledge (decisions, configurations, hostnames, ports, fixes, gotchas) that is not already in $($cfg.memoryFile), " +
      "append it now at the end of that file, one line per fact: '- [$((Get-Date).ToString('yyyy-MM-dd', $Invariant))] text'. " +
      "Mark facts that stay true long-term with [pin]: '- [YYYY-MM-DD] [pin] text'. Do not duplicate existing entries. " +
      "If there is nothing worth saving, end your turn without any further output."
    [Console]::Out.Write((ConvertTo-FlatJson ([ordered]@{ decision = 'block'; reason = $reason }) -Compress))
  }
}

function Get-TranscriptWarning($cfg) {
  if (-not $cfg.archiveTranscripts) { return $null }
  $cp = Get-CleanupPeriodDays
  if ($cp -le $cfg.retentionDays) {
    return "WARNING: cleanupPeriodDays=$cp in settings.json is <= the retention period ($($cfg.retentionDays)). Claude Code may delete transcripts before they are archived; raise it (e.g. $($cfg.retentionDays + 30))."
  }
  return $null
}

function Write-Status($root, $cfg) {
  $state = Get-State $root $cfg
  $mem = Join-Path $root $cfg.memoryFile
  $size = 0
  if (Test-Path -LiteralPath $mem) { $size = (Get-Item -LiteralPath $mem).Length }
  "$Tag status"
  "  project             : $root"
  "  retention           : $($cfg.retentionDays) days"
  "  current file        : $($cfg.memoryFile) ($(Get-EntryCount $root $cfg) entries, $(Get-PinnedCount $root $cfg) pinned, $([math]::Round($size / 1KB, 1)) KB)"
  "  archive folder      : $($cfg.archiveDir)"
  "  archive transcripts : $($cfg.archiveTranscripts)"
  "  save reminder       : $($cfg.saveReminder) (every $($cfg.reminderEveryTools) tool calls without saving)"
  "  backup              : $(Get-BackupSummary $root $cfg)"
  if ($state) { "  last rotation       : $($state.lastRunAt) (entries moved: $($state.lastMoved))" }
  else { '  last rotation       : never' }
  if (-not (Test-Path -LiteralPath $mem)) { "  -> Not initialized in this project. Run: /memrotate:rotate init" }
  if ($cfg.archiveTranscripts) {
    $td = Get-TranscriptDir $root
    if ($td) { "  transcripts         : $td" } else { '  transcripts         : project folder not found in ~/.claude/projects' }
  }
  $w = Get-TranscriptWarning $cfg
  if ($w) { "  $w" }
}

# ---------------------------------------------------------------- main

try {
$root = Get-ProjectRoot
$cfg = Get-Config $root

switch ($Mode) {
  'init' {
    if ($Days -gt 0) { Save-ProjectConfig $root @{ retentionDays = $Days }; $cfg = Get-Config $root }
    $created = Invoke-Init $root $cfg
    "$Tag initialized in $root"
    foreach ($c in $created) { "  + $c" }
    "  retention: $($cfg.retentionDays) days"
  }

  'set' {
    $changes = @{}
    if ($Days -gt 0) { $changes.retentionDays = $Days }
    if ($Transcripts) {
      if (Test-Truthy $Transcripts) { $changes.archiveTranscripts = $true }
      elseif (Test-Falsy $Transcripts) { $changes.archiveTranscripts = $false }
      else { throw "Invalid -Transcripts value: $Transcripts (use on|off)" }
    }
    if ($Reminder) {
      if (Test-Truthy $Reminder) { $changes.saveReminder = $true }
      elseif (Test-Falsy $Reminder) { $changes.saveReminder = $false }
      else { throw "Invalid -Reminder value: $Reminder (use on|off)" }
    }
    if ($ReminderTools -gt 0) { $changes.reminderEveryTools = $ReminderTools }
    if ($BackupEvery -ge 0) { $changes.backupIntervalHours = $BackupEvery }
    foreach ($pair in @(@($BackupGit, 'backupGit'), @($BackupDir, 'backupDir'))) {
      if ($pair[0]) {
        if (Test-Falsy $pair[0]) { $changes[$pair[1]] = 'off' }
        else {
          $v = [string]$pair[0]
          if ($v.StartsWith('~')) { $v = $HOME + $v.Substring(1) }
          $changes[$pair[1]] = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($v)
        }
      }
    }
    if ($changes.Count -eq 0) { throw 'Nothing to change. Use -Days N, -Transcripts on|off, -Reminder on|off, -ReminderTools N, -BackupGit <path|off>, -BackupDir <path|off> and/or -BackupEvery <hours>.' }
    Save-ProjectConfig $root $changes
    $cfg = Get-Config $root
    if (Test-Path -LiteralPath (Join-Path $root $cfg.memoryFile)) { Update-Index $root $cfg }
    "$Tag settings saved to .claude/memrotate.json"
    Write-Status $root $cfg
  }

  { $_ -in 'auto', 'now' } {
    $mem = Join-Path $root $cfg.memoryFile
    if (-not (Test-Path -LiteralPath $mem)) {
      if ($Mode -eq 'now') { "$Tag not initialized in this project. Run first: /memrotate:rotate init" }
      exit 0   # en modo auto, silencio total en proyectos que no usan el plugin
    }
    $hookIn = $null
    if ($Mode -eq 'auto') { $hookIn = Read-HookInput }
    try {
      # Migracion automatica desde memory-rotate (<= 0.2.x): refresca el bloque de CLAUDE.md
      $cmd = Join-Path $root 'CLAUDE.md'
      if ((Test-Path -LiteralPath $cmd) -and (Read-Text $cmd).Contains($LegacyMdStart)) { [void](Invoke-Init $root $cfg) }
      # Anade al .gitignore las lineas de estado que falten (versiones nuevas anaden ficheros)
      $gi = Join-Path $root '.gitignore'
      if (Test-Path -LiteralPath $gi) {
        $g = Read-Text $gi
        $missing = @(Get-GitignoreLines $cfg | Where-Object { -not $g.Contains($_) })
        if ($missing.Count -gt 0) { Write-Text $gi ($g.TrimEnd() + "`n" + ($missing -join "`n") + "`n") }
      }
      $state = Get-State $root $cfg
      $today = (Get-Date).ToString('yyyy-MM-dd', $Invariant)
      $result = @{ moved = 0; months = @(); transcripts = 0 }
      if ($Mode -eq 'now' -or -not $state -or $state.lastRun -ne $today) {
        $r = Invoke-MemoryRotation $root $cfg
        $result.moved = $r.moved; $result.months = $r.months
        $result.transcripts = Invoke-TranscriptArchive $root $cfg
        if (-not $DryRun) { Update-Index $root $cfg; Save-State $root $cfg $result }
      }
      $msg = "$Tag Current memory: $($cfg.memoryFile) ($(Get-EntryCount $root $cfg) entries, $(Get-PinnedCount $root $cfg) pinned, last $($cfg.retentionDays) days). Older archives: $($cfg.archiveDir)/INDEX.md; use the memrotate:archive skill to query them."
      if ($result.moved -gt 0) { $msg += " Rotated $($result.moved) entries to: $(($result.months | ForEach-Object { "MEMORY-$_.md.gz" }) -join ', ')." }
      if ($result.transcripts -gt 0) { $msg += " Transcripts archived: $($result.transcripts)." }
      if ($DryRun) { $msg += ' (dry run: nothing was written)' }
      $msg
      if ($hookIn -and [string]$hookIn.source -eq 'compact') {
        "$Tag The conversation was just compacted. Durable knowledge from before the compaction (decisions, configurations, hostnames, ports, fixes) that is not yet in $($cfg.memoryFile) should be appended there now, one line per fact: '- [$((Get-Date).ToString('yyyy-MM-dd', $Invariant))] text', with [pin] for long-lived facts."
      }
      $w = Get-TranscriptWarning $cfg
      if ($w) { "$Tag $w" }
    } catch {
      # Nunca romper el arranque de la sesion por un fallo de rotacion
      [Console]::Error.WriteLine("$Tag error: $($_.Exception.Message)")
      if ($Mode -eq 'now') { exit 1 }
      exit 0
    }
  }

  'status' { Write-Status $root $cfg }

  'remember' { Invoke-Remember $root $cfg }

  'doctor' { Invoke-Doctor $root $cfg }

  'backup' {
    try { Invoke-Backup $root $cfg }
    catch {
      # desde los hooks nunca rompe la sesion
      [Console]::Error.WriteLine("$Tag backup error: $($_.Exception.Message)")
      if ($Quiet) { exit 0 } else { exit 1 }
    }
  }

  'restore' { Invoke-Restore $root $cfg }

  'stop' {
    # Nunca bloquear ni romper el cierre de un turno por un fallo del plugin
    try { Invoke-StopHook $root $cfg } catch { [Console]::Error.WriteLine("$Tag stop hook error: $($_.Exception.Message)") }
    exit 0
  }

  'list' {
    $idx = Join-Path (Join-Path $root $cfg.archiveDir) 'INDEX.md'
    if (Test-Path -LiteralPath (Join-Path $root $cfg.memoryFile)) { Update-Index $root $cfg }
    if (Test-Path -LiteralPath $idx) { [Console]::Out.Write((Read-Text $idx)) } else { "$Tag no archives in $($cfg.archiveDir)" }
  }

  'search' {
    if (-not $Query) { throw 'Missing -Query "text"' }
    $arch = Join-Path $root $cfg.archiveDir
    $hits = 0; $max = 200
    $sources = @()
    $mem = Join-Path $root $cfg.memoryFile
    if (Test-Path -LiteralPath $mem) { $sources += [pscustomobject]@{ Label = 'current'; Lines = (Split-Lines (Read-Text $mem)) } }
    Get-ChildItem -LiteralPath $arch -Filter 'MEMORY-*.md.gz' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
      $sources += [pscustomobject]@{ Label = ($_.Name -replace '\.md\.gz$', ''); Lines = (Split-Lines (Read-Gz $_.FullName)) }
    }
    $terms = @($Query -split '\s+' | Where-Object { $_ })
    foreach ($s in $sources) {
      foreach ($l in $s.Lines) {
        $ok = $true
        foreach ($t in $terms) { if ($l.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; break } }
        if ($ok -and $l.Trim()) {
          "$($s.Label): $($l.Trim())"
          $hits++
          if ($hits -ge $max) { "$Tag ... limit of $max results reached, narrow the search"; break }
        }
      }
      if ($hits -ge $max) { break }
    }
    if ($hits -eq 0) { "$Tag no results for: $Query" }
  }

  'read' {
    if ($Month -notmatch '^\d{4}-\d{2}$') { throw 'Use -Month YYYY-MM (e.g. 2026-09)' }
    $gzPath = Join-Path (Join-Path $root $cfg.archiveDir) "MEMORY-$Month.md.gz"
    if (-not (Test-Path -LiteralPath $gzPath)) { "$Tag archive MEMORY-$Month.md.gz does not exist"; exit 0 }
    [Console]::Out.Write((Read-Gz $gzPath))
  }
}
} catch {
  # Errores de uso: mensaje limpio en stderr y codigo 1 (sin traza de PowerShell)
  [Console]::Error.WriteLine("$Tag $($_.Exception.Message)")
  exit 1
}
