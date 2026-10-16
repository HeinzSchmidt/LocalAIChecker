<#
.SYNOPSIS
  Local LLM Checkup for Windows: checks whether a local LLM server hits its KV prefix cache.

.DESCRIPTION
  Implements documentation/SPECIFICATION-Windows.md (v1.1.0). Runs checks C1-C5, a live
  4-request cache test against Ollama, LM Studio or llama.cpp, and writes a markdown report
  plus an HTML copy with Windows fix steps. Read-only: never changes configuration,
  environment variables or application settings.

  Compatible with Windows PowerShell 5.1 and PowerShell 7+. No external modules.
  Arguments are parsed by the script itself (not by PowerShell parameter binding) so that
  bad arguments always exit with code 3, as the specification requires.

  Run: powershell -ExecutionPolicy Bypass -File .\Invoke-LocalLLMCheckup.ps1 [options]
  Use -Help for the option list.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Script:Version   = '1.1.0'
$Script:Dir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:PrefixFile = Join-Path $Script:Dir 'prefix.txt'
$Script:HybridFile = Join-Path $Script:Dir 'hybrid-models.txt'
$Script:MinClaude = '2.1.181'
$Script:MaxTokens = 64
$Script:ReqTimeoutSec = 300
$Script:KeepAlive = '10m'
$Script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Script:Inv = [Globalization.CultureInfo]::InvariantCulture
$Script:OnWindows = ($PSVersionTable.PSVersion.Major -le 5) -or ((Test-Path variable:IsWindows) -and $IsWindows)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Err([string]$Message)  { [Console]::Error.WriteLine("Invoke-LocalLLMCheckup: error: $Message") }
function Write-Warn([string]$Message) { [Console]::Error.WriteLine("Invoke-LocalLLMCheckup: warning: $Message") }
function Exit-Tool([int]$Code) { exit $Code }

function Show-Usage {
@"
Invoke-LocalLLMCheckup.ps1 $Script:Version - check whether your local LLM server hits its prompt cache

Usage: Invoke-LocalLLMCheckup.ps1 [options]

  -Server <ollama|lmstudio|llamacpp>  Server to test (default: auto-detect)
  -Url <url>                          Override endpoint (requires -Server)
  -Model <name>                       Model to test (validated against installed models;
                                      default: first loaded model)
  -Interactive                        Choose server and model from a menu (automatic in an
                                      interactive console when no model is given)
  -ListModels                         List installed models for the server and exit
  -Config <path>                      Config file (default: local-llm-checkup.conf next to the
                                      script, then %APPDATA%\local-llm-checkup\config)
  -Log <path>                         Server log file for C3
  -SessionLog <path>                  Agent session log for C4 (optional)
  -SkipLive                           Run static checks only
  -OutputDir <path>                   Report directory (default: .\reports); writes
                                      llm-checkup-windows-<timestamp>.md and a .html copy
  -NoColor                            Disable colours
  -NoOpen                             Do not open the HTML report in the browser
  -Help                               Show help
  -Version                            Show version

Config file: KEY=value lines; keys SERVER, URL, MODEL, LOG, SESSION_LOG, OUTPUT,
SKIP_LIVE (0/1), NO_COLOR (0/1), OPEN_REPORT (0/1). Command-line options override it.

Exit codes: 0 all scored items PASS, 1 WARN (no FAIL), 2 at least one FAIL, 3 tool error.
"@
}

# Thousands separators, culture independent.
function Format-N($n) {
  if ($null -eq $n -or "$n" -eq '') { return '-' }
  $v = 0L
  if ([long]::TryParse("$n", [ref]$v)) { return $v.ToString('N0', $Script:Inv) }
  return "$n"
}
function Format-S($x) { if ($null -eq $x) { return '-' }; return ([double]$x).ToString('0.000', $Script:Inv) }

function Test-VersionGe([string]$A, [string]$B) {
  $x = $A.Split('.'); $y = $B.Split('.')
  $n = [Math]::Max($x.Count, $y.Count)
  for ($i = 0; $i -lt $n; $i++) {
    $xi = 0; $yi = 0
    if ($i -lt $x.Count) { [void][int]::TryParse($x[$i], [ref]$xi) }
    if ($i -lt $y.Count) { [void][int]::TryParse($y[$i], [ref]$yi) }
    if ($xi -gt $yi) { return $true }; if ($xi -lt $yi) { return $false }
  }
  return $true
}

function Expand-UserPath([string]$P) {
  if ([string]::IsNullOrEmpty($P)) { return $P }
  if ($P.StartsWith('~')) { $P = $HOME + $P.Substring(1) }
  return [Environment]::ExpandEnvironmentVariables($P)
}

