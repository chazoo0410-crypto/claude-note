<#
.SYNOPSIS
  Transcribe a local video/audio file into plain text.
  Tries Gemini (multimodal, understands video/audio directly via the
  File API) first, falls back to OpenAI Whisper (whisper-1) on failure.
  Verbatim transcription only - no summarizing, translating, or explaining.

.PARAMETER InputFile
  Path to the source video/audio file

.PARAMETER OutFile
  Output text file path. If omitted, the transcript is printed to stdout.

.PARAMETER Language
  Output/detection language hint, e.g. "ja", "en" (optional). If omitted,
  the content is transcribed in whatever language it is spoken in.

.PARAMETER GeminiModel
  Gemini model to use (default: gemini-2.5-flash)

.PARAMETER GeminiKeyFile
  Path to a file containing the Gemini API key (default: .secrets/gemini_api_key.txt)
  This path is gitignored and local-only - never commit real key values.

.PARAMETER OpenAIKeyFile
  Path to a file containing the OpenAI API key (default: .secrets/openai_api_key.txt)

.PARAMETER NoHeader
  Do not prepend a metadata comment header to -OutFile

.EXAMPLE
  pwsh -File transcribe.ps1 -InputFile "video.mp4" -OutFile "output/transcripts/foo.md"
#>
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [string]$OutFile,
    [string]$Language = "",
    [string]$GeminiModel = "gemini-2.5-flash",
    [string]$GeminiKeyFile = ".secrets/gemini_api_key.txt",
    [string]$OpenAIKeyFile = ".secrets/openai_api_key.txt",
    [switch]$NoHeader
)

$ErrorActionPreference = "Stop"

function Read-Key {
    param([string]$EnvName, [string]$KeyFile)
    $envVal = [Environment]::GetEnvironmentVariable($EnvName)
    if ($envVal) { return $envVal }
    if (Test-Path $KeyFile) { return (Get-Content $KeyFile -Raw).Trim() }
    return $null
}

