[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function ConvertFrom-CodePoints {
    param([int[]]$CodePoints)
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

$messageNoFiles = ConvertFrom-CodePoints @(
    12475,12461,12517,12522,12486,12451,35386,26029,23550,35987,12398,32,80,111,119,101,114,83,104,101,108,108,32,12501,12449,12452,12523,12364,35211,12388,12363,12426,12414,12379,12435,12290
)
$messageIssueHeader = ConvertFrom-CodePoints @(
    12475,12461,12517,12522,12486,12451,35386,26029,12391,21839,38988,12398,12354,12427,12497,12479,12540,12531,12434,26908,20986,12375,12414,12375,12383,58
)
$messageFailed = ConvertFrom-CodePoints @(
    12475,12461,12517,12522,12486,12451,35386,26029,12395,22833,25943,12375,12414,12375,12383,12290,32080,26524,12434,30906,35469,12375,12390,20462,27491,12375,12390,12367,12384,12373,12356,12290
)

$scanRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$files = Get-ChildItem -Path $scanRoot -Recurse -File -Include *.ps1,*.psm1 |
    Where-Object {
        $_.FullName -notmatch '\\[.]git\\' -and
        $_.FullName -notmatch '\\tests\\Invoke-SecurityCheck[.]ps1$'
    }

if (-not $files) {
    throw $messageNoFiles
}

$rules = @(
    @{ Name = 'Use of Invoke-Expression'; Pattern = '(?i)\b(Invoke-Expression|iex)\b' }
    @{ Name = 'Plaintext SecureString usage'; Pattern = '(?i)ConvertTo-SecureString[^\n]*-AsPlainText' }
    @{ Name = 'Potential hardcoded secrets'; Pattern = '(?i)\b(password|passwd|token|api[-_]?key|secret)\b\s*[:=]\s*[''\"][^''\"]+[''\"]' }
)

$issues = @()
foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8

    foreach ($rule in $rules) {
        if ($content -match $rule.Pattern) {
            $issues += "$($file.FullName): $($rule.Name)"
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host $messageIssueHeader -ForegroundColor Red
    $issues | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw $messageFailed
}
