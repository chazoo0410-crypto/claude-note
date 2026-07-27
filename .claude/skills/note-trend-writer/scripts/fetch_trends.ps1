<#
.SYNOPSIS
  Fetch popular articles per category from note.com's public JSON API
  (no login required), rank genres by average like count, and print JSON.

.PARAMETER Top
  How many top genres to output (default 5)

.PARAMETER SampleSize
  How many sample articles per genre (default 5)

.EXAMPLE
  pwsh -File fetch_trends.ps1 -Top 5 -SampleSize 5
#>
param(
    [int]$Top = 5,
    [int]$SampleSize = 5
)

$ErrorActionPreference = "Stop"
$Base = "https://note.com"
$Headers = @{
    "Accept"     = "application/json"
    "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
}
$TimeoutSec = 8

function Get-JsonUtf8 {
    param([string]$Uri)
    $resp = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -UseBasicParsing -TimeoutSec $TimeoutSec
    $bytes = $resp.RawContentStream.ToArray()
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $text | ConvertFrom-Json
}

try {
    $catsResp = Get-JsonUtf8 -Uri "$Base/api/v2/categories"
}
catch {
    [PSCustomObject]@{ error = "Failed to fetch category list: $_" } | ConvertTo-Json | Write-Output
    exit 1
}

$categories = $catsResp.data.categories | Where-Object { $_.engName }

$results = @()
$consecutiveFailures = 0
foreach ($cat in $categories) {
    $eng = $cat.engName
    try {
        $catResp = Get-JsonUtf8 -Uri "$Base/api/v1/categories/$eng`?note_intro_only=true"
        $consecutiveFailures = 0
    }
    catch {
        Write-Warning "$($cat.name) fetch failed: $_"
        $consecutiveFailures++
        if ($consecutiveFailures -ge 2) {
            Write-Warning "2 consecutive failures - assuming network reachability issue, aborting"
            break
        }
        continue
    }

    $notes = @($catResp.data.notes)
    if ($notes.Count -eq 0) { continue }

    $likeCounts = $notes | ForEach-Object { if ($_.like_count) { $_.like_count } else { 0 } }
    $avgLikes = ($likeCounts | Measure-Object -Average).Average

    $topNotes = $notes | Sort-Object -Property @{Expression = { if ($_.like_count) { $_.like_count } else { 0 } } } -Descending | Select-Object -First $SampleSize

    $samples = $topNotes | ForEach-Object {
        $excerpt = $_.body
        if ($excerpt -and $excerpt.Length -gt 200) { $excerpt = $excerpt.Substring(0, 200) }
        [PSCustomObject]@{
            title      = $_.name
            like_count = $_.like_count
            url        = $_.note_url
            excerpt    = $excerpt
        }
    }

    $results += [PSCustomObject]@{
        category_id      = $cat.id
        category_name    = $cat.name
        eng_name         = $eng
        note_count_sampled = $notes.Count
        avg_like_count   = [math]::Round($avgLikes, 1)
        top_articles     = $samples
    }
}

$ranked = $results | Sort-Object -Property avg_like_count -Descending | Select-Object -First $Top

[PSCustomObject]@{
    generated_from = "note.com public category API"
    ranked_genres  = $ranked
} | ConvertTo-Json -Depth 6
