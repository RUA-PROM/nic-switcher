[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function ConvertFrom-CodePoints {
    param([int[]]$CodePoints)
    -join ($CodePoints | ForEach-Object { [char]$_ })
}

$messageNoFiles = ConvertFrom-CodePoints @(
    25972,31435,12394,32,80,111,119,101,114,83,104,101,108,108,32,12501,12449,12452,12523,12364,35211,12388,12363,12426,12414,12379,12435,12290
)
$messageParseFailed = ConvertFrom-CodePoints @(
    27425,12398,12501,12449,12452,12523,12399,27880,25991,12363,12425,36763,35351,12391,12365,12414,12379,12435,12290
)
$messageTrailingWhitespace = ConvertFrom-CodePoints @(
    27425,12398,12501,12449,12452,12523,12395,20313,20998,12394,12488,12521,12452,12531,12464,12458,12469,12501,12451,12483,12463,12364,12354,12426,12414,12377,12290
)
$messageFinalNewline = ConvertFrom-CodePoints @(
    12501,12449,12452,12523,12398,26368,21518,12395,26032,12375,12356,25913,34892,12364,24517,35201,12391,12377,12290
)
$messageFailed = ConvertFrom-CodePoints @(
    25972,24418,12481,12455,12483,12463,12395,22833,25943,12375,12414,12375,12383,12290
)

$scanRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$files = Get-ChildItem -Path $scanRoot -Recurse -File -Include *.ps1,*.psm1 |
    Where-Object { $_.FullName -notmatch '\\[.]git\\' }

if (-not $files) {
    throw $messageNoFiles
}

$issues = @()
foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
    $lines = Get-Content -LiteralPath $file.FullName -Encoding UTF8

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $issues += "Parse error: $($file.FullName)"
        continue
    }

    if ($content -match '(?m)[ \t]+$') {
        $issues += "$($file.FullName): $messageTrailingWhitespace"
    }

    if (-not $content.EndsWith("`n")) {
        $issues += "$($file.FullName): $messageFinalNewline"
    }

    # BDD style checks for unit/integration test files.
    if ($file.FullName -match '\\tests\\(unit|integration)\\.*[.]Tests[.]ps1$') {
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]

            if ($line -match '^\s*Describe\s+[''\"](?<name>[^''\"]+)[''\"]') {
                if ($Matches.name -notmatch '^Feature:\s+\S') {
                    $issues += "$($file.FullName):$($i + 1): Describe must start with 'Feature: '"
                }
            }

            if ($line -match '^\s*Context\s+[''\"](?<name>[^''\"]+)[''\"]') {
                if ($Matches.name -notmatch '^Scenario:\s+\S') {
                    $issues += "$($file.FullName):$($i + 1): Context must start with 'Scenario: '"
                }
            }

            if ($line -match '^\s*It\s+.+\{\s*$') {
                $braceDepth = 0
                $block = @()

                for ($j = $i; $j -lt $lines.Count; $j++) {
                    $current = $lines[$j]
                    $openCount = ([regex]::Matches($current, '\{')).Count
                    $closeCount = ([regex]::Matches($current, '\}')).Count
                    $braceDepth += ($openCount - $closeCount)

                    if ($j -gt $i) {
                        $block += $current
                    }

                    if ($braceDepth -le 0) {
                        break
                    }
                }

                $blockText = $block -join "`n"
                if ($blockText -notmatch '(?m)^\s*#.*\bGiven\b') {
                    $issues += "$($file.FullName):$($i + 1): It block must contain a Given comment"
                }
                if ($blockText -notmatch '(?m)^\s*#.*\bWhen\b') {
                    $issues += "$($file.FullName):$($i + 1): It block must contain a When comment"
                }
                if ($blockText -notmatch '(?m)^\s*#.*\bThen\b') {
                    $issues += "$($file.FullName):$($i + 1): It block must contain a Then comment"
                }
            }
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host $messageParseFailed -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw $messageFailed
}
