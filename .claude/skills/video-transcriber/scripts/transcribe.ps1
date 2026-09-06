<#
.SYNOPSIS
  Transcribe a local video/audio file into plain text.
  Tries Gemini (multimodal, understands video/audio directly via the
  File API) first, falls back to OpenAI Whisper (whisper-1) on failure.
  Verbatim transcription only - no summarizing, translating, or explaining.

  Long recordings: if ffmpeg is installed and the media is longer than
  -SplitMinutes (default 30), the audio track is extracted, downmixed to
  16kHz mono and split into chunks, which are transcribed one by one and
  joined back together. Extracting audio also shrinks the payload enough
  that the 25MB Whisper fallback becomes usable for sources that were far
  too big as video. Without ffmpeg the file is sent whole.

.PARAMETER InputFile
  Path to the source video/audio file

.PARAMETER OutFile
  Output text file path. If omitted, the transcript is printed to stdout.

.PARAMETER Language
  Output/detection language hint, e.g. "ja", "en" (optional). If omitted,
  the content is transcribed in whatever language it is spoken in.

.PARAMETER SplitMinutes
  Split media longer than this into chunks (needs ffmpeg). 0 disables
  splitting. Default 30.

.PARAMETER ForceSplit
  Split even when the duration cannot be probed (no ffprobe/ffmpeg probe)

.PARAMETER NoChunkMarkers
  Do not insert [HH:MM:SS] markers between chunks

.PARAMETER FfmpegTimeout
  Timeout in seconds for each ffmpeg run (default 1800)

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

.EXAMPLE
  pwsh -File transcribe.ps1 -InputFile "long_meeting.mp4" -SplitMinutes 20
#>
param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [string]$OutFile,
    [string]$Language = "",
    [double]$SplitMinutes = 30,
    [switch]$ForceSplit,
    [switch]$NoChunkMarkers,
    [int]$FfmpegTimeout = 1800,
    [string]$GeminiModel = "gemini-2.5-flash",
    [string]$GeminiKeyFile = ".secrets/gemini_api_key.txt",
    [string]$OpenAIKeyFile = ".secrets/openai_api_key.txt",
    [switch]$NoHeader
)

$ErrorActionPreference = "Stop"

$WhisperExts = @(".flac", ".m4a", ".mp3", ".mpeg", ".mpga", ".mp4", ".oga", ".ogg", ".wav", ".webm")
$WhisperMaxBytes = 25 * 1024 * 1024

# Speech-friendly audio encodings, smallest first. Every one of these works
# with ffmpeg's segment muxer and is accepted by both providers; the list is
# tried in order so a build without libmp3lame/libopus still lands on wav.
$AudioCandidates = @(
    @{ Ext = "mp3"; Args = @("-c:a", "libmp3lame", "-b:a", "32k") },
    @{ Ext = "ogg"; Args = @("-c:a", "libopus", "-b:a", "24k") },
    @{ Ext = "wav"; Args = @("-c:a", "pcm_s16le") }
)

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

function Format-Timestamp {
    param([double]$Seconds)
    $span = [TimeSpan]::FromSeconds([Math]::Floor($Seconds))
    return ("{0:00}:{1:00}:{2:00}" -f [int]$span.TotalHours, $span.Minutes, $span.Seconds)
}

function Get-TranscriptPrompt {
    param([string]$Lang)
    if ($Lang) {
        return "Transcribe this audio/video verbatim, exactly as spoken. Output the transcript in $Lang. Do not summarize, translate, or add commentary - output only the transcript text, formatted into natural paragraphs."
    }
    return "Transcribe this audio/video verbatim, exactly as spoken, in its original language. Do not summarize, translate, or add commentary - output only the transcript text, formatted into natural paragraphs."
}

# ---------------------------------------------------------------------------
# Optional ffmpeg-backed preprocessing
# ---------------------------------------------------------------------------

