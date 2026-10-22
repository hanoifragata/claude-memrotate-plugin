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

.PINNED
  Las entradas marcadas con [pin] nunca rotan:  - [AAAA-MM-DD] [pin] texto   o   - [pin] texto
#>
[CmdletBinding()]
param(
  [ValidateSet('init', 'auto', 'now', 'status', 'set', 'list', 'search', 'read', 'stop', 'remember', 'doctor')]
  [string]$Mode = 'status',
  [int]$Days = 0,
  [string]$Transcripts = '',
  [string]$Reminder = '',
  [int]$ReminderTools = 0,
  [string]$Query = '',
  [string]$Text = '',
  [switch]$Pin,
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
    source             = 'defaults'
  }
  # 1) Valores globales del plugin (userConfig).
  #    a) En hooks llegan como variables de entorno -> se cachean en la carpeta de datos del plugin.
  #    b) Desde la skill no llegan -> se leen de esa cache.
  $envDays = $env:CLAUDE_PLUGIN_OPTION_RETENTION_DAYS
  $envTr = $env:CLAUDE_PLUGIN_OPTION_ARCHIVE_TRANSCRIPTS
  $envRem = $env:CLAUDE_PLUGIN_OPTION_SAVE_REMINDER
  $dataDir = Get-PluginDataDir
  $cache = $null
  if ($dataDir) { $cache = Join-Path $dataDir 'options.json' }
  if (($envDays -or $envTr -or $envRem) -and $cache) {
    try {
      Write-Text $cache ((ConvertTo-FlatJson ([ordered]@{ retention_days = "$envDays"; archive_transcripts = "$envTr"; save_reminder = "$envRem"; savedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss', $Invariant) })) + "`n")
    } catch { }
  }
  if ((-not $envDays -or -not $envTr -or -not $envRem) -and $cache -and (Test-Path -LiteralPath $cache)) {
    try {
      $c = (Read-Text $cache) | ConvertFrom-Json
      if (-not $envDays) { $envDays = [string]$c.retention_days }
      if (-not $envTr) { $envTr = [string]$c.archive_transcripts }
      if (-not $envRem) { $envRem = [string]$c.save_reminder }
    } catch { }
  }
  if (-not $envDays -and (Test-Substituted $DefaultDays)) { $envDays = $DefaultDays }
  if (-not $envTr -and (Test-Substituted $DefaultTranscripts)) { $envTr = $DefaultTranscripts }
  $n = 0
  if ($envDays -or $envTr -or $envRem) { $cfg.source = 'plugin options (/config)' }
  if ($envDays -and [int]::TryParse(([string]$envDays).Split('.')[0], [ref]$n) -and $n -gt 0) { $cfg.retentionDays = $n }
  if ($envTr) { if (Test-Truthy $envTr) { $cfg.archiveTranscripts = $true } elseif (Test-Falsy $envTr) { $cfg.archiveTranscripts = $false } }
  if ($envRem) { if (Test-Truthy $envRem) { $cfg.saveReminder = $true } elseif (Test-Falsy $envRem) { $cfg.saveReminder = $false } }

  # 2) Configuracion del proyecto (.claude/memrotate.json) tiene prioridad
  $p = Get-ProjectConfigPath $root
  if ($p) {
    $cfg.source = (Split-Path -Leaf $p)
    $j = (Read-Text $p) | ConvertFrom-Json
    foreach ($k in @('retentionDays', 'memoryFile', 'archiveDir', 'archiveTranscripts', 'saveReminder', 'reminderEveryTools')) {
      if ($j.PSObject.Properties.Name -contains $k -and $null -ne $j.$k) { $cfg[$k] = $j.$k }
    }
  }
  $cfg.retentionDays = [int]$cfg.retentionDays
  $cfg.archiveTranscripts = [bool]$cfg.archiveTranscripts
  $cfg.saveReminder = [bool]$cfg.saveReminder
  $cfg.reminderEveryTools = [math]::Max(1, [int]$cfg.reminderEveryTools)
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
  Write-Text (Join-Path $arch 'INDEX.md') $sb.ToString()
}

# ---------------------------------------------------------------- init

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
    foreach ($line in @("$($cfg.archiveDir)/.state.json", "$($cfg.archiveDir)/.sessions/")) {
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
      if ($g.Contains("$($cfg.archiveDir)/.state.json") -and $g.Contains("$($cfg.archiveDir)/.sessions/")) { Add-Check 'ok' '.gitignore ignores the plugin state files' }
      else { Add-Check 'warn' '.gitignore does not ignore the plugin state files: run /memrotate:rotate init' }
    }
  }

  if ($cfg.archiveTranscripts) {
    $w = Get-TranscriptWarning $cfg
    if ($w) { Add-Check 'warn' $w } else { Add-Check 'ok' "transcript archiving on (cleanupPeriodDays=$(Get-CleanupPeriodDays))" }
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
    if ($changes.Count -eq 0) { throw 'Nothing to change. Use -Days N, -Transcripts on|off, -Reminder on|off and/or -ReminderTools N.' }
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
