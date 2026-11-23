# fi.ps1 - Run Z-Image Turbo (int8) locally on Windows with AMD Ryzen iGPU (Vulkan)
# Pure 7-bit ASCII for universal Windows PowerShell 5.1 codepage compatibility.
#
#   .\fi.bat "a red fox in fresh snow"          make one image -> outputs\
#   .\fi.bat "..." --size 768x768 --steps 6     fast iGPU preset
#   .\fi.bat serve                              web UI on http://localhost:7861
#   .\fi.bat app                                launch as desktop app window (auto-installs if needed)
#   .\fi.bat bench                              measure seconds per image on this machine
#   .\fi.bat doctor                             show detected hardware, Vulkan devices, and flags

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

. (Join-Path $PSScriptRoot "common.ps1")

$SD_PORT = if ($env:FI_SD_PORT) { [int]$env:FI_SD_PORT } else { 7860 }
$UI_PORT = if ($env:FI_UI_PORT) { [int]$env:FI_UI_PORT } else { 7861 }

function Show-Usage {
    Write-Host "fi - run Z-Image Turbo (int8) locally on Windows (AMD iGPU Edition)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host '  .\fi.bat "a red fox in fresh snow"          make one image -> outputs\'
    Write-Host '  .\fi.bat "..." --size 768x768 --seed 7      custom size and fixed seed'
    Write-Host "  .\fi.bat app                                one-click desktop app window"
    Write-Host "  .\fi.bat serve                              web UI on http://localhost:$UI_PORT"
    Write-Host "  .\fi.bat bench                              measure seconds per image on this machine"
    Write-Host "  .\fi.bat doctor                             show detected AMD iGPU, RAM, and engine flags"
    Write-Host ""
    Write-Host "Options for single images:"
    Write-Host "  --size WxH     default 768x768 on iGPU / 1024x1024 on dGPU (multiples of 64)"
    Write-Host "  --steps N      default 6 on iGPU / 8 on dGPU"
    Write-Host "  --seed N       default random"
    Write-Host "  -o FILE        output path (default outputs\<time>.png)"
}