function ConvertTo-QuotedArg {
    param([string]$Value)
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Invoke-ExternalProcess {
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-QuotedArg $_ }) -join " ")
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    # Drain both pipes asynchronously; a full stderr buffer would otherwise
    # deadlock ffmpeg before it ever exits.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        return @{ Ok = $false; Out = ""; Err = "timed out after $TimeoutSec seconds" }
    }
    return @{ Ok = ($proc.ExitCode -eq 0); Out = $outTask.Result; Err = $errTask.Result }
}

function Get-ToolPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-MediaDuration {
    param([string]$Path)

    $ffprobe = Get-ToolPath -Name "ffprobe"
    if ($ffprobe) {
        $probeArgs = @("-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", $Path)
        $result = Invoke-ExternalProcess -Exe $ffprobe -Arguments $probeArgs -TimeoutSec 60
        if ($result.Ok) {
            $parsed = 0.0
            if ([double]::TryParse($result.Out.Trim(), [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
                return $parsed
            }
        }
    }

    # Some installs ship ffmpeg without ffprobe; ffmpeg itself reports the
    # duration on stderr when asked to open a file with no output target.
    $ffmpeg = Get-ToolPath -Name "ffmpeg"
    if (-not $ffmpeg) { return $null }
    $result = Invoke-ExternalProcess -Exe $ffmpeg -Arguments @("-i", $Path) -TimeoutSec 60
    if ($result.Err -match "Duration:\s*(\d+):(\d\d):(\d\d(?:\.\d+)?)") {
        return ([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) +
        [double]::Parse($Matches[3], [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

function Export-AudioFile {
    # Extract a single compressed speech-quality audio file. $null on failure.
    param([string]$Path, [string]$OutDir, [int]$TimeoutSec)

    $ffmpeg = Get-ToolPath -Name "ffmpeg"
    if (-not $ffmpeg) { return $null }
    foreach ($candidate in $AudioCandidates) {
        $outPath = Join-Path $OutDir ("audio." + $candidate.Ext)
        $ffArgs = @("-v", "error", "-y", "-i", $Path, "-vn", "-ac", "1", "-ar", "16000")
        $ffArgs += $candidate.Args
        $ffArgs += $outPath
        $result = Invoke-ExternalProcess -Exe $ffmpeg -Arguments $ffArgs -TimeoutSec $TimeoutSec
        if ($result.Ok -and (Test-Path $outPath) -and (Get-Item $outPath).Length -gt 0) {
            return $outPath
        }
        if (Test-Path $outPath) { Remove-Item $outPath -Force }
    }
    return $null
}

function Split-AudioFile {
    # Extract audio and cut it into ChunkSeconds pieces. $null on failure.
    param([string]$Path, [string]$OutDir, [double]$ChunkSeconds, [int]$TimeoutSec)

    $ffmpeg = Get-ToolPath -Name "ffmpeg"
    if (-not $ffmpeg) { return $null }
    foreach ($candidate in $AudioCandidates) {
        $pattern = Join-Path $OutDir ("part_%04d." + $candidate.Ext)
        $ffArgs = @("-v", "error", "-y", "-i", $Path, "-vn", "-ac", "1", "-ar", "16000")
        $ffArgs += $candidate.Args
        $ffArgs += @("-f", "segment", "-segment_time", ([int]$ChunkSeconds).ToString(),
            "-reset_timestamps", "1", $pattern)
        $result = Invoke-ExternalProcess -Exe $ffmpeg -Arguments $ffArgs -TimeoutSec $TimeoutSec
        $parts = @(Get-ChildItem -Path $OutDir -Filter ("part_*." + $candidate.Ext) -ErrorAction SilentlyContinue |
            Sort-Object Name | ForEach-Object { $_.FullName })
        if ($result.Ok -and $parts.Count -gt 0) { return $parts }
        foreach ($leftover in $parts) { Remove-Item $leftover -Force }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Providers
# ---------------------------------------------------------------------------

function Invoke-GeminiTranscribe {
    param([string]$Path, [string]$Mime, [string]$ApiKey, [string]$Model, [string]$Lang)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $size = $bytes.Length
    $displayName = [System.IO.Path]::GetFileName($Path)

    $startUri = "https://generativelanguage.googleapis.com/upload/v1beta/files?key=$ApiKey"
    $startBody = @{ file = @{ display_name = $displayName } } | ConvertTo-Json
    $startHeaders = @{
        "X-Goog-Upload-Protocol"              = "resumable"
        "X-Goog-Upload-Command"               = "start"
        "X-Goog-Upload-Header-Content-Length" = "$size"
        "X-Goog-Upload-Header-Content-Type"   = $Mime
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

# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

function Invoke-TranscribeOne {
    # Transcribe one file, Gemini first then Whisper.
    # Returns @{ Text; Provider; Errors }; Text is $null when both failed.
    param(
        [string]$Path,
        [string]$GeminiKey,
        [string]$OpenAIKey,
        [string]$TmpDir,
        [bool]$AllowAudioShrink
    )

    $errorList = @()
    $mime = Get-MimeType -Path $Path

    if ($GeminiKey) {
        try {
            $text = Invoke-GeminiTranscribe -Path $Path -Mime $mime -ApiKey $GeminiKey -Model $GeminiModel -Lang $Language
            return @{ Text = $text; Provider = "gemini ($GeminiModel)"; Errors = $errorList }
        }
        catch {
            $errorList += "gemini: $_"
        }
    }
    else {
        $errorList += "gemini: no API key found"
    }

    if (-not $OpenAIKey) {
        $errorList += "openai: no API key found"
        return @{ Text = $null; Provider = $null; Errors = $errorList }
    }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $size = (Get-Item $Path).Length

    # A video that Whisper would reject outright - wrong container, or simply
    # too big - often fits comfortably once the audio track is pulled out.
    if ($AllowAudioShrink -and (($WhisperExts -notcontains $ext) -or ($size -gt $WhisperMaxBytes))) {
        $shrunk = Export-AudioFile -Path $Path -OutDir $TmpDir -TimeoutSec $FfmpegTimeout
        if ($shrunk) {
            $Path = $shrunk
            $ext = [System.IO.Path]::GetExtension($shrunk).ToLowerInvariant()
            $mime = Get-MimeType -Path $shrunk
            $size = (Get-Item $shrunk).Length
        }
    }

    if ($WhisperExts -notcontains $ext) {
        $errorList += "openai: unsupported extension for Whisper API: $ext"
    }
    elseif ($size -gt $WhisperMaxBytes) {
        $errorList += "openai: file too large for Whisper API (25MB limit, got $size bytes)"
    }
    else {
        try {
            $text = Invoke-WhisperTranscribe -Path $Path -ApiKey $OpenAIKey -Lang $Language -Mime $mime
            return @{ Text = $text; Provider = "openai (whisper-1)"; Errors = $errorList }
        }
        catch {
            $errorList += "openai: $_"
        }
    }
    return @{ Text = $null; Provider = $null; Errors = $errorList }
}

function Write-FatalError {
    # Write-Error would throw under $ErrorActionPreference = "Stop", so the
    # explicit exit code below would never be reached.
    param([string]$Message)
    [Console]::Error.WriteLine("error: $Message")
}

if (-not (Test-Path $InputFile)) {
    Write-FatalError "input file not found: $InputFile"
    exit 1
}

$geminiKey = Read-Key -EnvName "GEMINI_API_KEY" -KeyFile $GeminiKeyFile
$openaiKey = Read-Key -EnvName "OPENAI_API_KEY" -KeyFile $OpenAIKeyFile

$duration = Get-MediaDuration -Path $InputFile
$chunkSeconds = $SplitMinutes * 60
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$transcript = $null
$providerLabel = $null
$chunkNote = $null
$failures = @()

try {
    $parts = $null
    $shouldSplit = ($chunkSeconds -gt 0) -and
        ((($null -ne $duration) -and ($duration -gt $chunkSeconds)) -or (($null -eq $duration) -and $ForceSplit))

    if ($shouldSplit) {
        if (-not (Get-ToolPath -Name "ffmpeg")) {
            Write-Host "warning: media is longer than -SplitMinutes but ffmpeg was not found; sending the whole file in one request instead"
        }
        else {
            $lengthText = if ($null -ne $duration) { Format-Timestamp -Seconds $duration } else { "unknown" }
            Write-Host "splitting audio ($lengthText) into $SplitMinutes-minute chunks..."
            $parts = Split-AudioFile -Path $InputFile -OutDir $tmpDir -ChunkSeconds $chunkSeconds -TimeoutSec $FfmpegTimeout
            if (-not $parts) {
                Write-Host "warning: ffmpeg could not split the audio; sending the whole file instead"
            }
        }
    }

    if ($parts) {
        $texts = @()
        $providers = @()
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $offset = Format-Timestamp -Seconds ($i * $chunkSeconds)
            $result = Invoke-TranscribeOne -Path $parts[$i] -GeminiKey $geminiKey -OpenAIKey $openaiKey -TmpDir $tmpDir -AllowAudioShrink $false
            if (-not $result.Text) {
                $reason = ($result.Errors -join "; ")
                $failures += "chunk $($i + 1)/$($parts.Count) ($offset): $reason"
                $texts += "[!! failed to transcribe the chunk starting at $offset : $reason !!]"
                Write-Host "  chunk $($i + 1)/$($parts.Count) FAILED ($offset)"
                continue
            }
            $providers += $result.Provider
            if ($NoChunkMarkers) { $texts += $result.Text }
            else { $texts += "[$offset]`n`n$($result.Text)" }
            Write-Host "  chunk $($i + 1)/$($parts.Count) ok ($offset, $($result.Provider), $($result.Text.Length) chars)"
        }
        if ($providers.Count -eq 0) {
            Write-FatalError "transcription failed on every chunk:`n$($failures -join [Environment]::NewLine)"
            exit 1
        }
        $transcript = ($texts -join "`n`n")
        $providerLabel = (($providers | Sort-Object -Unique) -join ", ")
        $chunkNote = "$($parts.Count) chunks x ${SplitMinutes}min"
    }
    else {
        $result = Invoke-TranscribeOne -Path $InputFile -GeminiKey $geminiKey -OpenAIKey $openaiKey -TmpDir $tmpDir -AllowAudioShrink $true
        if (-not $result.Text) {
            Write-FatalError "transcription failed on all providers:`n$($result.Errors -join [Environment]::NewLine)"
            exit 1
        }
        $transcript = $result.Text
        $providerLabel = $result.Provider
    }
}
finally {
    Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
}

if ($OutFile) {
    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    $content = $transcript
    if (-not $NoHeader) {
        $headerLines = @(
            "<!--",
            "generated_at: $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
            "source: $InputFile",
            "provider: $providerLabel"
        )
        if ($null -ne $duration) { $headerLines += "duration: $(Format-Timestamp -Seconds $duration)" }
        if ($chunkNote) { $headerLines += "chunks: $chunkNote" }
        if ($failures.Count -gt 0) { $headerLines += "partial: yes ($($failures.Count) chunk(s) failed)" }
        $headerLines += @("-->", "", "")
        $content = ($headerLines -join "`n") + $transcript
    }
    [IO.File]::WriteAllText($OutFile, $content, [System.Text.Encoding]::UTF8)
    $state = if ($failures.Count -gt 0) { "saved (partial)" } else { "saved" }
    Write-Output "$state ($providerLabel): $OutFile ($($transcript.Length) chars)"
}
else {
    Write-Output "# provider: $providerLabel`n"
    Write-Output $transcript
}

if ($failures.Count -gt 0) {
    Write-Warning "$($failures.Count) chunk(s) failed and are marked inline:`n$($failures -join [Environment]::NewLine)"
    exit 1
}
