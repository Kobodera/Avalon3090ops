# Vision test: render text to a PNG, POST as base64 data URI to /v1/chat/completions, check OCR.
param([string]$BaseUrl = 'http://localhost:8080')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$png = Join-Path $PSScriptRoot 'vision_test.png'
$bmp = New-Object System.Drawing.Bitmap 640, 200
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
$g.DrawString('AVALON VISION TEST 3090', (New-Object System.Drawing.Font('Arial', 24, [System.Drawing.FontStyle]::Bold)), $brush, 10, 20)
$g.DrawString('The quick brown fox jumps over the lazy dog.', (New-Object System.Drawing.Font('Arial', 18)), $brush, 10, 80)
$g.DrawString('Expert cache + MTP + mmproj = 42', (New-Object System.Drawing.Font('Arial', 18)), $brush, 10, 120)
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png))
$body = @{
    model = 'test'
    messages = @(
        @{
            role = 'user'
            content = @(
                @{ type = 'image_url'; image_url = @{ url = "data:image/png;base64,$b64" } }
                @{ type = 'text'; text = 'Transcribe all text you see in this image, line by line.' }
            )
        }
    )
    max_tokens = 200
    temperature = 0.1
} | ConvertTo-Json -Depth 10

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$resp = Invoke-RestMethod -Uri "$BaseUrl/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 600
$sw.Stop()
$text = $resp.choices[0].message.content
Write-Output ("elapsed: {0:N1}s" -f $sw.Elapsed.TotalSeconds)
Write-Output ("response: " + $text)
$score = 0
if ($text -match 'AVALON') { $score++ }
if ($text -match 'quick brown fox') { $score++ }
if ($text -match '42') { $score++ }
Write-Output ("OCR score: $score / 3")
if ($score -eq 3) { Write-Output 'VISION PASS' } else { Write-Output 'VISION CHECK NEEDED' }