function Get-MimeType {
    param([string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        ".mp4" { return "video/mp4" }
        ".mov" { return "video/quicktime" }
        ".m4v" { return "video/x-m4v" }
        ".avi" { return "video/x-msvideo" }
        ".mkv" { return "video/x-matroska" }
        ".webm" { return "video/webm" }
        ".mp3" { return "audio/mpeg" }
        ".wav" { return "audio/wav" }
        ".m4a" { return "audio/mp4" }
        ".ogg" { return "audio/ogg" }
        ".oga" { return "audio/ogg" }
        ".flac" { return "audio/flac" }
        ".aac" { return "audio/aac" }
        default { return "application/octet-stream" }
    }
}

function Get-TranscriptPrompt {
    param([string]$Lang)
    if ($Lang) {
        return "Transcribe this audio/video verbatim, exactly as spoken. Output the transcript in $Lang. Do not summarize, translate, or add commentary - output only the transcript text, formatted into natural paragraphs."
    }
    return "Transcribe this audio/video verbatim, exactly as spoken, in its original language. Do not summarize, translate, or add commentary - output only the transcript text, formatted into natural paragraphs."
}

function Invoke-GeminiTranscribe {
    param([string]$Path, [string]$Mime, [string]$ApiKey, [string]$Model, [string]$Lang)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $size = $bytes.Length
    $displayName = [System.IO.Path]::GetFileName($Path)

    $startUri = "https://generativelanguage.googleapis.com/upload/v1beta/files?key=$ApiKey"
    $startBody = @{ file = @{ display_name = $displayName } } | ConvertTo-Json
    $startHeaders = @{
        "X-Goog-Upload-Protocol"               = "resumable"
        "X-Goog-Upload-Command"                = "start"
        "X-Goog-Upload-Header-Content-Length"  = "$size"
        "X-Goog-Upload-Header-Content-Type"    = $Mime
    }
    $startResp = Invoke-WebRequest -Uri $startUri -Method Post -ContentType "application/json" -Headers $startHeaders -Body $startBody -TimeoutSec 30
    $uploadUrl = $startResp.Headers["X-Goog-Upload-URL"]
    if ($uploadUrl -is [System.Array]) { $uploadUrl = $uploadUrl[0] }
    if (-not $uploadUrl) { throw "no upload URL returned by Gemini File API" }

    $uploadHeaders = @{
        "X-Goog-Upload-Offset"  = "0"
        "X-Goog-Upload-Command" = "upload, finalize"
    }
    $uploadResp = Invoke-RestMethod -Uri $uploadUrl -Method Post -Headers $uploadHeaders -Body $bytes -TimeoutSec 300
    $file = $uploadResp.file

    $waited = 0
    $maxWait = 180
    while ($file.state -ne "ACTIVE" -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 3
        $waited += 3
        $fileUri = "https://generativelanguage.googleapis.com/v1beta/$($file.name)?key=$ApiKey"
        $file = Invoke-RestMethod -Uri $fileUri -TimeoutSec 30
    }
    if ($file.state -eq "FAILED") { throw "Gemini file processing failed" }
    if ($file.state -ne "ACTIVE") { throw "timed out waiting for Gemini file to become ACTIVE" }

    $prompt = Get-TranscriptPrompt -Lang $Lang
    $genBody = @{
        contents = @(
            @{
                parts = @(
                    @{ file_data = @{ mime_type = $file.mimeType; file_uri = $file.uri } },
                    @{ text = $prompt }
                )
            }
        )
    } | ConvertTo-Json -Depth 8
    $genUri = "https://generativelanguage.googleapis.com/v1beta/models/${Model}:generateContent?key=$ApiKey"
    $genResp = Invoke-RestMethod -Uri $genUri -Method Post -ContentType "application/json" -Body $genBody -TimeoutSec 300

    try {
        $deleteUri = "https://generativelanguage.googleapis.com/v1beta/$($file.name)?key=$ApiKey"
        Invoke-RestMethod -Uri $deleteUri -Method Delete -TimeoutSec 15 | Out-Null
    }
    catch {
        # best-effort cleanup, never fails the transcription
    }

    $textParts = $genResp.candidates[0].content.parts | Where-Object { $_.text } | Select-Object -ExpandProperty text
    $transcript = ($textParts -join "`n").Trim()
    if (-not $transcript) { throw "no transcript text in Gemini response" }
    return $transcript
}

function Invoke-WhisperTranscribe {
    param([string]$Path, [string]$ApiKey, [string]$Lang, [string]$Mime)

    $boundary = [System.Guid]::NewGuid().ToString()
    $fileName = [System.IO.Path]::GetFileName($Path)
    $fileBytes = [IO.File]::ReadAllBytes($Path)

    $preambleLines = @("--$boundary", 'Content-Disposition: form-data; name="model"', "", "whisper-1")
    if ($Lang) {
        $preambleLines += "--$boundary"
        $preambleLines += 'Content-Disposition: form-data; name="language"'
        $preambleLines += ""
        $preambleLines += $Lang
    }
    $preambleLines += "--$boundary"
    $preambleLines += "Content-Disposition: form-data; name=`"file`"; filename=`"$fileName`""
    $preambleLines += "Content-Type: $Mime"
    $preambleLines += ""
    $preambleLines += ""
    $preamble = [System.Text.Encoding]::UTF8.GetBytes(($preambleLines -join "`r`n"))
    $trailer = [System.Text.Encoding]::UTF8.GetBytes("`r`n--$boundary--`r`n")

    $body = New-Object byte[] ($preamble.Length + $fileBytes.Length + $trailer.Length)
    [Array]::Copy($preamble, 0, $body, 0, $preamble.Length)
    [Array]::Copy($fileBytes, 0, $body, $preamble.Length, $fileBytes.Length)
    [Array]::Copy($trailer, 0, $body, $preamble.Length + $fileBytes.Length, $trailer.Length)

    $headers = @{ Authorization = "Bearer $ApiKey" }
    $resp = Invoke-RestMethod -Uri "https://api.openai.com/v1/audio/transcriptions" -Method Post -Headers $headers -ContentType "multipart/form-data; boundary=$boundary" -Body $body -TimeoutSec 120
    if (-not $resp.text) { throw "no transcript text in OpenAI response" }
    return $resp.text.Trim()
}

$WhisperExts = @(".flac", ".m4a", ".mp3", ".mp4", ".mpeg", ".mpga", ".oga", ".ogg", ".wav", ".webm")
$WhisperMaxBytes = 25 * 1024 * 1024

if (-not (Test-Path $InputFile)) {
    Write-Error "input file not found: $InputFile"
    exit 1
}

$mime = Get-MimeType -Path $InputFile
$size = (Get-Item $InputFile).Length
$errors = @()
$transcript = $null
$providerLabel = $null

$geminiKey = Read-Key -EnvName "GEMINI_API_KEY" -KeyFile $GeminiKeyFile
if ($geminiKey) {
    try {
        $transcript = Invoke-GeminiTranscribe -Path $InputFile -Mime $mime -ApiKey $geminiKey -Model $GeminiModel -Lang $Language
        $providerLabel = "gemini ($GeminiModel)"
    }
    catch {
        $errors += "gemini: $_"
    }
}
else {
    $errors += "gemini: no API key found"
}

if (-not $transcript) {
    $openaiKey = Read-Key -EnvName "OPENAI_API_KEY" -KeyFile $OpenAIKeyFile
    $ext = [System.IO.Path]::GetExtension($InputFile).ToLowerInvariant()
    if (-not $openaiKey) {
        $errors += "openai: no API key found"
    }
    elseif ($WhisperExts -notcontains $ext) {
        $errors += "openai: unsupported extension for Whisper API: $ext"
    }
    elseif ($size -gt $WhisperMaxBytes) {
        $errors += "openai: file too large for Whisper API (25MB limit, got $size bytes)"
    }
    else {
        try {
            $transcript = Invoke-WhisperTranscribe -Path $InputFile -ApiKey $openaiKey -Lang $Language -Mime $mime
            $providerLabel = "openai (whisper-1)"
        }
        catch {
            $errors += "openai: $_"
        }
    }
}

if (-not $transcript) {
    Write-Error "transcription failed on all providers:`n$($errors -join [Environment]::NewLine)"
    exit 1
}

if ($OutFile) {
    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    $content = $transcript
    if (-not $NoHeader) {
        $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm"
        $header = "<!--`ngenerated_at: $generatedAt`nsource: $InputFile`nprovider: $providerLabel`n-->`n`n"
        $content = $header + $transcript
    }
    [IO.File]::WriteAllText($OutFile, $content, [System.Text.Encoding]::UTF8)
    Write-Output "saved ($providerLabel): $OutFile ($($transcript.Length) chars)"
}
else {
    Write-Output "# provider: $providerLabel`n"
    Write-Output $transcript
}