function Test-EngineReady {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$SD_PORT/sdapi/v1/sd-models" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        return ($resp.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Format-QuotedArgs([string[]]$rawArgs) {
    $quoted = @()
    foreach ($a in $rawArgs) {
        if ($a -match '\s') {
            $quoted += "`"$a`""
        } else {
            $quoted += $a
        }
    }
    return $quoted
}

function Start-EngineServerAttempt([PSCustomObject]$hw, [string]$mode) {
    $binDir   = Join-Path $script:FI_HOME "bin"
    $sdServer = Join-Path $binDir "sd-server.exe"
    $engineArgs = Get-EngineArgs -hw $hw -mode $mode
    $defaultSteps = if ($hw.IsIGPU) { "6" } else { "8" }
    $rawArgs = @("--listen-ip", "127.0.0.1", "--listen-port", "$SD_PORT") + $engineArgs + @("--steps", $defaultSteps)
    $allArgs = Format-QuotedArgs $rawArgs

    $logFile = Join-Path $script:FI_HOME "server.log"
    $errFile = Join-Path $script:FI_HOME "server.err.log"

    $proc = Start-Process -FilePath $sdServer -ArgumentList $allArgs -WorkingDirectory $binDir `
        -NoNewWindow -PassThru -RedirectStandardOutput $logFile -RedirectStandardError $errFile

    $attempts = 0
    while (-not (Test-EngineReady)) {
        if ($proc.HasExited) {
            return [PSCustomObject]@{
                Success  = $false
                Process  = $proc
                ExitCode = $proc.ExitCode
                LogFile  = $logFile
                ErrFile  = $errFile
            }
        }
        $attempts++
        if ($attempts -gt 600) {
            try { Stop-Process -Id $proc.Id -Force } catch {}
            Stop-WithError "Engine did not start within 5 minutes. Log: $logFile"
        }
        Start-Sleep -Milliseconds 500
    }

    return [PSCustomObject]@{
        Success  = $true
        Process  = $proc
        ExitCode = 0
        LogFile  = $logFile
        ErrFile  = $errFile
    }
}

function Show-LogTail([string]$logFile, [string]$errFile) {
    if (Test-Path $errFile) {
        $errLines = @(Get-Content $errFile -Tail 15 -ErrorAction SilentlyContinue)
        foreach ($l in $errLines) {
            if ("$l".Trim()) { Write-Host "    $l" -ForegroundColor Red }
        }
    }
    if (Test-Path $logFile) {
        $logLines = @(Get-Content $logFile -Tail 15 -ErrorAction SilentlyContinue)
        foreach ($l in $logLines) {
            if ("$l".Trim()) { Write-Host "    $l" -ForegroundColor Yellow }
        }
    }
}

function Start-EngineServer([PSCustomObject]$hw) {
    if (Test-EngineReady) {
        Write-Info "Engine already running on port $SD_PORT"
        return $null
    }

    Write-Info "Loading Z-Image Turbo into memory (first start takes 15-45s)..."

    $modes = @("default")
    if (-not $hw.IsIntel) { $modes += "no-flash" }
    $modes += "cpu"

    foreach ($m in $modes) {
        if ($m -eq "no-flash") {
            Write-Warn "Retrying Vulkan engine with --flash-attn off for driver compatibility..."
        } elseif ($m -eq "cpu" -and $modes.Count -gt 1) {
            Write-Warn "Vulkan initialization failed on $($hw.GPUName) - automatically falling back to CPU AVX2 mode (--backend cpu)..."
            $hw.Platform = "cpu"
        }

        $res = Start-EngineServerAttempt -hw $hw -mode $m
        if ($res.Success) {
            return $res.Process
        }

        Write-Warn "sd-server exited during '$m' startup with code $(Format-ExitCode $res.ExitCode)"
        Show-LogTail -logFile $res.LogFile -errFile $res.ErrFile
    }

    Stop-WithError "Engine failed to start in both Vulkan and CPU modes. Run '.\fi.bat doctor' to inspect your setup."
}

function Open-AppWindow([string]$url) {
    $edgePaths = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:LocalAppData\Microsoft\Edge\Application\msedge.exe"
    )
    foreach ($p in $edgePaths) {
        if (Test-Path $p) {
            Start-Process -FilePath $p -ArgumentList "--app=$url", "--window-size=960,860" | Out-Null
            return
        }
    }
    Start-Process $url | Out-Null
}

function Invoke-Serve([PSCustomObject]$hw, [bool]$openBrowser = $false) {
    Assert-Installation $hw
    $pyExe = Find-PythonExe
    if (-not $pyExe) {
        Stop-WithError "Python 3 not found. Run .\install.bat --build to install portable Python."
    }

    $sdProc = Start-EngineServer $hw
    Write-Ok "Engine ready: $($hw.DeviceSummary) [$($hw.Platform.ToUpper())]"
    $uiUrl = "http://localhost:$UI_PORT"
    Write-Ok "Web UI (PWA) ready: $uiUrl"
    Write-Info "Keep this window open while using the app. Press Ctrl+C to stop."

    $env:FI_SD_URL   = "http://127.0.0.1:$SD_PORT"
    $env:FI_OUT      = Join-Path $script:ROOT "outputs"
    $env:FI_DEVICE   = $hw.DeviceSummary
    $env:FI_GPU_NAME = $hw.GPUName
    $env:FI_CPU_NAME = $hw.CPUName
    $env:FI_PLATFORM = $hw.Platform
    $env:FI_IS_IGPU  = if ($hw.IsIGPU) { "1" } else { "0" }
    $env:FI_RAM_GB   = "$($hw.RAMGB)"
    $env:FI_LLM_NAME = Split-Path (Get-LlmModelPath $hw) -Leaf

    if ($openBrowser) {
        Open-AppWindow $uiUrl
    }

    try {
        $servePy = Join-Path $script:ROOT "ui\serve.py"
        & $pyExe $servePy --port $UI_PORT
    } finally {
        if ($sdProc -and -not $sdProc.HasExited) {
            Write-Info "Stopping sd-server..."
            try { Stop-Process -Id $sdProc.Id -Force } catch {}
        }
    }
}

function Invoke-App([PSCustomObject]$hw) {
    $sdSrv = Join-Path $script:FI_HOME "bin\sd-server.exe"
    $diff  = Join-Path $script:FI_HOME "models\z_image_turbo_int8_convrot.safetensors"
    if (-not ((Test-Path $sdSrv) -and (Test-Path $diff))) {
        Write-Step "First-time setup detected - running installer automatically"
        & (Join-Path $PSScriptRoot "install.ps1")
    }
    Invoke-Serve -hw $hw -openBrowser $true
}

function Invoke-Generate([PSCustomObject]$hw, [string[]]$cliArgs) {
    $prompt = ""
    $size   = if ($hw.IsIGPU) { "768x768" } else { "1024x1024" }
    $steps  = if ($hw.IsIGPU) { 6 } else { 8 }
    $seed   = -1
    $out    = ""

    $i = 0
    while ($i -lt $cliArgs.Count) {
        switch ($cliArgs[$i]) {
            "--size"  { $size  = $cliArgs[$i + 1]; $i += 2 }
            "--steps" { $steps = [int]$cliArgs[$i + 1]; $i += 2 }
            "--seed"  { $seed  = [int]$cliArgs[$i + 1]; $i += 2 }
            "-o"      { $out   = $cliArgs[$i + 1]; $i += 2 }
            "--out"   { $out   = $cliArgs[$i + 1]; $i += 2 }
            "-h"      { Show-Usage; exit 0 }
            "--help"  { Show-Usage; exit 0 }
            default   {
                if ($prompt) { $prompt += " " }
                $prompt += $cliArgs[$i]
                $i++
            }
        }
    }

    if (-not $prompt) {
        Show-Usage
        exit 1
    }

    Assert-Installation $hw
    $parts = $size -split "x"
    $w = $parts[0]
    $h = $parts[1]

    $outDir = Join-Path $script:ROOT "outputs"
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    if (-not $out) {
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $out = Join-Path $outDir "$stamp.png"
    }

    Write-Info "$($hw.GPUName) | ${w}x${h} | $steps steps"
    $binDir = Join-Path $script:FI_HOME "bin"
    $sdCli  = Join-Path $binDir "sd-cli.exe"
    $engineArgs = Get-EngineArgs $hw
    $lastLog = Join-Path $script:FI_HOME "last.log"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $allArgs = $engineArgs + @("-p", $prompt, "-W", "$w", "-H", "$h", "--steps", "$steps", "-s", "$seed", "-o", $out)

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Push-Location $binDir
        & $sdCli @allArgs *> $lastLog
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
        $ErrorActionPreference = $oldEAP
    }

    if ($exitCode -ne 0) {
        if (Test-Path $lastLog) { Get-Content $lastLog -Tail 25 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red } }
        Stop-WithError "Generation failed (exit code $(Format-ExitCode $exitCode)). Full log: $lastLog"
    }
    $sw.Stop()
    $secs = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Ok "$out  ($secs s incl. model load - use 'start-app.bat' or 'fi.bat serve' to keep it loaded)"
}

