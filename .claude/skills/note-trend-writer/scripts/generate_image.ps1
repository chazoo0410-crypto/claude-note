<#
.SYNOPSIS
  Generate an article title illustration and save it as PNG at a fixed
  output size (default 1280x670, note.com's standard eyecatch size).
  Tries Gemini 2.5 Flash Image (nanobanana) first, falls back to
  OpenAI gpt-image-1 on failure.

.PARAMETER Prompt
  Image prompt (English recommended)

.PARAMETER OutFile
  Output PNG path

.PARAMETER Width
  Output image width in pixels (default 1280)

.PARAMETER Height
  Output image height in pixels (default 670)

.PARAMETER GeminiKeyFile
  Path to a file containing the Gemini API key (default: .secrets/gemini_api_key.txt)
  This path is gitignored and local-only - never commit real key values.

.PARAMETER OpenAIKeyFile
  Path to a file containing the OpenAI API key (default: .secrets/openai_api_key.txt)

.EXAMPLE
  pwsh -File generate_image.ps1 -Prompt "..." -OutFile "output/images/foo.png"
#>
param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$Width = 1280,
    [int]$Height = 670,
    [string]$GeminiKeyFile = ".secrets/gemini_api_key.txt",
    [string]$OpenAIKeyFile = ".secrets/openai_api_key.txt"
)

$ErrorActionPreference = "Stop"

function Read-Key {
    param([string]$EnvName, [string]$KeyFile)
    $envVal = [Environment]::GetEnvironmentVariable($EnvName)
    if ($envVal) { return $envVal }
    if (Test-Path $KeyFile) { return (Get-Content $KeyFile -Raw).Trim() }
    return $null
}

function ConvertTo-CroppedImage {
    param([byte[]]$Bytes, [int]$TargetWidth, [int]$TargetHeight)

    Add-Type -AssemblyName System.Drawing

    $srcStream = New-Object System.IO.MemoryStream(, $Bytes)
    $src = [System.Drawing.Image]::FromStream($srcStream)

    $srcRatio = $src.Width / $src.Height
    $targetRatio = $TargetWidth / $TargetHeight

    if ($srcRatio -gt $targetRatio) {
        $scale = $TargetHeight / $src.Height
    }
    else {
        $scale = $TargetWidth / $src.Width
    }

    $scaledW = [Math]::Max(1, [int][Math]::Ceiling($src.Width * $scale))
    $scaledH = [Math]::Max(1, [int][Math]::Ceiling($src.Height * $scale))

    $scaledBmp = New-Object System.Drawing.Bitmap($scaledW, $scaledH)
    $g1 = [System.Drawing.Graphics]::FromImage($scaledBmp)
    $g1.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g1.DrawImage($src, 0, 0, $scaledW, $scaledH)
    $g1.Dispose()
    $src.Dispose()
    $srcStream.Dispose()

    $cropX = [int](($scaledW - $TargetWidth) / 2)
    $cropY = [int](($scaledH - $TargetHeight) / 2)

    $finalBmp = New-Object System.Drawing.Bitmap($TargetWidth, $TargetHeight)
    $g2 = [System.Drawing.Graphics]::FromImage($finalBmp)
    $srcRect = New-Object System.Drawing.Rectangle($cropX, $cropY, $TargetWidth, $TargetHeight)
    $destRect = New-Object System.Drawing.Rectangle(0, 0, $TargetWidth, $TargetHeight)
    $g2.DrawImage($scaledBmp, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
    $g2.Dispose()
    $scaledBmp.Dispose()

    $outStream = New-Object System.IO.MemoryStream
    $finalBmp.Save($outStream, [System.Drawing.Imaging.ImageFormat]::Png)
    $finalBmp.Dispose()

    return $outStream.ToArray()
}

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$errors = @()

$geminiKey = Read-Key -EnvName "GEMINI_API_KEY" -KeyFile $GeminiKeyFile
if ($geminiKey) {
    try {
        $body = @{
            contents         = @(@{ parts = @(@{ text = $Prompt }) })
            generationConfig = @{ responseModalities = @("IMAGE") }
        } | ConvertTo-Json -Depth 6
        $uri = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent?key=$geminiKey"
        $resp = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -TimeoutSec 40
        $b64 = $resp.candidates[0].content.parts | Where-Object { $_.inlineData } | Select-Object -First 1 -ExpandProperty inlineData | Select-Object -ExpandProperty data
        if (-not $b64) { throw "no image data in Gemini response" }
        $finalBytes = ConvertTo-CroppedImage -Bytes ([Convert]::FromBase64String($b64)) -TargetWidth $Width -TargetHeight $Height
        [IO.File]::WriteAllBytes($OutFile, $finalBytes)
        Write-Output "saved (gemini, ${Width}x${Height}): $OutFile ($((Get-Item $OutFile).Length) bytes)"
        return
    }
    catch {
        $errors += "gemini: $_"
    }
}
else {
    $errors += "gemini: no API key found"
}

$openaiKey = Read-Key -EnvName "OPENAI_API_KEY" -KeyFile $OpenAIKeyFile
if ($openaiKey) {
    try {
        $body = @{ model = "gpt-image-1"; prompt = $Prompt; size = "1536x1024"; n = 1 } | ConvertTo-Json
        $headers = @{ Authorization = "Bearer $openaiKey" }
        $resp = Invoke-RestMethod -Uri "https://api.openai.com/v1/images/generations" -Method Post -ContentType "application/json" -Headers $headers -Body $body -TimeoutSec 60
        $b64 = $resp.data[0].b64_json
        if (-not $b64) { throw "no image data in OpenAI response" }
        $finalBytes = ConvertTo-CroppedImage -Bytes ([Convert]::FromBase64String($b64)) -TargetWidth $Width -TargetHeight $Height
        [IO.File]::WriteAllBytes($OutFile, $finalBytes)
        Write-Output "saved (openai fallback, ${Width}x${Height}): $OutFile ($((Get-Item $OutFile).Length) bytes)"
        return
    }
    catch {
        $errors += "openai: $_"
    }
}
else {
    $errors += "openai: no API key found"
}

Write-Error "image generation failed on all providers:`n$($errors -join [Environment]::NewLine)"
exit 1
