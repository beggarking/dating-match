# 교만추 AI 설명 서버 켜기
#   Ollama(로컬 LLM · 임베딩) → app.py(1위 설명 API) → Cloudflare 터널(인터넷 주소) → 사이트에 주소 등록
#   이 창이 열려 있는 동안만 켜져 있다. Enter 를 누르거나 창을 닫으면 모두 꺼진다.
#   컴퓨터를 켤 때 자동으로 실행되지 않는다 (바탕화면의 "교만추 AI 서버 켜기"를 더블클릭할 때만).
$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "교만추 AI 서버 (이 창을 닫으면 꺼져요)"
$dir = $PSScriptRoot
$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
$rpcBase = "https://vykpzywrgwgluldswias.supabase.co/rest/v1/rpc/"
$key = "sb_publishable_vjDGzZdpn5w4tcOMgXLnfQ_ILVQk-e0"
$secret = (Get-Content "$dir\secret.txt" -Raw).Trim()
$LLM = "exaone3.5:2.4b"; $EMBED = "qwen3-embedding:0.6b"

function Set-AiUrl($url) {
  $body = @{ p_secret = $secret; p_url = $url } | ConvertTo-Json -Compress
  Invoke-RestMethod -Method Post -Uri ($rpcBase + "ml_set_ai_url") -Headers @{ apikey = $key } -ContentType "application/json" -Body $body | Out-Null
}
function Wait-Until($what, $seconds, [scriptblock]$test) {
  $until = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $until) { try { if (& $test) { return } } catch {} ; Start-Sleep -Milliseconds 700 }
  throw "$what 이(가) $seconds 초 안에 준비되지 않았어요."
}
function Post-Json($path, $obj, $timeout = 300) {
  $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
  Invoke-RestMethod -Method Post -Uri ("http://127.0.0.1:7860" + $path) -ContentType "application/json; charset=utf-8" -Body $bytes -TimeoutSec $timeout
}

Write-Host ""
Write-Host "  교만추 AI 서버를 켜는 중이에요..." -ForegroundColor Yellow
$procs = @()
try {
  # 1) Ollama: 이 PC 안(127.0.0.1:11435)에서만, 모델 폴더를 직접 지정해서 따로 띄운다
  $env:OLLAMA_MODELS = "$env:USERPROFILE\.ollama\models"
  $env:OLLAMA_HOST = "127.0.0.1:11435"
  $env:OLLAMA_KEEP_ALIVE = "-1"
  $procs += Start-Process $ollama "serve" -NoNewWindow -PassThru -RedirectStandardOutput "$dir\ollama.out.log" -RedirectStandardError "$dir\ollama.log"
  Wait-Until "Ollama" 30 { Invoke-RestMethod "http://127.0.0.1:11435/api/version" -TimeoutSec 2 }
  Write-Host "  [1/4] 로컬 LLM(Ollama) 켜짐"
  $have = (Invoke-RestMethod "http://127.0.0.1:11435/api/tags").models.name
  foreach ($m in $LLM, $EMBED) {
    if ($have -notcontains $m) { Write-Host "        처음 한 번 모델 받는 중: $m"; & $ollama pull $m }
  }

  # 2) 1위 설명 API (app.py): 역시 이 PC 안에서만
  $env:OLLAMA_URL = "http://127.0.0.1:11435"; $env:LLM_MODEL = $LLM; $env:EMBED_MODEL = $EMBED; $env:PORT = "7860"
  $env:PYTHONIOENCODING = "utf-8"
  $procs += Start-Process python "`"$dir\app.py`"" -NoNewWindow -PassThru -RedirectStandardOutput "$dir\app.log" -RedirectStandardError "$dir\app-err.log"
  Wait-Until "API" 20 { Invoke-RestMethod "http://127.0.0.1:7860/" -TimeoutSec 2 }
  Write-Host "  [2/4] 설명 API 켜짐"

  # 모델을 미리 메모리에 올려 둔다 (첫 방문자가 기다리지 않게)
  Write-Host "        모델 불러오는 중 (30초쯤)..."
  Post-Json "/embed" @{ texts = @("준비", "운동") } | Out-Null
  Post-Json "/explain" @{ facts = @("하늘님이 60점으로 1위예요.") } | Out-Null
  Write-Host "  [3/4] 모델 준비 완료"

  # 3) Cloudflare 터널: 설명 API(7860)만 인터넷 주소로 연다
  if (Test-Path "$dir\tunnel.log") { Remove-Item "$dir\tunnel.log" }
  $procs += Start-Process "$dir\cloudflared.exe" "tunnel --no-autoupdate --url http://127.0.0.1:7860" -NoNewWindow -PassThru -RedirectStandardOutput "$dir\tunnel.out.log" -RedirectStandardError "$dir\tunnel.log"
  $url = $null
  Wait-Until "터널" 60 { $script:url = (Select-String -Path "$dir\tunnel.log" -Pattern "https://[a-z0-9-]+\.trycloudflare\.com" | Select-Object -First 1).Matches.Value; $script:url }
  Wait-Until "터널 연결" 60 { (Invoke-RestMethod "$url/" -TimeoutSec 5).ok }
  Set-AiUrl $url
  Write-Host "  [4/4] 인터넷에 연결됨: $url"
  Write-Host ""
  Write-Host "  켜졌어요! 이제 사이트에서 'AI에게 1위 이유 듣기'를 누르면 이 PC의 LLM이 설명해요." -ForegroundColor Green
  Write-Host "  끄려면 이 창에서 Enter 를 누르거나 창을 닫으세요."
  [void](Read-Host)
}
catch {
  Write-Host ""
  Write-Host "  켜는 중에 문제가 생겼어요: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "  (자세한 내용은 $dir 의 *.log 파일)"
  [void](Read-Host "  Enter 를 누르면 창이 닫혀요")
}
finally {
  try { Set-AiUrl $null } catch {}
  $procs | Where-Object { $_ -and -not $_.HasExited } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
  Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" | Where-Object { $procs.Id -contains $_.ParentProcessId } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
