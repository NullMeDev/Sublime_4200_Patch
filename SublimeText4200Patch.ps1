param()

$patches = @(
  @{ Find="74 06 3B"; Replace="EB 06 3B"; Min=1; Max=1 },
  @{ Find="89 F8 48 81 C4 38 02"; Replace="33 C0 48 81 C4 38 02"; Min=0; Max=5 },
  @{ Find="E8 F4 7F 10 00"; Replace="90 90 90 90 90"; Min=0; Max=10 },
  @{ Find="41 57 41 56 41 54 56 57 53 48 83 EC 38 4C 89 CE 4C 89 C7 48 89 D3 49 89 CE 4C"; Replace="90 90 41 56 41 54 56 57 53 48 83 EC 38 4C 89 CE 4C 89 C7 48 89 D3 49 89 CE 4C"; Min=0; Max=2 }
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process -FilePath "powershell" -ArgumentList "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
  exit
}

function To-Bytes($hex) {
  $h = ($hex -replace '\s','').ToUpper()
  if ($h.Length % 2 -ne 0) { throw "Hex length must be even." }
  $b = New-Object byte[] ($h.Length/2)
  for ($i=0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($h.Substring($i*2,2),16) }
  $b
}

function Index-OfBytes([byte[]]$haystack,[byte[]]$needle,[int]$start) {
  if ($needle.Length -eq 0) { return -1 }
  for ($i=$start; $i -le $haystack.Length-$needle.Length; $i++) {
    $j=0
    while ($j -lt $needle.Length -and $haystack[$i+$j] -eq $needle[$j]) { $j++ }
    if ($j -eq $needle.Length) { return $i }
  }
  -1
}

function Count-Bytes([byte[]]$haystack,[byte[]]$needle,[int]$start,[int]$last) {
  if ($needle.Length -eq 0) { return 0 }
  $count = 0
  $pos = $start
  while ($pos -le $last) {
    $idx = Index-OfBytes $haystack $needle $pos
    if ($idx -lt 0 -or $idx -gt $last) { break }
    $count++
    $pos = $idx + $needle.Length
  }
  $count
}

function Resolve-TargetPath {
  $candidates = @(
    "C:\Program Files\Sublime Text\sublime_text.exe",
    "C:\Program Files (x86)\Sublime Text\sublime_text.exe"
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { return (Resolve-Path -LiteralPath $p).Path }
  }
  try {
    $appPath = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\sublime_text.exe" -ErrorAction Stop).'(Default)'
    if ($appPath -and (Test-Path -LiteralPath $appPath)) { return (Resolve-Path -LiteralPath $appPath).Path }
  } catch {}
  $uninstRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
  )
  foreach ($root in $uninstRoots) {
    try {
      $keys = Get-ChildItem $root -ErrorAction Stop
      foreach ($k in $keys) {
        $p = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue)
        if ($p -and ($p.DisplayName -like "*Sublime Text*")) {
          if ($p.InstallLocation) {
            $exe = Join-Path $p.InstallLocation "sublime_text.exe"
            if (Test-Path -LiteralPath $exe) { return (Resolve-Path -LiteralPath $exe).Path }
          }
          if ($p.DisplayIcon) {
            $icon = $p.DisplayIcon.Trim('"')
            if (Test-Path -LiteralPath $icon) {
              if ($icon.ToLower().EndsWith(".exe")) { return (Resolve-Path -LiteralPath $icon).Path }
              $exe2 = Join-Path (Split-Path $icon) "sublime_text.exe"
              if (Test-Path -LiteralPath $exe2) { return (Resolve-Path -LiteralPath $exe2).Path }
            }
          }
        }
      }
    } catch {}
  }
  throw "Could not locate sublime_text.exe automatically."
}

function Patch-File-InPlace([string]$targetPath, [array]$patchList) {
  $inBytes = [IO.File]::ReadAllBytes($targetPath)
  $work = New-Object byte[] $inBytes.Length
  [Array]::Copy($inBytes,$work,$inBytes.Length)
  $anyChange = $false
  $allRequiredSatisfied = $true
  foreach ($p in $patchList) {
    $find = To-Bytes $p.Find
    $repl = To-Bytes $p.Replace
    if ($find.Length -ne $repl.Length) { throw "Find and Replace must be the same length." }
    $max = if ($p.ContainsKey("Max")) { [int]$p.Max } else { [int]::MaxValue }
    $min = if ($p.ContainsKey("Min")) { [int]$p.Min } else { 1 }
    $offsetStart = if ($p.ContainsKey("OffsetStart")) { [int64]$p.OffsetStart } else { 0 }
    $offsetEnd = if ($p.ContainsKey("OffsetEnd")) { [int64]$p.OffsetEnd } else { [int64]($work.Length-1) }
    if ($offsetStart -lt 0 -or $offsetEnd -ge $work.Length -or $offsetEnd -lt $offsetStart) { throw "Invalid OffsetStart or OffsetEnd." }
    $applied = 0
    $searchStart = [int]$offsetStart
    $last = [int]($offsetEnd - $find.Length + 1)
    while ($searchStart -le $last -and $applied -lt $max) {
      $idx = Index-OfBytes $work $find $searchStart
      if ($idx -lt 0 -or $idx -gt $last) { break }
      [Array]::Copy($repl,0,$work,$idx,$repl.Length)
      $applied++
      $searchStart = $idx + $repl.Length
      $anyChange = $true
    }
    $replLast = [int]($offsetEnd - $repl.Length + 1)
    $already = Count-Bytes $work $repl ([int]$offsetStart) $replLast
    if (($applied + $already) -lt $min) { $allRequiredSatisfied = $false }
  }
  $ts = Get-Date -Format "yyyyMMdd-HHmmss"
  $bakPath = "$targetPath.$ts.bak"
  [IO.File]::WriteAllBytes($bakPath,$inBytes)
  if ($anyChange) {
    $tempOut = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllBytes($tempOut,$work)
    Move-Item -LiteralPath $tempOut -Destination $targetPath -Force
  }
  [pscustomobject]@{
    Modified=$anyChange
    AllRequiredSatisfied=$allRequiredSatisfied
    Backup=$bakPath
  }
}

try {
  $target = Resolve-TargetPath
  $result = Patch-File-InPlace -targetPath $target -patchList $patches
  if ($result.AllRequiredSatisfied) {
    Start-Process -FilePath $target | Out-Null
  } else {
    exit 1
  }
}
catch {
  exit 1
}