function Invoke-Bench([PSCustomObject]$hw) {
    Assert-Installation $hw
    $sdProc = Start-EngineServer $hw
    try {
        $prompts = @(
            "a red fox standing in fresh snow at golden hour, detailed fur",
            "a cozy ramen shop at night in the rain, neon reflections",
            "studio portrait of an elderly fisherman, soft window light"
        )
        $w = if ($hw.IsIGPU) { 768 } else { 1024 }
        $h = if ($hw.IsIGPU) { 768 } else { 1024 }
        $steps = if ($hw.IsIGPU) { 6 } else { 8 }

        Write-Step "Benchmark: ${w}x${h}, $steps steps ($($hw.DeviceSummary))"
        Write-Info "warm-up..."
        $warmBody = @{ prompt = "warm up"; width = 512; height = 512; steps = 4; cfg_scale = 1.0; seed = 42 } | ConvertTo-Json
        Invoke-RestMethod -Uri "http://127.0.0.1:$SD_PORT/sdapi/v1/txt2img" -Method Post -ContentType "application/json" -Body $warmBody -TimeoutSec 600 | Out-Null

        $total = 0.0
        foreach ($p in $prompts) {
            $body = @{ prompt = $p; width = $w; height = $h; steps = $steps; cfg_scale = 1.0; seed = 42 } | ConvertTo-Json
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-RestMethod -Uri "http://127.0.0.1:$SD_PORT/sdapi/v1/txt2img" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 900 | Out-Null
            $sw.Stop()
            $t = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            $total += $t
            Write-Host ("  {0,6:N1} s  {1}" -f $t, $p)
        }
        $avg = [math]::Round($total / $prompts.Count, 1)
        Write-Ok "$avg s per image on average (${w}x${h}, $steps steps)"
    } finally {
        if ($sdProc -and -not $sdProc.HasExited) {
            try { Stop-Process -Id $sdProc.Id -Force } catch {}
        }
    }
}

