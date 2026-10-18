[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$LogDir,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateRange(1, 999999999)]
    [int]$ThresholdMB,

    [Parameter(Mandatory = $true, Position = 2)]
    [ValidateRange(1, 999999999)]
    [int]$NPercent,

    [Parameter(Mandatory = $true, Position = 3)]
    [ValidateRange(1, 999999999)]
    [int]$MFiles,

    [Parameter(Position = 4)]
    [string]$BackupDir = 'C:\backup',

    [string]$Pattern = '*.log',

    [switch]$RemoveOriginals
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("Error: $Message")
    exit $Code
}

function Resolve-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd('\', '/')
}

if (-not (Test-Path -LiteralPath $LogDir -PathType Container)) {
    Fail "folder '$LogDir' does not exist"
}
try {
    $null = Get-ChildItem -LiteralPath $LogDir -Force
}
catch {
    Fail "no permission to read folder '$LogDir'"
}

$LogFull    = Resolve-FullPath $LogDir
$BackupFull = Resolve-FullPath $BackupDir
if ($LogFull -ieq $BackupFull) {
    Fail 'backup folder must differ from the log folder'
}

function Get-DirSizeBytes {
    $m = Get-ChildItem -LiteralPath $LogFull -File -Recurse -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    if ($null -eq $m.Sum) { return [long]0 }
    return [long]$m.Sum
}

function Get-UsagePercent([long]$SizeBytes) {
    $thresholdBytes = [long]$ThresholdMB * 1MB
    return [long][math]::Floor([double]$SizeBytes * 100 / $thresholdBytes)
}

function Get-OldFiles {
    Get-ChildItem -LiteralPath $LogFull -File -Force | Sort-Object -Property LastWriteTime
}

function Select-SuitableFiles {
    param([Parameter(ValueFromPipeline = $true)] $File)
    process {
        if ($File.Name -like $Pattern -and $File.Extension -ne '.gz' -and $File.Length -gt 0) {
            $File
        }
    }
}

function New-Archive([string]$ArchivePath, [string[]]$Names) {
    $tmp = "$ArchivePath.part"
    & tar -czf $tmp -C $LogFull @Names
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Fail 'tar failed, nothing was archived' 2
    }
    Move-Item -LiteralPath $tmp -Destination $ArchivePath
    & tar -tzf $ArchivePath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "archive verification failed: $ArchivePath" 2
    }
}

$sizeBytes = Get-DirSizeBytes
$usage     = Get-UsagePercent $sizeBytes

Write-Host "Folder:     $LogFull"
Write-Host ("Size:       {0} bytes ({1} KB)" -f $sizeBytes, [math]::Floor($sizeBytes / 1KB))
Write-Host "Threshold:  $ThresholdMB MB"
Write-Host "Usage:      $usage%"

if ($usage -le $NPercent) {
    Write-Host "Usage $usage% does not exceed $NPercent%, nothing to do."
    exit 0
}

Write-Host "Usage $usage% exceeds $NPercent%: archiving up to $MFiles oldest files."

$candidates = @(Get-OldFiles | Select-SuitableFiles)
if ($candidates.Count -eq 0) {
    Write-Host "No suitable files (pattern '$Pattern', not .gz, not empty), nothing to archive."
    exit 0
}
if ($candidates.Count -lt $MFiles) {
    [Console]::Error.WriteLine("Warning: only $($candidates.Count) suitable file(s) found, fewer than M=$MFiles; archiving all of them.")
}

$selected = @($candidates | Select-Object -First $MFiles)
$names    = @($selected | ForEach-Object { $_.Name })

try {
    New-Item -ItemType Directory -Path $BackupFull -Force | Out-Null
    $probe = Join-Path $BackupFull ".write_test_$PID"
    [IO.File]::WriteAllText($probe, '')
    Remove-Item -LiteralPath $probe -Force
}
catch {
    Fail "cannot write to backup folder '$BackupDir'" 2
}

$stamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$archive = Join-Path $BackupFull "logs_$stamp.tar.gz"
if (Test-Path -LiteralPath $archive) {
    $archive = Join-Path $BackupFull "logs_${stamp}_$PID.tar.gz"
}

New-Archive $archive $names

$archiveSize = (Get-Item -LiteralPath $archive).Length
Write-Host "Archive created: $archive ($($names.Count) file(s), $archiveSize bytes)"
foreach ($n in $names) { Write-Host "  + $n" }

if ($RemoveOriginals) {
    foreach ($n in $names) {
        try { Remove-Item -LiteralPath (Join-Path $LogFull $n) -Force }
        catch { [Console]::Error.WriteLine("Warning: could not remove '$n'") }
    }
    $newUsage = Get-UsagePercent (Get-DirSizeBytes)
    Write-Host "Originals removed. Usage is now $newUsage%."
}

exit 0