function Get-Prop($Obj, [string]$Name) {
  # Safe property read under StrictMode (works for names containing dots).
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Test-Tty {
  try { return (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected) -and [Environment]::UserInteractive }
  catch { return $false }
}

# ---------------------------------------------------------------------------
# Argument parsing (manual, so bad arguments exit 3)
# ---------------------------------------------------------------------------
$Opt = @{ Server = ''; Url = ''; Model = ''; Log = ''; SessionLog = ''; SkipLive = $null; OutputDir = '';
          NoColor = $null; Open = $null; Config = ''; ListModels = $false; Interactive = $false }
$valueOpts = @('-server','-url','-model','-log','-sessionlog','-outputdir','-config')
$i = 0
while ($i -lt $args.Count) {
  $a = [string]$args[$i]; $k = $a.ToLowerInvariant()
  if ($valueOpts -contains $k) {
    if ($i + 1 -ge $args.Count -or ([string]$args[$i + 1]).StartsWith('-')) {
      Write-Err "option $a requires a value"; Show-Usage | Write-Host; Exit-Tool 3
    }
    $v = [string]$args[$i + 1]; $i += 2
    switch ($k) {
      '-server'     { $Opt.Server = $v.ToLowerInvariant() }
      '-url'        { $Opt.Url = $v.TrimEnd('/') }
      '-model'      { $Opt.Model = $v }
      '-log'        { $Opt.Log = Expand-UserPath $v }
      '-sessionlog' { $Opt.SessionLog = Expand-UserPath $v }
      '-outputdir'  { $Opt.OutputDir = Expand-UserPath $v }
      '-config'     { $Opt.Config = Expand-UserPath $v }
    }
    continue
  }
  switch ($k) {
    '-skiplive'    { $Opt.SkipLive = $true }
    '-nocolor'     { $Opt.NoColor = $true }
    '-noopen'      { $Opt.Open = $false }
    '-listmodels'  { $Opt.ListModels = $true }
    '-interactive' { $Opt.Interactive = $true }
    { $_ -in '-help','-h','-?','/?' } { Show-Usage; Exit-Tool 0 }
    '-version'     { "Invoke-LocalLLMCheckup.ps1 $Script:Version"; Exit-Tool 0 }
    default        { Write-Err "unknown option: $a"; Show-Usage | Write-Host; Exit-Tool 3 }
  }
  $i++
}

# ---------------------------------------------------------------------------
# Config file: KEY=value lines, parsed as text (never dot-sourced or evaluated)
# ---------------------------------------------------------------------------
$ConfigUsed = ''
if ($Opt.Config) {
  if (-not (Test-Path -LiteralPath $Opt.Config -PathType Leaf)) { Write-Err "config file not readable: $($Opt.Config)"; Exit-Tool 3 }
  $ConfigUsed = $Opt.Config
} else {
  $cands = @((Join-Path $Script:Dir 'local-llm-checkup.conf'))
  if ($env:APPDATA) { $cands += (Join-Path $env:APPDATA 'local-llm-checkup\config') }
  foreach ($c in $cands) { if (Test-Path -LiteralPath $c -PathType Leaf) { $ConfigUsed = $c; break } }
}
$ModelSource = ''; $cfgModel = $false
function ConvertTo-Bool([string]$V) {
  switch ($V.ToLowerInvariant()) { { $_ -in '1','true','yes','on' } { return $true } { $_ -in '0','false','no','off','' } { return $false } }
  return $null
}
if ($ConfigUsed) {
  $lineNo = 0
  foreach ($raw in [IO.File]::ReadAllLines($ConfigUsed)) {
    $lineNo++
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $eq = $line.IndexOf('=')
    if ($eq -lt 1) { Write-Warn "${ConfigUsed}:${lineNo}: ignored (not KEY=value): $line"; continue }
    $key = $line.Substring(0, $eq).Trim().ToUpperInvariant()
    $val = $line.Substring($eq + 1).Trim()
    if ($val.Length -ge 2 -and (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'")))) {
      $val = $val.Substring(1, $val.Length - 2)
    } else { $val = ($val -replace '\s#.*$', '') }
    switch ($key) {
      'SERVER'      { if (-not $Opt.Server) { $Opt.Server = $val.ToLowerInvariant() } }
      'URL'         { if (-not $Opt.Url) { $Opt.Url = $val.TrimEnd('/') } }
      'MODEL'       { if (-not $Opt.Model -and $val) { $Opt.Model = $val; $cfgModel = $true } }
      'LOG'         { if (-not $Opt.Log) { $Opt.Log = Expand-UserPath $val } }
      'SESSION_LOG' { if (-not $Opt.SessionLog) { $Opt.SessionLog = Expand-UserPath $val } }
      'OUTPUT'      { if (-not $Opt.OutputDir) { $Opt.OutputDir = Expand-UserPath $val } }
      { $_ -in 'SKIP_LIVE','NO_COLOR','OPEN_REPORT' } {
        $b = ConvertTo-Bool $val
        if ($null -eq $b) { Write-Warn "${ConfigUsed}:${lineNo}: $key must be 0 or 1, got '$val'; ignored"; break }
        if ($key -eq 'SKIP_LIVE'   -and $null -eq $Opt.SkipLive) { $Opt.SkipLive = $b }
        if ($key -eq 'NO_COLOR'    -and $null -eq $Opt.NoColor)  { $Opt.NoColor = $b }
        if ($key -eq 'OPEN_REPORT' -and $null -eq $Opt.Open)     { $Opt.Open = $b }
      }
      default { Write-Warn "${ConfigUsed}:${lineNo}: unknown key '$key' ignored" }
    }
  }
}
if ($null -eq $Opt.SkipLive) { $Opt.SkipLive = $false }
if ($null -eq $Opt.NoColor)  { $Opt.NoColor = $false }
if (-not $Opt.OutputDir)     { $Opt.OutputDir = Join-Path '.' 'reports' }
if ($Opt.Model) { if ($cfgModel) { $ModelSource = 'config' } else { $ModelSource = 'CLI' } }

if ($Opt.Server -and @('ollama','lmstudio','llamacpp') -notcontains $Opt.Server) { Write-Err "invalid -Server '$($Opt.Server)' (use ollama, lmstudio or llamacpp)"; Exit-Tool 3 }
if ($Opt.Url -and -not $Opt.Server) { Write-Err '-Url requires -Server so the API type is known'; Exit-Tool 3 }
if ($Opt.Log -and -not (Test-Path -LiteralPath $Opt.Log -PathType Leaf)) { Write-Err "log file not readable: $($Opt.Log)"; Exit-Tool 3 }
if ($Opt.SessionLog -and -not (Test-Path -LiteralPath $Opt.SessionLog -PathType Leaf)) { Write-Err "session log not readable: $($Opt.SessionLog)"; Exit-Tool 3 }

# ---------------------------------------------------------------------------
# Colours (spec 6): off with -NoColor, NO_COLOR, or redirected output
# ---------------------------------------------------------------------------
$useColor = -not ($Opt.NoColor -or (Test-Path env:NO_COLOR) -or [Console]::IsOutputRedirected)
$E = [char]27
if ($useColor) { $C = @{ G = "$E[32m"; Y = "$E[33m"; R = "$E[31m"; D = "$E[90m"; C = "$E[36m"; B = "$E[1m"; O = "$E[0m" } }
else { $C = @{ G = ''; Y = ''; R = ''; D = ''; C = ''; B = ''; O = '' } }
function Get-ResColor([string]$R) { switch ($R) { 'PASS' { $C.G } 'WARN' { $C.Y } { $_ -in 'FAIL','ERROR' } { $C.R } default { $C.D } } }
function Out-Heading([string]$T) { [Console]::Out.WriteLine("$($C.C)$($C.B)$T$($C.O)") }
function Out-Progress([string]$T) { [Console]::Out.WriteLine("$($C.C)  ... $T$($C.O)") }
function Out-Line([string]$T) { [Console]::Out.WriteLine($T) }

# ---------------------------------------------------------------------------
# Dependencies and files
# ---------------------------------------------------------------------------
foreach ($f in @($Script:PrefixFile, $Script:HybridFile)) {
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-Err "required file missing: $f"; Exit-Tool 3 }
}
if (-not $Opt.ListModels) {
  try { [void](New-Item -ItemType Directory -Force -Path $Opt.OutputDir) } catch { Write-Err "cannot create output directory: $($Opt.OutputDir)"; Exit-Tool 3 }
}
$StartTs = Get-Date -Format 'yyyyMMdd-HHmmss'
$StartHuman = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz', $Script:Inv)
$Report = Join-Path $Opt.OutputDir "llm-checkup-windows-$StartTs.md"

# Results (one ordered list of hashtables)
$Results = New-Object System.Collections.ArrayList
function Add-Result([string]$Id, [string]$Name, [string]$Res, [string]$Detail) {
  $score = '-'
  switch ($Res) { 'PASS' { $score = '1.0' } 'WARN' { $score = '0.5' } 'FAIL' { $score = '0.0' } }
  [void]$Results.Add(@{ Id = $Id; Name = $Name; Res = $Res; Score = $score; Detail = $Detail })
  $label = "[$Id] $Name "
  $n = [Math]::Max(3, 52 - $label.Length)
  Out-Line ("{0}{1} {2}{3}{4}  {5}{6}{7}" -f $label, ('.' * $n), (Get-ResColor $Res), $Res, $C.O, $C.D, $Detail, $C.O)
}

# ---------------------------------------------------------------------------
# Environment (spec 3.3); every probe is guarded so non-Windows hosts still run
# ---------------------------------------------------------------------------
if (-not $Opt.ListModels) { Out-Heading "Local LLM Checkup for Windows $Script:Version" }
$OsText = 'unknown'; $CpuText = 'unknown'; $MemText = 'unknown'; $GpuText = 'unknown'
try {
  $os = Get-CimInstance Win32_OperatingSystem
  $OsText = "$($os.Caption) $($os.Version) (build $($os.BuildNumber))"
  $CpuText = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
  $MemText = '{0:0} GB' -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
  $GpuText = ((Get-CimInstance Win32_VideoController | ForEach-Object {
      if ($_.AdapterRAM) { '{0} ({1:0.#} GB)' -f $_.Name, ($_.AdapterRAM / 1GB) } else { $_.Name } }) -join '; ')
} catch {
  if ($Script:OnWindows) { Write-Warn "could not read system information: $($_.Exception.Message)" }
  else { $OsText = "$([Runtime.InteropServices.RuntimeInformation]::OSDescription) (not Windows)" }
}
$PsText = $PSVersionTable.PSVersion.ToString()

function Get-ToolVersion([string]$Cmd, [string[]]$ArgList, [string]$Pattern) {
  $g = Get-Command $Cmd -ErrorAction SilentlyContinue
  if (-not $g) { return '' }
  try { $out = (& $Cmd @ArgList 2>&1 | Out-String) } catch { return '' }
  $m = [regex]::Match($out, $Pattern)
  if ($m.Success) { return $m.Value }; return ''
}
$ClaudeInstalled = [bool](Get-Command claude -ErrorAction SilentlyContinue)
$ClaudeVerRaw = ''; $ClaudeVer = ''
if ($ClaudeInstalled) {
  try { $ClaudeVerRaw = ((& claude --version 2>&1) | Select-Object -First 1) | Out-String } catch { $ClaudeVerRaw = '' }
  $m = [regex]::Match($ClaudeVerRaw, '\d+\.\d+\.\d+'); if ($m.Success) { $ClaudeVer = $m.Value }
}
$OllamaVer = Get-ToolVersion 'ollama' @('--version') '\d+\.\d+\.\d+\S*'
$LmsVer    = Get-ToolVersion 'lms' @('version') '\d+\.\d+\.\d+'
$LlamaVer  = Get-ToolVersion 'llama-server' @('--version') '(?<=version: ).*'

# ---------------------------------------------------------------------------
# Server detection, model listing and selection (spec 2.1, 5.1)
# ---------------------------------------------------------------------------
function Get-DefaultUrl([string]$S) { switch ($S) { 'ollama' { 'http://localhost:11434' } 'lmstudio' { 'http://localhost:1234' } 'llamacpp' { 'http://localhost:8080' } } }
function Get-ServerLabel([string]$S) { switch ($S) { 'ollama' { 'Ollama' } 'lmstudio' { 'LM Studio' } 'llamacpp' { 'llama.cpp (llama-server)' } default { 'none' } } }
$Probe = @{}
function Test-Server([string]$S, [string]$U) {
  $path = '/v1/models'; if ($S -eq 'ollama') { $path = '/api/tags' }
  try { $Probe[$S] = Invoke-RestMethod -Uri "$U$path" -TimeoutSec 3 -Method Get; return $true } catch { return $false }
}
$EmbedRe = 'embed|bge-|minilm|e5-|gte-|nomic-bert|rerank'
function Get-InstalledModelList([string]$S) {
  $list = New-Object System.Collections.ArrayList
  $p = $Probe[$S]
  if ($S -eq 'ollama') {
    foreach ($m in @(Get-Prop $p 'models')) {
      if ($null -eq $m) { continue }
      $fam = [string](Get-Prop (Get-Prop $m 'details') 'family')
      $emb = ($m.name -match $EmbedRe) -or ($fam -match 'bert')
      [void]$list.Add(@{ Name = [string]$m.name; Size = [long](Get-Prop $m 'size'); Embed = $emb })
    }
  } else {
    foreach ($m in @(Get-Prop $p 'data')) {
      if ($null -eq $m) { continue }
      $emb = ($m.id -match $EmbedRe) -or ([string](Get-Prop $m 'type') -match 'embed')
      [void]$list.Add(@{ Name = [string]$m.id; Size = 0L; Embed = $emb })
    }
  }
  return ,$list
}
function Format-Size([long]$B) {
  if ($B -le 0) { return '-' }
  if ($B -ge 1GB) { return ($B / 1GB).ToString('0.0', $Script:Inv) + ' GB' }
  return ($B / 1MB).ToString('0', $Script:Inv) + ' MB'
}
# Numbered menu drawn on the host (not the output stream); returns the chosen index (0-based).
function Read-Choice([string]$Title, [string[]]$Items) {
  Write-Host $Title
  for ($j = 0; $j -lt $Items.Count; $j++) { Write-Host ('  {0,2}) {1}' -f ($j + 1), $Items[$j]) }
  while ($true) {
    Write-Host -NoNewline ("Choose 1-{0} [1]: " -f $Items.Count)
    $ans = [Console]::In.ReadLine()
    if ($null -eq $ans) { Write-Err 'no selection (end of input)'; Exit-Tool 3 }
    $ans = $ans.Trim(); if ($ans -eq '') { $ans = '1' }
    $n = 0
    if (-not [int]::TryParse($ans, [ref]$n)) { Write-Host '  Please enter a number.'; continue }
    if ($n -ge 1 -and $n -le $Items.Count) { return ($n - 1) }
    Write-Host '  Out of range.'
  }
}

$Server = ''; $Url = ''; $ServerNote = ''; $Responding = @()
if ($Opt.Server) {
  $Url = $Opt.Url; if (-not $Url) { $Url = Get-DefaultUrl $Opt.Server }
  if (Test-Server $Opt.Server $Url) { $Server = $Opt.Server }
  elseif ($Opt.ListModels) { Write-Err "$($Opt.Server) not reachable at $Url"; Exit-Tool 3 }
  elseif (-not $Opt.SkipLive) { Write-Err "$($Opt.Server) not reachable at $Url (use -SkipLive for static checks only)"; Exit-Tool 3 }
  else { $ServerNote = "$($Opt.Server) not reachable at $Url"; Write-Warn $ServerNote }
} else {
  foreach ($s in @('ollama','lmstudio','llamacpp')) { if (Test-Server $s (Get-DefaultUrl $s)) { $Responding += $s } }
  if ($Responding.Count -gt 0) { $Server = $Responding[0]; $Url = Get-DefaultUrl $Server }
  else {
    $ServerNote = 'no local server responded (Ollama :11434, LM Studio :1234, llama.cpp :8080)'
    if ($Opt.ListModels) { Write-Err $ServerNote; Exit-Tool 3 }
    Write-Warn $ServerNote
  }
}

$Prompt = $false
if (-not $Opt.ListModels -and $Server -and ($Opt.Interactive -or -not $Opt.Model)) {
  if (Test-Tty) { $Prompt = $true }
  elseif ($Opt.Interactive) { Write-Warn '-Interactive needs an interactive console; using defaults' }
}
if ($Prompt -and -not $Opt.Server -and $Responding.Count -gt 1) {
  $idx = Read-Choice 'Several local servers responded:' @($Responding | ForEach-Object { "$_  $(Get-DefaultUrl $_)" })
  $Server = $Responding[$idx]; $Url = Get-DefaultUrl $Server
}
$Installed = New-Object System.Collections.ArrayList
if ($Server) { $Installed = Get-InstalledModelList $Server }

if ($Opt.ListModels) {
  Out-Line ("{0} models at {1}:" -f (Get-ServerLabel $Server), $Url)
  if ($Installed.Count -eq 0) { Out-Line '  (none)'; Exit-Tool 0 }
  foreach ($m in $Installed) {
    $tag = ''; if ($m.Embed) { $tag = '  [embedding, not selectable]' }
    Out-Line ('  {0,-40} {1,9}{2}' -f $m.Name, (Format-Size $m.Size), $tag)
  }
  Exit-Tool 0
}

$Model = ''; $ModelNote = ''
if ($Opt.Model -and $Server) {
  foreach ($m in $Installed) {
    if ($m.Name -eq $Opt.Model -or ($Server -eq 'ollama' -and ($m.Name -eq "$($Opt.Model):latest" -or "$($m.Name):latest" -eq $Opt.Model))) { $Model = $m.Name; $hit = $m; break }
  }
  if (-not $Model) {
    Write-Err "model '$($Opt.Model)' ($ModelSource) is not installed on $(Get-ServerLabel $Server). Installed models:"
    foreach ($m in $Installed) { $t = ''; if ($m.Embed) { $t = '  [embedding]' }; [Console]::Error.WriteLine("  $($m.Name)$t") }
    Exit-Tool 3
  }
  if ($hit.Embed) { Write-Err "model '$Model' is an embedding model and cannot be chat-tested"; Exit-Tool 3 }
} elseif ($Opt.Model) { $Model = $Opt.Model }

if (-not $Model -and $Prompt) {
  $chat = @($Installed | Where-Object { -not $_.Embed })
  if ($chat.Count -gt 0) {
    $idx = Read-Choice "Installed models on $(Get-ServerLabel $Server) (embedding models hidden):" @($chat | ForEach-Object { '{0,-40} {1,9}' -f $_.Name, (Format-Size $_.Size) })
    $Model = $chat[$idx].Name; $ModelSource = 'interactive'
  } else { Write-Warn 'no chat models installed; falling back to defaults' }
}
if (-not $Model -and $Server) {
  if ($Server -eq 'ollama') {
    try { $ps = Invoke-RestMethod -Uri "$Url/api/ps" -TimeoutSec 5; $first = @(Get-Prop $ps 'models') | Select-Object -First 1; if ($first) { $Model = [string]$first.name; $ModelNote = 'first loaded model' } } catch { $null = $_ }  # optional data; fall back below
  }
  if (-not $Model) {
    $first = @($Installed | Where-Object { -not $_.Embed }) | Select-Object -First 1
    if ($first) { $Model = $first.Name; $ModelNote = 'first installed model' }
  }
  if ($Model) { $ModelSource = 'default' }
}

Out-Line ("  {0}; {1}; {2}" -f $OsText, $CpuText, $MemText)
$src = ''; if ($ModelSource) { $src = " (chosen by: $ModelSource)" }
$mshow = $Model; if (-not $mshow) { $mshow = 'none' }
Out-Line ("  Server: {0} {1}  Model: {2}{3}" -f (Get-ServerLabel $Server), $Url, $mshow, $src)
if ($ConfigUsed) { Out-Line "  Config: $ConfigUsed" }

# Server log for C3 (spec 5 default locations); remember its size so only new lines count.
$LogFile = $Opt.Log
if (-not $LogFile) {
  switch ($Server) {
    'ollama'   { if ($env:LOCALAPPDATA) { $c = Join-Path $env:LOCALAPPDATA 'Ollama\server.log'; if (Test-Path -LiteralPath $c) { $LogFile = $c } } }
    'lmstudio' { $d = Join-Path $HOME '.lmstudio\server-logs'; if (Test-Path $d) { $f = Get-ChildItem -Path $d -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1; if ($f) { $LogFile = $f.FullName } } }
    'llamacpp' { Write-Warn 'llama.cpp has no default log location; pass -Log <file> (start llama-server.exe with -v 4) for C3' }
  }
}
$LogStart = 0L
if ($LogFile -and (Test-Path -LiteralPath $LogFile)) { $LogStart = (Get-Item -LiteralPath $LogFile).Length }

# ---------------------------------------------------------------------------
# C1: Claude Code attribution header (process, user and machine environment)
# ---------------------------------------------------------------------------
Out-Heading 'Checklist'
$Attr = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_ATTRIBUTION_HEADER')
$AttrScope = 'process'
if ($null -eq $Attr -and $Script:OnWindows) {
  foreach ($scope in @('User','Machine')) {
    $v = [Environment]::GetEnvironmentVariable('CLAUDE_CODE_ATTRIBUTION_HEADER', $scope)
    if ($null -ne $v) { $Attr = $v; $AttrScope = $scope.ToLowerInvariant(); break }
  }
}
try {
  if (-not $ClaudeInstalled) { Add-Result 'C1' 'Claude Code attribution header' 'SKIP' 'Claude Code not installed' }
  elseif ($Attr -eq '0') { $vt = ''; if ($ClaudeVer) { $vt = " (Claude Code $ClaudeVer)" }; Add-Result 'C1' 'Claude Code attribution header' 'PASS' "CLAUDE_CODE_ATTRIBUTION_HEADER=0 in $AttrScope environment$vt" }
  elseif (-not $ClaudeVer) { Add-Result 'C1' 'Claude Code attribution header' 'WARN' "Version could not be parsed ('$($ClaudeVerRaw.Trim())') and variable not 0" }
  elseif (Test-VersionGe $ClaudeVer $Script:MinClaude) { Add-Result 'C1' 'Claude Code attribution header' 'PASS' "Claude Code $ClaudeVer" }
  else { $at = 'not set'; if ($null -ne $Attr) { $at = "is $Attr" }; Add-Result 'C1' 'Claude Code attribution header' 'FAIL' "Claude Code $ClaudeVer < $($Script:MinClaude) and variable $at" }
} catch { Add-Result 'C1' 'Claude Code attribution header' 'ERROR' $_.Exception.Message }

# ---------------------------------------------------------------------------
# Live cache test (spec 4). Uses HttpWebRequest so time to first token can be
# measured on a streamed response in both Windows PowerShell 5.1 and PowerShell 7.
# ---------------------------------------------------------------------------
$L = @{}; foreach ($t in 1..4) { $L[$t] = @{ Ttft = $null; Total = $null; Prompt = $null; Cached = $null; Src = ''; Think = 0; Content = ''; Thinking = '' } }
$LiveStatus = 'skipped'; $LiveNote = ''; $ThinkMode = $false; $CounterSrc = ''
$LiveStart = $null; $LiveEnd = $null
$Questions = @('',
  'Question A: In one sentence, what must the keeper do if they cannot oil the main bearing?',
  'Question B: In one sentence, which sections mention the lighthouse?',
  'Question C: In one sentence, how often must the alarm bell be tested?',
  'Question D: In one sentence, what is written in the ledger?')
# Same bytes as the macOS tool: read as UTF-8 without BOM; the macOS tool strips the final newline.
$PrefixText = [IO.File]::ReadAllText($Script:PrefixFile, $Script:Utf8NoBom).TrimEnd("`n")

function Invoke-Stream([string]$Uri, [string]$Body) {
  # Returns @{ Status; Ttft; Total; Lines }; Ttft = seconds until the first non-empty line.
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $req = [Net.HttpWebRequest]::Create($Uri)
  $req.Method = 'POST'; $req.ContentType = 'application/json'
  $req.Timeout = $Script:ReqTimeoutSec * 1000; $req.ReadWriteTimeout = $Script:ReqTimeoutSec * 1000
  $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
  $req.ContentLength = $bytes.Length
  $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
  try { $resp = $req.GetResponse() }
  catch [Net.WebException] {
    $r = $_.Exception.Response
    $msg = $_.Exception.Message
    if ($r) { $msg = (New-Object IO.StreamReader($r.GetResponseStream())).ReadToEnd() }
    return @{ Status = 0; Error = $msg; Ttft = $null; Total = $null; Lines = @() }
  }
  $status = [int]$resp.StatusCode   # read before Close(); disposed responses report 0 on .NET Core
  $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
  $lines = New-Object System.Collections.ArrayList; $ttft = $null
  while ($null -ne ($line = $reader.ReadLine())) {
    if ($line.Trim() -eq '') { continue }
    if ($null -eq $ttft) { $ttft = $sw.Elapsed.TotalSeconds }
    [void]$lines.Add($line)
  }
  $reader.Close(); $resp.Close(); $sw.Stop()
  return @{ Status = $status; Error = ''; Ttft = $ttft; Total = $sw.Elapsed.TotalSeconds; Lines = $lines }
}

function Send-Turn([int]$T, $Messages) {
  $r = $L[$T]
  if ($Server -eq 'ollama') {
    $body = @{ model = $Model; messages = $Messages; stream = $true; keep_alive = $Script:KeepAlive; options = @{ num_predict = $Script:MaxTokens } }
    if ($ThinkMode) { $body.think = $true }
    $res = Invoke-Stream "$Url/api/chat" ($body | ConvertTo-Json -Depth 10 -Compress)
    if ($res.Status -ne 200) { Write-Err "request ${T}: $($res.Error)"; return $false }
    $objs = @($res.Lines | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    $fin = @($objs | Where-Object { (Get-Prop $_ 'done') -eq $true }) | Select-Object -Last 1
    if (-not $fin) { Write-Err "request ${T}: no final chunk"; return $false }
    $r.Ttft = $res.Ttft; $r.Total = $res.Total
    $r.Prompt = Get-Prop $fin 'prompt_eval_count'
    $cc = Get-Prop $fin 'prompt_eval_cached_count'
    if ($null -ne $cc) { $r.Cached = [long]$cc; $r.Src = 'prompt_eval_cached_count' }
    elseif ($null -ne $r.Prompt -and $null -ne $L[1].Prompt -and $T -gt 1) {
      $r.Cached = [Math]::Max(0, [long]$L[1].Prompt - [long]$r.Prompt); $r.Src = 'prompt_eval_count vs prompt length'
    }
    $r.Content  = (@($objs | ForEach-Object { [string](Get-Prop (Get-Prop $_ 'message') 'content') }) -join '')
    $r.Thinking = (@($objs | ForEach-Object { [string](Get-Prop (Get-Prop $_ 'message') 'thinking') }) -join '')
  } else {
    $body = @{ model = $Model; messages = $Messages; stream = $true; max_tokens = $Script:MaxTokens; cache_prompt = $true; stream_options = @{ include_usage = $true } }
    $res = Invoke-Stream "$Url/v1/chat/completions" ($body | ConvertTo-Json -Depth 10 -Compress)
    if ($res.Status -ne 200) { Write-Err "request ${T}: $($res.Error)"; return $false }
    $objs = @($res.Lines | Where-Object { $_ -like 'data:*' } | ForEach-Object { $_.Substring(5).Trim() } | Where-Object { $_ -ne '[DONE]' } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    if ($objs.Count -eq 0) { Write-Err "request ${T}: empty stream"; return $false }
    $r.Ttft = $res.Ttft; $r.Total = $res.Total
    $usage = @($objs | Where-Object { Get-Prop $_ 'usage' } | ForEach-Object { $_.usage }) | Select-Object -Last 1
    $tim   = @($objs | Where-Object { Get-Prop $_ 'timings' } | ForEach-Object { $_.timings }) | Select-Object -Last 1
    if ($usage) { $r.Prompt = Get-Prop $usage 'prompt_tokens' }
    $ct = Get-Prop (Get-Prop $usage 'prompt_tokens_details') 'cached_tokens'
    if ($null -ne $ct) { $r.Cached = [long]$ct; $r.Src = 'usage.prompt_tokens_details.cached_tokens' }
    elseif ($null -ne (Get-Prop $tim 'cache_n')) {
      $r.Cached = [long]$tim.cache_n; $r.Src = 'timings.cache_n'
      if ($null -eq $r.Prompt) { $r.Prompt = [long]$tim.prompt_n + [long]$tim.cache_n }
    }
    $r.Content  = (@($objs | ForEach-Object { [string](Get-Prop (Get-Prop (@(Get-Prop $_ 'choices') | Select-Object -First 1) 'delta') 'content') }) -join '')
    $r.Thinking = (@($objs | ForEach-Object { $d = Get-Prop (@(Get-Prop $_ 'choices') | Select-Object -First 1) 'delta'; $x = Get-Prop $d 'reasoning_content'; if ($null -eq $x) { $x = Get-Prop $d 'reasoning' }; [string]$x }) -join '')
  }
  $r.Think = $r.Thinking.Length
  return $true
}
function Get-AssistantMessage([int]$T) {
  $m = [ordered]@{ role = 'assistant'; content = $L[$T].Content }
  if ($L[$T].Thinking) { if ($Server -eq 'ollama') { $m.thinking = $L[$T].Thinking } else { $m.reasoning_content = $L[$T].Thinking } }
  return $m
}

if ($Opt.SkipLive) { $LiveNote = '-SkipLive given' }
elseif (-not $Server) { $LiveNote = $ServerNote }
elseif (-not $Model) { $LiveNote = 'no model available on the server (pass -Model)'; Write-Warn $LiveNote }
else {
  Out-Heading "Live cache test ($Model)"
  if ($Server -eq 'ollama') {
    try { $show = Invoke-RestMethod -Uri "$Url/api/show" -Method Post -Body (@{ model = $Model } | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec 10 }
    catch { Write-Err "model '$Model' not found on Ollama"; Exit-Tool 3 }
    if (@(Get-Prop $show 'capabilities') -contains 'thinking') { $ThinkMode = $true }
  }
  if ($ThinkMode) { Out-Progress 'model supports thinking; reasoning enabled for all turns' }
  $LiveStatus = 'ok'
  try {
    Out-Progress 'request 1/4: prefix + question A (includes model load if not loaded)'
    $msgs = @([ordered]@{ role = 'system'; content = $PrefixText }, [ordered]@{ role = 'user'; content = $Questions[1] })
    if (-not (Send-Turn 1 $msgs)) { throw 'request 1 failed' }
    $LiveStart = Get-Date   # model load excluded from the time budget
    Out-Progress 'request 2/4: same prefix + question B'
    $msgs = @([ordered]@{ role = 'system'; content = $PrefixText }, [ordered]@{ role = 'user'; content = $Questions[2] })
    if (-not (Send-Turn 2 $msgs)) { throw 'request 2 failed' }
    Out-Progress 'turn 3/4: conversation + question C'
    $msgs = $msgs + @((Get-AssistantMessage 2), [ordered]@{ role = 'user'; content = $Questions[3] })
    if (-not (Send-Turn 3 $msgs)) { throw 'turn 3 failed' }
    Out-Progress 'turn 4/4: conversation + question D'
    $msgs = $msgs + @((Get-AssistantMessage 3), [ordered]@{ role = 'user'; content = $Questions[4] })
    if (-not (Send-Turn 4 $msgs)) { throw 'turn 4 failed' }
  } catch { $LiveStatus = 'error'; $LiveNote = "a live request failed: $($_.Exception.Message)"; Write-Err $LiveNote }
  $LiveEnd = Get-Date
  $CounterSrc = $L[2].Src
  foreach ($t in 1..4) {
    if ($null -ne $L[$t].Ttft) {
      $cv = $L[$t].Cached; if ($null -eq $cv) { $cv = 'n/a' }
      Out-Progress ("turn {0}: TTFT {1}s, total {2}s, prompt {3}, cached {4}, reasoning {5} chars" -f $t, (Format-S $L[$t].Ttft), (Format-S $L[$t].Total), (Format-N $L[$t].Prompt), (Format-N $cv), $L[$t].Think)
    }
  }
}

# ---------------------------------------------------------------------------
# C2: Ollama context window, with the model's trained maximum
# ---------------------------------------------------------------------------
$Ctx = $null; $ModelMax = $null; $C2Capped = $false
try {
  if ($Server -ne 'ollama') { Add-Result 'C2' 'Ollama context window' 'SKIP' 'Ollama not installed or not the selected server' }
  else {
    if (Get-Command ollama -ErrorAction SilentlyContinue) {
      $oldHost = $env:OLLAMA_HOST; $env:OLLAMA_HOST = $Url   # process-local, restored below
      try { $psOut = @(& ollama ps 2>$null) } catch { $psOut = @() } finally { $env:OLLAMA_HOST = $oldHost }
      if ($psOut.Count -gt 1 -and $psOut[0] -match 'CONTEXT') {
        foreach ($row in $psOut[1..($psOut.Count - 1)]) {
          $f = $row -split '\s+'
          if ($Model -and $f[0] -ne $Model) { continue }
          foreach ($x in $f[1..($f.Count - 1)]) { $v = 0; if ([int]::TryParse($x, [ref]$v) -and $v -ge 512) { $Ctx = $v; break } }
          if ($Ctx) { break }
        }
      }
    }
    if (-not $Ctx) {
      try { $ps = Invoke-RestMethod -Uri "$Url/api/ps" -TimeoutSec 5
        foreach ($m in @(Get-Prop $ps 'models')) { if ($m -and (-not $Model -or $m.name -eq $Model)) { $Ctx = Get-Prop $m 'context_length'; if ($Ctx) { break } } } } catch { $null = $_ }  # optional data; fall back below
    }
    if ($Model) {
      try {
        $show2 = Invoke-RestMethod -Uri "$Url/api/show" -Method Post -Body (@{ model = $Model } | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec 10
        $info = Get-Prop $show2 'model_info'
        $arch = [string](Get-Prop $info 'general.architecture')
        $ModelMax = Get-Prop $info "$arch.context_length"
        if ($null -eq $ModelMax -and $info) { $p = @($info.PSObject.Properties | Where-Object { $_.Name -like '*.context_length' }) | Select-Object -First 1; if ($p) { $ModelMax = $p.Value } }
      } catch { $null = $_ }  # optional data; fall back below
      if ($null -eq $ModelMax) { Write-Warn "could not read the trained context length of $Model from /api/show" } else { $ModelMax = [long]$ModelMax }
    }
    $maxTxt = ''; if ($ModelMax) { $maxTxt = "; model maximum $(Format-N $ModelMax)" }
    if ($Ctx) { $Ctx = [long]$Ctx }
    if ($Ctx -and $ModelMax -and $Ctx -lt 64000 -and $Ctx -ge $ModelMax) { $C2Capped = $true; $cdet = "Context $(Format-N $Ctx) = model maximum $(Format-N $ModelMax); setting cannot raise it" }
    else { $cdet = "Context $(Format-N $Ctx), minimum 64,000$maxTxt" }
    if (-not $Ctx) { Add-Result 'C2' 'Ollama context window' 'SKIP' 'No model loaded (run without -SkipLive, or load a model)' }
    elseif ($Ctx -ge 64000) { Add-Result 'C2' 'Ollama context window' 'PASS' "Context $(Format-N $Ctx)$maxTxt" }
    elseif ($Ctx -ge 32000) { Add-Result 'C2' 'Ollama context window' 'WARN' $cdet }
    else { Add-Result 'C2' 'Ollama context window' 'FAIL' $cdet }
  }
} catch { Add-Result 'C2' 'Ollama context window' 'ERROR' $_.Exception.Message }

# ---------------------------------------------------------------------------
# C3: Hybrid model and prompt reprocessing (only log lines written during this run)
# ---------------------------------------------------------------------------
$Hybrid = $false; $HybridPat = ''; $ReproSession = 0; $ReproTotal = 0
try {
  if ($Model) {
    foreach ($raw in [IO.File]::ReadAllLines($Script:HybridFile)) {
      $pat = ($raw -replace '#.*$', '').Trim()
      if (-not $pat) { continue }
      if ($Model -match $pat) { $Hybrid = $true; $HybridPat = $pat; break }
    }
  }
  if ($LogFile -and (Test-Path -LiteralPath $LogFile)) {
    $ReproTotal = @(Select-String -LiteralPath $LogFile -Pattern 'full prompt reprocessing' -SimpleMatch).Count
    $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
    try { [void]$fs.Seek([Math]::Min($LogStart, $fs.Length), 'Begin'); $newText = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Close() }
    $ReproSession = ([regex]::Matches($newText, 'full prompt reprocessing', 'IgnoreCase')).Count
    if ($ReproSession -gt 0) { Add-Result 'C3' 'Hybrid model and prompt reprocessing' 'FAIL' "Log shows full prompt reprocessing $ReproSession time(s) this session" }
    elseif ($Hybrid) { Add-Result 'C3' 'Hybrid model and prompt reprocessing' 'WARN' "Hybrid model (matches '$HybridPat'), no reprocessing message yet" }
    else { $nh = ''; if ($Model) { $nh = 'Not hybrid; ' }; Add-Result 'C3' 'Hybrid model and prompt reprocessing' 'PASS' "${nh}no reprocessing message in log" }
  } elseif ($Hybrid) { Add-Result 'C3' 'Hybrid model and prompt reprocessing' 'WARN' "Hybrid model (matches '$HybridPat'); server log not found" }
  else { Add-Result 'C3' 'Hybrid model and prompt reprocessing' 'SKIP' 'Server log not found and model not in hybrid list' }
} catch { Add-Result 'C3' 'Hybrid model and prompt reprocessing' 'ERROR' $_.Exception.Message }

# ---------------------------------------------------------------------------
# C4: Frontend cache tokens
# ---------------------------------------------------------------------------
$SessionHits = $null; $SessionLines = 0
if ($Opt.SessionLog) {
  $ms = [regex]::Matches([IO.File]::ReadAllText($Opt.SessionLog), '"(cache_read_input_tokens|cached_tokens|cache_n)"\s*:\s*(\d+)')
  $SessionLines = $ms.Count; $SessionHits = 0L; foreach ($m in $ms) { $SessionHits += [long]$m.Groups[2].Value }
}
function Get-SessionSuffix { if ($Opt.SessionLog) { return "; session log: $(Format-N $SessionHits) cache-hit tokens in $SessionLines entries" }; return '' }
function Get-HybridHint { if ($Hybrid) { return '; hybrid model, likely checkpoint limit (see C3)' }; return '' }
try {
  if ($LiveStatus -eq 'skipped') { $ln = ''; if ($LiveNote) { $ln = " ($LiveNote)" }; Add-Result 'C4' 'Frontend cache tokens' 'SKIP' "Live test skipped$ln" }
  elseif ($null -eq $L[2].Ttft) { Add-Result 'C4' 'Frontend cache tokens' 'ERROR' 'Request 2 did not complete' }
  elseif ($null -eq $L[2].Cached) {
    $ratio = '?'; if ($L[1].Ttft -gt 0) { $ratio = [Math]::Round(100 * $L[2].Ttft / $L[1].Ttft) }
    Add-Result 'C4' 'Frontend cache tokens' 'WARN' ("Server-side counter not reported; TTFT {0}s vs {1}s ({2}%){3}" -f (Format-S $L[2].Ttft), (Format-S $L[1].Ttft), $ratio, (Get-SessionSuffix))
  } else {
    $p2 = [long]$L[2].Prompt; $c2 = [long]$L[2].Cached
    $pct = 0; if ($p2 -gt 0) { $pct = [Math]::Round(100.0 * $c2 / $p2) }
    if ($c2 -eq 0) { Add-Result 'C4' 'Frontend cache tokens' 'FAIL' "Cached 0 of $(Format-N $p2) prompt tokens on request 2 (identical prefix)$(Get-HybridHint)$(Get-SessionSuffix)" }
    elseif ($p2 -gt 0 -and $c2 * 100 -ge $p2 * 80) {
      if ($Opt.SessionLog -and $SessionLines -gt 0 -and $SessionHits -eq 0) { Add-Result 'C4' 'Frontend cache tokens' 'WARN' "Server caches ($(Format-N $c2)/$(Format-N $p2)) but the session log shows 0 cache-hit tokens" }
      else { Add-Result 'C4' 'Frontend cache tokens' 'PASS' "Cached $(Format-N $c2) of $(Format-N $p2) prompt tokens ($pct%)$(Get-SessionSuffix)" }
    } else { Add-Result 'C4' 'Frontend cache tokens' 'WARN' "Cached $(Format-N $c2) of $(Format-N $p2) prompt tokens ($pct%), below 80%$(Get-HybridHint)$(Get-SessionSuffix)" }
  }
} catch { Add-Result 'C4' 'Frontend cache tokens' 'ERROR' $_.Exception.Message }

# ---------------------------------------------------------------------------
# C5: Thinking tokens preserved (turns 2 -> 3 -> 4)
# ---------------------------------------------------------------------------
try {
  $anyThink = $false; foreach ($t in 1..4) { if ($L[$t].Think -gt 0) { $anyThink = $true } }
  if ($LiveStatus -eq 'skipped') { Add-Result 'C5' 'Thinking tokens preserved' 'SKIP' 'Live test skipped' }
  elseif ($null -eq $L[4].Ttft) { Add-Result 'C5' 'Thinking tokens preserved' 'ERROR' 'Turns 3-4 did not complete' }
  elseif (-not $anyThink) { Add-Result 'C5' 'Thinking tokens preserved' 'SKIP' 'Model produced no reasoning output' }
  elseif ($null -eq $L[2].Cached -or $null -eq $L[3].Cached -or $null -eq $L[4].Cached) { Add-Result 'C5' 'Thinking tokens preserved' 'ERROR' 'Server did not report cache counters for turns 2-4' }
  else {
    $d3 = $L[3].Cached -lt $L[2].Cached; $d4 = $L[4].Cached -lt $L[3].Cached
    $seq = '{0} -> {1} -> {2}' -f (Format-N $L[2].Cached), (Format-N $L[3].Cached), (Format-N $L[4].Cached)
    if ($d3 -and $d4) { Add-Result 'C5' 'Thinking tokens preserved' 'FAIL' "Cache dropped on turns 3 and 4 ($seq)" }
    elseif ($d3 -or $d4) { Add-Result 'C5' 'Thinking tokens preserved' 'WARN' "Cache dropped once ($seq)" }
    else { Add-Result 'C5' 'Thinking tokens preserved' 'PASS' "Cache grew on turns 2, 3, 4 ($seq)" }
  }
} catch { Add-Result 'C5' 'Thinking tokens preserved' 'ERROR' $_.Exception.Message }

# ---------------------------------------------------------------------------
# Score and exit code (spec 3.1, 8)
# ---------------------------------------------------------------------------
$cnt = @{ PASS = 0; WARN = 0; FAIL = 0; SKIP = 0; ERROR = 0 }
foreach ($r in $Results) { $cnt[$r.Res]++ }
$nScored = $cnt.PASS + $cnt.WARN + $cnt.FAIL; $nExcl = $cnt.SKIP + $cnt.ERROR
$Score = $null; $ScoreTxt = 'n/a'
if ($nScored -gt 0) { $Score = [int][Math]::Round(100.0 * ($cnt.PASS + 0.5 * $cnt.WARN) / $nScored, [MidpointRounding]::AwayFromZero); $ScoreTxt = "$Score%" }
$ExitCode = 0; if ($cnt.FAIL -gt 0) { $ExitCode = 2 } elseif ($cnt.WARN -gt 0) { $ExitCode = 1 }

# ---------------------------------------------------------------------------
# Recommendations (spec 7.3): found / why / fix on Windows / verify
# ---------------------------------------------------------------------------
function Get-Recommendation([string]$Id, [string]$Detail) {
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine("**Found:** $Detail"); [void]$sb.AppendLine()
  switch ($Id) {
    'C1' {
      [void]$sb.AppendLine('**Why it matters:** older Claude Code versions send an attribution header that changes the start of every request, so the server can never reuse its prompt cache.'); [void]$sb.AppendLine()
      [void]$sb.AppendLine('**Fix on Windows:**')
      [void]$sb.AppendLine('- Run `claude update`, or reinstall using the official installer. Open a new PowerShell window afterwards so the updated binary is on the path.')
      [void]$sb.AppendLine('- If an update is not possible, set the variable for your user account and restart the terminal: `[Environment]::SetEnvironmentVariable(''CLAUDE_CODE_ATTRIBUTION_HEADER'', ''0'', ''User'')`')
      [void]$sb.AppendLine('- If Claude Code is started from a shortcut or desktop launcher, quit it and start it again after setting the variable. Environment changes apply only to processes started after the change.')
    }
    'C2' {
      [void]$sb.AppendLine('**Why it matters:** an agent''s first request (about 33,000 tokens for Claude Code) does not fit in a small context window, so Ollama truncates the prompt and the cached prefix no longer matches.'); [void]$sb.AppendLine()
      [void]$sb.AppendLine('**Fix on Windows:**')
      if ($C2Capped) {
        [void]$sb.AppendLine("- This model was trained with a maximum context of $(Format-N $ModelMax) tokens, and Ollama never loads it with more. Raising ``OLLAMA_CONTEXT_LENGTH`` will not change it.")
        [void]$sb.AppendLine('- Use a model with a larger trained context window (64,000 tokens or more) for agent sessions. Check a model''s limit with `ollama show <model>` (the "context length" line) before choosing it.')
        [void]$sb.AppendLine('- Re-run the tool with that model (`-Model <model>` or the interactive picker) and confirm C2 shows PASS.')
      } else {
        $mx = ''; if ($ModelMax) { $mx = " This model supports up to $(Format-N $ModelMax) tokens (``ollama show $Model``)." }
        [void]$sb.AppendLine("- Run ``ollama ps`` and note the CONTEXT column.$mx")
        [void]$sb.AppendLine('- Set the context length to at least 64000. Set the user environment variable: `[Environment]::SetEnvironmentVariable(''OLLAMA_CONTEXT_LENGTH'', ''65536'', ''User'')` (or `setx OLLAMA_CONTEXT_LENGTH 65536`). Then quit Ollama from the system tray icon and start it again. If your Ollama version has a context length option in its Settings window, you can use that instead.')
        [void]$sb.AppendLine('- Run `ollama ps` again to confirm the new value. Ollama must reload the model before the change applies.')
        [void]$sb.AppendLine('- Higher context uses more memory. Check Task Manager''s Performance tab for GPU memory use after the change. If the model spills into system memory, choose a smaller model or a smaller context value.')
      }
    }
    'C3' {
      [void]$sb.AppendLine('**Why it matters:** hybrid (SSM / recurrent) models cannot rewind their state past a checkpoint, so when the prompt changes the server may re-read the whole prompt from scratch ("full prompt reprocessing").'); [void]$sb.AppendLine()
      [void]$sb.AppendLine('**Fix on Windows:**')
      [void]$sb.AppendLine('- Find the log and search it: `Select-String -Path "$env:LOCALAPPDATA\Ollama\server.log" -Pattern "full prompt reprocessing"` (LM Studio: the newest file in `%USERPROFILE%\.lmstudio\server-logs\`).')
      [void]$sb.AppendLine('- For llama.cpp, start `llama-server.exe` with `-v 4` (or `--verbosity 4`) to see the cache-related log lines.')
      [void]$sb.AppendLine('- If the model is hybrid and reprocessing appears every turn, switch to a non-hybrid model for agent sessions, or accept the cold-read cost and keep sessions short.')
    }
    'C4' {
      [void]$sb.AppendLine('**Why it matters:** if the cached-token count stays near zero while the prefix is identical, every turn re-reads the whole prompt and time to first token grows with the conversation.'); [void]$sb.AppendLine()
      [void]$sb.AppendLine('**Fix on Windows:**')
      [void]$sb.AppendLine('- Confirm the server reports cache counters. If it does not, update the server (for Ollama, download the latest installer from ollama.com or run `winget upgrade Ollama.Ollama`).')
      [void]$sb.AppendLine('- Test the frontend itself: run a short agent session, then check the cache-token counter the server logs (for Ollama, `%LOCALAPPDATA%\Ollama\server.log`). Zero cached tokens deep into a session means the frontend is changing the prompt prefix between turns.')
      [void]$sb.AppendLine('- Try another frontend that caches correctly, and compare the cache counter for the same task.')
    }
    'C5' {
      [void]$sb.AppendLine('**Why it matters:** when reasoning output is removed from the history between turns, the conversation no longer matches what the server cached, so cached tokens fall and the prompt is re-read.'); [void]$sb.AppendLine()
      [void]$sb.AppendLine('**Fix on Windows:**')
      [void]$sb.AppendLine('- Find the setting in your frontend that controls whether reasoning output is kept in conversation history. Turn on preserved or kept thinking.')
      [void]$sb.AppendLine('- If the frontend has no such setting, report the issue to its maintainer and consider a frontend that preserves thinking.')
      [void]$sb.AppendLine('- Re-run the tool and confirm that cached tokens grow on each turn.')
    }
  }
  [void]$sb.AppendLine(); [void]$sb.AppendLine('**Verify:** re-run `Invoke-LocalLLMCheckup.ps1` and confirm this item shows PASS.')
  return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Markdown report (spec 7)
# ---------------------------------------------------------------------------
function Get-Na($v) { if ($null -eq $v -or "$v" -eq '') { return 'n/a' }; return "$v" }
$md = New-Object Text.StringBuilder
function Add-Md([string]$T) { [void]$md.Append($T).Append("`n") }
Add-Md '# Local LLM Checkup (Windows)'; Add-Md ''
Add-Md "Generated $StartHuman by Invoke-LocalLLMCheckup.ps1 $Script:Version"; Add-Md ''
Add-Md '## Environment'; Add-Md ''
Add-Md "- Windows: $OsText"; Add-Md "- CPU: $CpuText"; Add-Md "- Memory: $MemText"; Add-Md "- GPU: $GpuText"
Add-Md "- PowerShell: $PsText"
Add-Md "- Ollama: $(if ($OllamaVer) { $OllamaVer } else { 'not found' })"
Add-Md "- LM Studio: $(if ($LmsVer) { $LmsVer } else { 'not found' })"
Add-Md "- llama.cpp: $(if ($LlamaVer) { $LlamaVer.Trim() } else { 'not found' })"
Add-Md "- Claude Code: $(if ($ClaudeVer) { $ClaudeVer } else { 'not found' })"
Add-Md "- Selected server: $(Get-ServerLabel $Server)"; Add-Md "- Endpoint: $(Get-Na $Url)"
$mn = ''; if ($ModelNote) { $mn = " ($ModelNote)" }
Add-Md "- Model: $(Get-Na $Model)$mn"
Add-Md "- Model trained context (max): $(if ($ModelMax) { Format-N $ModelMax } else { 'n/a' })"
Add-Md "- Model chosen by: $(Get-Na $ModelSource)"; Add-Md "- Config file: $(if ($ConfigUsed) { $ConfigUsed } else { 'none' })"
Add-Md "- Server log: $(if ($LogFile) { $LogFile } else { 'not found' })"; Add-Md ''
Add-Md '## Summary'; Add-Md ''
Add-Md "**Overall score: $ScoreTxt** ($nScored items scored, $nExcl excluded)"; Add-Md ''
Add-Md '| PASS | WARN | FAIL | SKIP | ERROR |'; Add-Md '|------|------|------|------|-------|'
Add-Md "| $($cnt.PASS) | $($cnt.WARN) | $($cnt.FAIL) | $($cnt.SKIP) | $($cnt.ERROR) |"; Add-Md ''
Add-Md '## Results'; Add-Md ''
Add-Md '| ID | Item | Result | Score | Detail |'; Add-Md '|----|------|--------|-------|--------|'
foreach ($r in $Results) { Add-Md ("| {0} | {1} | {2} | {3} | {4} |" -f $r.Id, $r.Name, $r.Res, $r.Score, ($r.Detail -replace '\|', '\|')) }
$errTxt = ''; if ($cnt.ERROR -gt 0) { $errTxt = ", $($cnt.ERROR) errored" }
Add-Md "| | **Overall** | | **$ScoreTxt** | $nScored items scored, $($cnt.SKIP) skipped$errTxt |"; Add-Md ''
Add-Md '## Live test details'; Add-Md ''
if ($LiveStatus -eq 'skipped') { Add-Md "Live test skipped: $(Get-Na $LiveNote)."; Add-Md '' }
else {
  $th = 'not requested (model has no thinking capability or server is OpenAI-compatible)'; if ($ThinkMode) { $th = 'enabled' }
  $cs = $CounterSrc; if (-not $cs) { $cs = 'server-side counter not reported' }
  Add-Md ("Prefix: ``prefix.txt`` ({0} bytes, identical on every run). max_tokens: {1}. Reasoning: {2}. Cache counter: {3}." -f (Get-Item -LiteralPath $Script:PrefixFile).Length, $Script:MaxTokens, $th, $cs); Add-Md ''
  Add-Md '| Turn | Request | TTFT (s) | Total (s) | Prompt tokens | Cached tokens | Reasoning chars |'
  Add-Md '|------|---------|----------|-----------|---------------|---------------|-----------------|'
  $desc = @('', 'prefix + question A', 'prefix + question B', 'turn 2 + answer + question C', 'turn 3 + answer + question D')
  foreach ($t in 1..4) {
    $ttft = '-'; $tot = '-'; $thk = '-'
    if ($null -ne $L[$t].Ttft) { $ttft = Format-S $L[$t].Ttft; $tot = Format-S $L[$t].Total; $thk = $L[$t].Think }
    Add-Md ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $t, $desc[$t], $ttft, $tot, (Format-N $L[$t].Prompt), (Format-N $L[$t].Cached), $thk)
  }
  if ($LiveStart -and $LiveEnd) { Add-Md ''; Add-Md ("Turns 2-4 took {0}s (after model load and request 1)." -f [int]($LiveEnd - $LiveStart).TotalSeconds) }
  if ($Ctx) { Add-Md ''; Add-Md ("Loaded context (ollama ps): {0}; model trained maximum: {1}." -f (Format-N $Ctx), $(if ($ModelMax) { Format-N $ModelMax } else { 'n/a' })) }
  if ($LiveNote) { Add-Md ''; Add-Md "Note: $LiveNote." }
  Add-Md ''
}
Add-Md '## Recommendations'; Add-Md ''
$any = $false
foreach ($r in $Results) {
  if ($r.Res -eq 'PASS') { continue }
  $any = $true
  if ($r.Res -eq 'SKIP') { Add-Md "### $($r.Id) $($r.Name) (SKIP)"; Add-Md ''; Add-Md "**Found:** $($r.Detail)"; Add-Md ''; Add-Md 'Not applicable on this system; no action needed unless you expected this check to run.'; Add-Md ''; continue }
  Add-Md "### $($r.Id) $($r.Name) ($($r.Res))"; Add-Md ''
  Add-Md ((Get-Recommendation $r.Id $r.Detail) -replace "`r", '')
}
if (-not $any) { Add-Md 'All items passed. No action needed.'; Add-Md '' }
Add-Md '## Notes and limitations'; Add-Md ''
Add-Md '- This tool only reads configuration and sends test requests; it changes no settings, environment variables or files outside the report directory.'
Add-Md '- Pass/fail decisions use server cache counters, not timing. Timings are for information and vary with load.'
Add-Md '- "Prompt tokens" on request 2 is used as the shared prefix size; the differing question adds roughly 20 tokens.'
Add-Md "- C3 counts ``full prompt reprocessing`` only in log lines written during this run ($ReproTotal occurrence(s) in the whole log). Ollama and LM Studio may not log this phrase; llama.cpp logs it at verbosity 4."
Add-Md '- The hybrid model list (`hybrid-models.txt`) is pattern based and may not cover new or renamed models.'
Add-Md "- The live test leaves the model loaded (Ollama keep_alive $($Script:KeepAlive)) so the cache persists between requests."
if ($ServerNote) { Add-Md "- $ServerNote." }
$MdText = $md.ToString()
try { [IO.File]::WriteAllText($Report, $MdText, $Script:Utf8NoBom) } catch { Write-Err "could not write report: $Report ($($_.Exception.Message))"; Exit-Tool 3 }

# ---------------------------------------------------------------------------
# HTML copy (spec 7.4). ConvertFrom-Markdown (PowerShell 7+) when available,
# otherwise a built-in converter for exactly what the report uses. Failures are
# logged and never change the markdown report or the exit code.
# ---------------------------------------------------------------------------
function ConvertTo-HtmlEsc([string]$S) { return $S.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }
function Format-Inline([string]$S) {
  # Input is already HTML-escaped. Code spans first (odd segments), then bold and links.
  $parts = $S.Split('`'); $out = New-Object Text.StringBuilder
  if ($parts.Count % 2 -eq 0) { $parts = @($S) }
  for ($k = 0; $k -lt $parts.Count; $k++) {
    if ($k % 2 -eq 1) { [void]$out.Append("<code>$($parts[$k])</code>") }
    else {
      $t = [regex]::Replace($parts[$k], '\*\*([^*]+)\*\*', '<strong>$1</strong>')
      $t = [regex]::Replace($t, '\[([^\]]*)\]\(([^) ]*)\)', '<a href="$2">$1</a>')
      [void]$out.Append($t)
    }
  }
  return $out.ToString()
}
function Convert-ResultCell([string]$C) {
  $t = $C.Trim()
  if ($t -match '^(PASS|WARN|FAIL|SKIP|ERROR)$') { return "<span class=""badge $($t.ToLowerInvariant())"">$t</span>" }
  return (Format-Inline $C)
}
function Convert-MdBody([string]$Text) {
  $o = New-Object Text.StringBuilder
  $para = ''; $inList = $false; $inTable = $false; $hdr = $false; $inCode = $false
  # Dot-sourced (". $closeBlocks") so the assignments below change this function's variables.
  $closeBlocks = {
    if ($para) { [void]$o.AppendLine("<p>$(Format-Inline $para)</p>"); $para = '' }
    if ($inList) { [void]$o.AppendLine('</ul>'); $inList = $false }
    if ($inTable) { [void]$o.AppendLine('</tbody></table>'); $inTable = $false }
  }
  $cells = {
    param([string]$Line, [string]$Tag)
    $Line = $Line.Replace('\|', [string][char]1).Trim()
    if ($Line.StartsWith('|')) { $Line = $Line.Substring(1) }; if ($Line.EndsWith('|')) { $Line = $Line.Substring(0, $Line.Length - 1) }
    $row = '<tr>'
    foreach ($c in $Line.Split('|')) { $c = $c.Trim().Replace([string][char]1, '|'); if ($Tag -eq 'td') { $row += "<td>$(Convert-ResultCell $c)</td>" } else { $row += "<th>$(Format-Inline $c)</th>" } }
    return $row + '</tr>'
  }
  $lines = $Text.Replace("`r", '').Split("`n")
  for ($n = 1; $n -lt $lines.Count; $n++) {   # line 0 is the title, emitted as <h1> by the caller
    $raw = $lines[$n]
    if ($inCode) { if ($raw.StartsWith('```')) { [void]$o.AppendLine('</code></pre>'); $inCode = $false } else { [void]$o.AppendLine((ConvertTo-HtmlEsc $raw)) }; continue }
    if ($raw.StartsWith('```')) { . $closeBlocks; [void]$o.Append('<pre><code>'); $inCode = $true; continue }
    $line = ConvertTo-HtmlEsc $raw
    if ($line -match '^(#+) (.*)$') { . $closeBlocks; $lv = $Matches[1].Length; [void]$o.AppendLine("<h$lv>$(Format-Inline $Matches[2])</h$lv>"); continue }
    if ($line -match '^\s*\|') {
      if (-not $inTable) { . $closeBlocks; [void]$o.AppendLine("<table><thead>$(& $cells $line 'th')</thead><tbody>"); $inTable = $true; $hdr = $true; continue }
      if ($hdr -and $line -match '^\s*\|[-| :]+\|\s*$') { $hdr = $false; continue }
      $hdr = $false; [void]$o.AppendLine((& $cells $line 'td')); continue
    }
    if ($line.StartsWith('- ')) {
      if ($para) { [void]$o.AppendLine("<p>$(Format-Inline $para)</p>"); $para = '' }
      if ($inTable) { [void]$o.AppendLine('</tbody></table>'); $inTable = $false }
      if (-not $inList) { [void]$o.AppendLine('<ul>'); $inList = $true }
      [void]$o.AppendLine("<li>$(Format-Inline $line.Substring(2))</li>"); continue
    }
    if ($line.Trim() -eq '') { . $closeBlocks; continue }
    if ($inList -or $inTable) { . $closeBlocks }
    if ($para) { $para = "$para $line" } else { $para = $line }
  }
  . $closeBlocks
  if ($inCode) { [void]$o.AppendLine('</code></pre>') }
  return $o.ToString()
}
function Write-HtmlReport([string]$MdPath, [string]$HtmlPath, [string]$Text) {
  $title = ConvertTo-HtmlEsc (($Text.Split("`n")[0]) -replace '^#\s*', '')
  $body = $null
  if (Get-Command ConvertFrom-Markdown -ErrorAction SilentlyContinue) {
    try {
      $body = (ConvertFrom-Markdown -InputObject $Text).Html
      # Badge the result cells produced by Markdig (<td>PASS</td> etc.).
      $body = [regex]::Replace($body, '<td>(PASS|WARN|FAIL|SKIP|ERROR)</td>', { param($m) "<td><span class=""badge $($m.Groups[1].Value.ToLowerInvariant())"">$($m.Groups[1].Value)</span></td>" })
    } catch { $body = $null }
  }
  if (-not $body) { $body = "<h1>$title</h1>`n" + (Convert-MdBody $Text) }
  $css = @'
body { font: 15px/1.55 "Segoe UI", -apple-system, "Helvetica Neue", Arial, sans-serif; color: #1d1d1f; background: #fafafa; max-width: 980px; margin: 2em auto; padding: 0 1.2em; }
h1 { font-size: 1.8em; border-bottom: 2px solid #ddd; padding-bottom: .3em; }
h2 { font-size: 1.35em; margin-top: 1.8em; border-bottom: 1px solid #e5e5e5; padding-bottom: .2em; }
h3 { font-size: 1.1em; margin-top: 1.4em; }
code { font: .9em Consolas, ui-monospace, Menlo, monospace; background: #eee; padding: .1em .35em; border-radius: 4px; }
pre { background: #f0f0f0; padding: .8em 1em; border-radius: 6px; overflow-x: auto; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; margin: 1em 0; width: 100%; background: #fff; }
th, td { border: 1px solid #ddd; padding: .45em .7em; text-align: left; vertical-align: top; }
th { background: #f2f2f2; }
tr:nth-child(even) td { background: #fbfbfb; }
.badge { display: inline-block; min-width: 3.6em; text-align: center; font-weight: 600; font-size: .85em; padding: .15em .5em; border-radius: 999px; color: #fff; }
.pass { background: #1e8e3e; } .warn { background: #e8a10c; } .fail { background: #d93025; }
.skip { background: #8a8a8a; } .error { background: #a50e0e; }
a { color: #0b57d0; }
'@
  $html = "<!DOCTYPE html>`n<html lang=""en"">`n<head>`n<meta charset=""utf-8"">`n<meta name=""viewport"" content=""width=device-width, initial-scale=1"">`n<title>$title</title>`n<style>`n$css</style>`n</head>`n<body>`n$body</body>`n</html>`n"
  [IO.File]::WriteAllText($HtmlPath, $html, $Script:Utf8NoBom)
}
$ReportHtml = [IO.Path]::ChangeExtension($Report, '.html')
try { Write-HtmlReport $Report $ReportHtml $MdText }
catch { Write-Err "could not write HTML report ${ReportHtml}: $($_.Exception.Message)"; $ReportHtml = '' }

# ---------------------------------------------------------------------------
# Final summary and opening the report (spec 6)
# ---------------------------------------------------------------------------
Out-Heading 'Summary'
$sc = ''; if ($null -ne $Score) { if ($Score -ge 80) { $sc = $C.G } elseif ($Score -ge 50) { $sc = $C.Y } else { $sc = $C.R } }
Out-Line ("  Overall score: {0}{1}{2}{3}  (PASS {4}, WARN {5}, FAIL {6}, SKIP {7}, ERROR {8})" -f $C.B, $sc, $ScoreTxt, $C.O, $cnt.PASS, $cnt.WARN, $cnt.FAIL, $cnt.SKIP, $cnt.ERROR)
Out-Line "  Report: $Report"
if ($ReportHtml) { Out-Line "  HTML:   $ReportHtml" }
# Open only on Windows, in an interactive console, outside CI and remote sessions.
$remote = (Test-Path variable:PSSenderInfo) -and $null -ne $PSSenderInfo
if ($ReportHtml -and $Opt.Open -ne $false -and $Script:OnWindows -and (Test-Tty) -and -not $env:CI -and -not $remote) {
  try { Start-Process -FilePath (Resolve-Path -LiteralPath $ReportHtml).Path; Out-Line '  Opened the HTML report in your default browser.' }
  catch { Write-Err "could not open ${ReportHtml}: $($_.Exception.Message)" }
}
exit $ExitCode