function Invoke-Doctor([PSCustomObject]$hw) {
    $binDir = Join-Path $script:FI_HOME "bin"
    $sdCli  = Join-Path $binDir "sd-cli.exe"
    $diff   = Join-Path $script:FI_HOME "models\z_image_turbo_int8_convrot.safetensors"
    $llm    = Get-LlmModelPath $hw
    $vae    = Join-Path $script:FI_HOME "models\ae.safetensors"
    $engineArgs = Get-EngineArgs $hw

    $gpuMode = if ($hw.IsIGPU) { "Integrated GPU | Unified RAM" } else { "$($hw.VRAMMB) MB VRAM" }
    $engStatus = if (Test-Path $sdCli) { "installed ($($hw.Platform) x64)" } else { "not installed (run .\install.bat)" }
    $pyPath = Find-PythonExe
    $pyStatus = if ($pyPath) { $pyPath } else { "not installed (run .\install.bat --build)" }
    $llmLeaf = Split-Path $llm -Leaf
    $modStatus = if ((Test-Path $diff) -and (Test-Path $llm) -and (Test-Path $vae)) { "present ($llmLeaf)" } else { "missing (run .\install.bat --models)" }

    Write-Host "platform : $($hw.Platform)"
    Write-Host "cpu      : $($hw.CPUName) ($($hw.PhysicalCores) cores / $($hw.LogicalCores) threads)"
    Write-Host "gpu/igpu : $($hw.GPUName) ($gpuMode)"
    Write-Host "memory   : $($hw.RAMGB) GB total system RAM"
    Write-Host "home     : $($script:FI_HOME)"
    Write-Host "engine   : $engStatus"
    Write-Host "python   : $pyStatus"
    Write-Host "models   : $modStatus"
    Write-Host "flags    : $($engineArgs -join ' ')"

    if (Test-Path $sdCli) {
        Ensure-EngineRuntime
        Write-Host ""
        Write-Host "compute devices reported by sd-cli:" -ForegroundColor Cyan
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            Push-Location $binDir
            & $sdCli --list-devices
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  sd-cli exited with code $(Format-ExitCode $LASTEXITCODE)" -ForegroundColor Red
            }
        } catch {
            Write-Host "  (unable to query devices)"
        } finally {
            Pop-Location -ErrorAction SilentlyContinue
            $ErrorActionPreference = $oldEAP
        }
    }
}

$hw = Get-HardwareProfile
$cmd = if ($ArgsList.Count -gt 0) { $ArgsList[0] } else { "" }

switch ($cmd) {
    ""        { Show-Usage }
    "-h"      { Show-Usage }
    "--help"  { Show-Usage }
    "help"    { Show-Usage }
    "serve"   { Invoke-Serve -hw $hw -openBrowser $false }
    "app"     { Invoke-App -hw $hw }
    "bench"   { Invoke-Bench -hw $hw }
    "doctor"  { Invoke-Doctor -hw $hw }
    default   { Invoke-Generate -hw $hw -cliArgs $ArgsList }
}
