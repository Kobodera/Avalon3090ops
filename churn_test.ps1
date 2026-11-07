# Mixed IMG+CHAT+TOOLS churn test (stability gate).
# Alternates vision / plain chat / tool-call requests, checks /health between each.
# Flags: wedge (health fail or request timeout), empty/garbage response, tools failure.
param([string]$BaseUrl = 'http://localhost:8080', [int]$Rounds = 4)
$ErrorActionPreference = 'Continue'

function Post-Chat($body, $label, $timeoutSec = 300) {
    $json = $body | ConvertTo-Json -Depth 10
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-RestMethod -Uri "$BaseUrl/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $json -TimeoutSec $timeoutSec
        $sw.Stop()
        $txt = $resp.choices[0].message.content
        if (-not $txt) { $txt = '' }
        $tc = $resp.choices[0].message.tool_calls
        return [pscustomobject]@{ ok = $true; secs = $sw.Elapsed.TotalSeconds; text = $txt; tool_calls = $tc }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{ ok = $false; secs = $sw.Elapsed.TotalSeconds; text = $_.Exception.Message; tool_calls = $null }
    }
}

# build one test image once
Add-Type -AssemblyName System.Drawing
$png = Join-Path $PSScriptRoot 'churn_img.png'
$bmp = New-Object System.Drawing.Bitmap 512, 160
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::White)
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::Black)
$g.DrawString('CHURN ROUND MARKER 7749', (New-Object System.Drawing.Font('Arial', 22, [System.Drawing.FontStyle]::Bold)), $brush, 10, 15)
$g.DrawString('alpha bravo charlie delta', (New-Object System.Drawing.Font('Arial', 20)), $brush, 10, 70)
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png))

$pass = 0; $fail = 0
for ($r = 1; $r -le $Rounds; $r++) {
    # health gate between requests: catches wedges immediately
    try { Invoke-RestMethod -Uri "$BaseUrl/health" -TimeoutSec 10 | Out-Null }
    catch { Write-Output "ROUND $r PRE: HEALTH FAIL - possible wedge"; $fail++; continue }

    # 1) vision
    $v = Post-Chat @{ model='t'; max_tokens=120; temperature=0.1; messages=@(
        @{ role='user'; content=@(
            @{ type='image_url'; image_url=@{ url="data:image/png;base64,$b64" } }
            @{ type='text'; text='Transcribe all text in this image.' } ) }) } 'vision'
    $vok = $v.ok -and $v.text -match '7749' -and $v.text -match 'alpha bravo'
    Write-Output ("ROUND {0} VISION: ok={1} {2:N1}s match={3}" -f $r, $v.ok, $v.secs, ($v.text -match '7749'))
    if ($vok) { $pass++ } else { $fail++; Write-Output ("  text: " + $v.text.Substring(0, [Math]::Min(120, $v.text.Length))) }

    # 2) plain chat
    $c = Post-Chat @{ model='t'; max_tokens=64; temperature=0.2; messages=@(
        @{ role='user'; content='Reply with exactly: CHAT-OK-' + $r }) } 'chat'
    $cok = $c.ok -and $c.text -match ('CHAT-OK-' + $r)
    Write-Output ("ROUND {0} CHAT:   ok={1} {2:N1}s match={3}" -f $r, $c.ok, $c.secs, ($c.text -match ('CHAT-OK-' + $r)))
    if ($cok) { $pass++ } else { $fail++; Write-Output ("  text: " + $c.text.Substring(0, [Math]::Min(120, $c.text.Length))) }

    # 3) tools (schema: properties keyed by param name)
    $t = Post-Chat @{ model='t'; max_tokens=128; temperature=0.1; messages=@(
        @{ role='user'; content='What is 25 times 4? You MUST call the calculator tool.' }
    ); tools=@(
        @{ type='function'; function=@{ name='calculator'; description='Multiply two integers';
            parameters=@{ type='object'
                         properties=@{ a=@{ type='integer' }; b=@{ type='integer' } }
                         required=@('a','b') } } }) } 'tools'
    $tok = $t.ok -and $t.tool_calls -and ($t.tool_calls | Where-Object { $_.function.name -eq 'calculator' -and $_.function.arguments -match '25' -and $_.function.arguments -match '4' })
    Write-Output ("ROUND {0} TOOLS:  ok={1} {2:N1}s toolcall={3}" -f $r, $t.ok, $t.secs, [bool]$tok)
    if ($tok) { $pass++ } else { $fail++; Write-Output ("  text: " + $t.text + " calls: " + ($t.tool_calls | ConvertTo-Json -Compress)) }
}

Write-Output ("CHURN RESULT: pass=$pass fail=$fail of " + ($Rounds * 3))
if ($fail -eq 0) { Write-Output 'CHURN GATE PASS' } else { Write-Output 'CHURN GATE FAIL' }
