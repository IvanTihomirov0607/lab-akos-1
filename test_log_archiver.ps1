[CmdletBinding()]
param(
    [string]$ScriptPath = ''
)

$HereDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($HereDir)) {
    $HereDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrEmpty($ScriptPath)) {
    $ScriptPath = Join-Path $HereDir 'log_archiver.ps1'
}

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    [Console]::Error.WriteLine("Script not found: $ScriptPath")
    exit 2
}

$PsExe = (Get-Process -Id $PID).Path
$Work  = Join-Path ([IO.Path]::GetTempPath()) ('lr1_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Work | Out-Null

$script:Pass = 0
$script:Fail = 0
$script:Out  = ''
$script:Rc   = 0

function Initialize-Case {
    $script:Log = Join-Path $Work 'log'
    $script:Bk  = Join-Path $Work 'backup'
    Remove-Item -LiteralPath $script:Log, $script:Bk -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $script:Log | Out-Null
}

function New-TestFile([string]$Name, [int]$Kb, [double]$AgeDays) {
    $path = Join-Path $script:Log $Name
    [IO.File]::WriteAllBytes($path, (New-Object byte[] ($Kb * 1024)))
    (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
}

function Invoke-Under([string[]]$ArgList) {
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ArgList
    $lines = & $PsExe @all 2>&1 | ForEach-Object { "$_" }
    $script:Rc  = $LASTEXITCODE
    $script:Out = ($lines -join "`n")
}

function Start-Case([string]$Title) { Write-Host ''; Write-Host "== $Title" }

function Write-Pass([string]$Text) { $script:Pass++; Write-Host "  PASS: $Text" }
function Write-Fail([string]$Text) {
    $script:Fail++
    Write-Host "  FAIL: $Text"
    Write-Host ("        output was: " + ($script:Out -replace "`r?`n", ' | '))
}

function Assert-Rc([int]$Expected, [string]$Text) {
    if ($script:Rc -eq $Expected) { Write-Pass "$Text (exit code $Expected)" }
    else { Write-Fail "$Text (expected exit code $Expected, got $($script:Rc))" }
}
function Assert-OutHas([string]$Needle, [string]$Text) {
    if ($script:Out.Contains($Needle)) { Write-Pass $Text } else { Write-Fail "$Text (output lacks '$Needle')" }
}

function Get-Archives { @(Get-ChildItem -LiteralPath $script:Bk -Filter '*.tar.gz' -ErrorAction SilentlyContinue) }
function Get-ArchiveList { $a = Get-Archives; if ($a.Count -gt 0) { @(& tar -tzf $a[0].FullName) } else { @() } }

function Assert-Archives([int]$Expected, [string]$Text) {
    $n = (Get-Archives).Count
    if ($n -eq $Expected) { Write-Pass "$Text ($Expected archive(s) in backup)" }
    else { Write-Fail "$Text (expected $Expected archive(s), found $n)" }
}
function Assert-InArchive([string]$Name) {
    if ((Get-ArchiveList) -contains $Name) { Write-Pass "archive contains '$Name'" } else { Write-Fail "archive should contain '$Name'" }
}
function Assert-NotInArchive([string]$Name) {
    if ((Get-ArchiveList) -contains $Name) { Write-Fail "archive must not contain '$Name'" } else { Write-Pass "archive does not contain '$Name'" }
}
function Assert-Exists([string]$Name) {
    if (Test-Path -LiteralPath (Join-Path $script:Log $Name)) { Write-Pass "'$Name' still exists in log folder" } else { Write-Fail "'$Name' should still exist" }
}
function Assert-Missing([string]$Name) {
    if (Test-Path -LiteralPath (Join-Path $script:Log $Name)) { Write-Fail "'$Name' should have been removed" } else { Write-Pass "'$Name' was removed" }
}

function Get-PrintedPercent {
    if ($script:Out -match 'Usage:\s+(\d+)%') { return [int]$Matches[1] }
    return -1
}

try {
Start-Case 'A1: log folder does not exist'
Initialize-Case
Invoke-Under @((Join-Path $Work 'nope'), '1', '80', '5')
Assert-Rc 1 'missing folder'
Assert-OutHas 'does not exist' 'error message'

Start-Case 'A2: threshold is not a number'
Initialize-Case
Invoke-Under @($script:Log, 'abc', '80', '5')
Assert-Rc 1 "threshold 'abc'"

Start-Case 'A3: threshold / N / M are zero'
Initialize-Case
Invoke-Under @($script:Log, '0', '80', '5'); Assert-Rc 1 'threshold 0'
Invoke-Under @($script:Log, '1', '0', '5');  Assert-Rc 1 'N = 0'
Invoke-Under @($script:Log, '1', '80', '0'); Assert-Rc 1 'M = 0'

Start-Case 'A4: backup folder equals log folder'
Initialize-Case
Invoke-Under @($script:Log, '1', '80', '5', $script:Log)
Assert-Rc 1 'same folder'
Assert-OutHas 'must differ' 'error message'

Start-Case 'B1: printed percent matches the real folder size'
Initialize-Case
New-TestFile 'a.log' 512 1
$size = (Get-ChildItem -LiteralPath $script:Log -File | Measure-Object Length -Sum).Sum
$expected = [math]::Floor($size * 100 / 1MB)
Invoke-Under @($script:Log, '1', '99', '5', $script:Bk)
Assert-Rc 0 'run'
Assert-OutHas "Usage:      $expected%" "printed usage is $expected%"

Start-Case 'B2: empty folder -> nothing to do'
Initialize-Case
Invoke-Under @($script:Log, '10', '1', '5', $script:Bk)
Assert-Rc 0 'empty folder'
Assert-OutHas 'nothing to do' 'message'
Assert-Archives 0 'no archive'

Start-Case 'C1: below N% -> nothing is archived'
Initialize-Case
New-TestFile 'a.log' 100 1
Invoke-Under @($script:Log, '10', '80', '5', $script:Bk)
Assert-Rc 0 'below threshold'
Assert-Archives 0 'no archive'
Assert-Exists 'a.log'

Start-Case 'C2: exactly N% -> NOT archived (must be MORE than N%)'
Initialize-Case
New-TestFile 'a.log' 100 2; New-TestFile 'b.log' 100 1
Invoke-Under @($script:Log, '1', '99', '5', $script:Bk)
$p = Get-PrintedPercent
Invoke-Under @($script:Log, '1', "$p", '5', $script:Bk)
Assert-Rc 0 "N equals usage ($p%)"
Assert-Archives 0 'no archive at exactly N%'

Start-Case 'C3: N-1 -> archived'
Initialize-Case
New-TestFile 'a.log' 100 2; New-TestFile 'b.log' 100 1
Invoke-Under @($script:Log, '1', '99', '5', $script:Bk)
$p = Get-PrintedPercent
Invoke-Under @($script:Log, '1', "$($p - 1)", '5', $script:Bk)
Assert-Rc 0 "N is usage-1 ($($p - 1)%)"
Assert-Archives 1 'archive created'

Start-Case 'D1: the M oldest files are archived, newer ones are not'
Initialize-Case
New-TestFile 'old1.log' 300 10; New-TestFile 'old2.log' 300 9; New-TestFile 'old3.log' 300 8
New-TestFile 'new1.log' 300 1;  New-TestFile 'new2.log' 300 0
Invoke-Under @($script:Log, '1', '80', '3', $script:Bk)
Assert-Rc 0 'run'
Assert-Archives 1 'one archive'
Assert-InArchive 'old1.log'; Assert-InArchive 'old2.log'; Assert-InArchive 'old3.log'
Assert-NotInArchive 'new1.log'; Assert-NotInArchive 'new2.log'
Assert-Exists 'old1.log'

Start-Case 'D2: with -RemoveOriginals the archived originals are removed'
Initialize-Case
New-TestFile 'old1.log' 300 10; New-TestFile 'old2.log' 300 9; New-TestFile 'old3.log' 300 8
New-TestFile 'new1.log' 300 1;  New-TestFile 'new2.log' 300 0
Invoke-Under @('-RemoveOriginals', $script:Log, '1', '80', '3', $script:Bk)
Assert-Rc 0 'run with -RemoveOriginals'
Assert-Archives 1 'one archive'
Assert-Missing 'old1.log'; Assert-Missing 'old2.log'; Assert-Missing 'old3.log'
Assert-Exists 'new1.log'; Assert-Exists 'new2.log'

Start-Case 'D3: fewer suitable files than M -> archive all, with a warning'
Initialize-Case
New-TestFile 'a.log' 600 3; New-TestFile 'b.log' 600 2
Invoke-Under @($script:Log, '1', '80', '10', $script:Bk)
Assert-Rc 0 'run'
Assert-OutHas 'Warning' 'warning is printed'
Assert-InArchive 'a.log'; Assert-InArchive 'b.log'

Start-Case 'D4: file names with spaces'
Initialize-Case
New-TestFile 'my app.log' 600 9; New-TestFile 'other.log' 600 1
Invoke-Under @($script:Log, '1', '80', '1', $script:Bk)
Assert-Rc 0 'run'
Assert-InArchive 'my app.log'

Start-Case 'D5: backup folder is created if it does not exist'
Initialize-Case
New-TestFile 'a.log' 1200 1
$deep = Join-Path $Work 'new\backup\dir'
Invoke-Under @($script:Log, '1', '80', '1', $deep)
Assert-Rc 0 'run'
if (@(Get-ChildItem -LiteralPath $deep -Filter '*.tar.gz' -ErrorAction SilentlyContinue).Count -eq 1) { Write-Pass 'archive is in the new folder' }
else { Write-Fail 'no archive in the new folder' }

Start-Case 'E1: only *.log is archived; .gz, other extensions, empty files, folders are skipped'
Initialize-Case
New-TestFile 'ancient.log.gz' 400 100
New-TestFile 'notes.txt' 400 90
New-TestFile 'empty.log' 0 80
New-Item -ItemType Directory -Path (Join-Path $script:Log 'sub') | Out-Null
[IO.File]::WriteAllBytes((Join-Path $script:Log 'sub\inner.log'), (New-Object byte[] (400 * 1024)))
New-TestFile 'real1.log' 400 5; New-TestFile 'real2.log' 400 4
Invoke-Under @($script:Log, '1', '80', '5', $script:Bk)
Assert-Rc 0 'run'
Assert-InArchive 'real1.log'; Assert-InArchive 'real2.log'
Assert-NotInArchive 'ancient.log.gz'; Assert-NotInArchive 'notes.txt'; Assert-NotInArchive 'empty.log'

Start-Case 'E2: custom pattern with -Pattern'
Initialize-Case
New-TestFile 'a.txt' 600 9; New-TestFile 'b.txt' 600 8; New-TestFile 'c.log' 600 7
Invoke-Under @('-Pattern', '*.txt', $script:Log, '1', '80', '5', $script:Bk)
Assert-Rc 0 'run'
Assert-InArchive 'a.txt'; Assert-InArchive 'b.txt'; Assert-NotInArchive 'c.log'

Start-Case 'E3: over threshold but nothing suitable -> exit 0, no archive'
Initialize-Case
New-TestFile 'big1.gz' 1200 5; New-TestFile 'big2.gz' 600 4
Invoke-Under @($script:Log, '1', '80', '5', $script:Bk)
Assert-Rc 0 'run'
Assert-OutHas 'No suitable files' 'message'
Assert-Archives 0 'no archive'

Start-Case 'F1: backup path is a file -> exit 2, originals untouched'
Initialize-Case
New-TestFile 'a.log' 1200 1
$notFolder = Join-Path $Work 'not_a_folder'
Set-Content -LiteralPath $notFolder -Value ''
Invoke-Under @('-RemoveOriginals', $script:Log, '1', '80', '1', $notFolder)
Assert-Rc 2 'backup is a file'
Assert-Exists 'a.log'

}
finally {
    Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=============================='
Write-Host "Passed: $($script:Pass)   Failed: $($script:Fail)"
Write-Host '=============================='
if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
