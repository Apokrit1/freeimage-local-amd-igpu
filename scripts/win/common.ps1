# Shared helpers for Windows (install.bat, start-app.bat, fi.bat)
# Optimized for AMD Ryzen iGPU laptops (e.g., Acer Aspire Lite 15 Ryzen 7 5825U / Vega 8 / 16 GB RAM)
# Pure 7-bit ASCII for universal Windows PowerShell 5.1 codepage compatibility.

$ErrorActionPreference = "Stop"

$script:ROOT = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:FI_HOME = if ($env:FI_HOME) { $env:FI_HOME } else { Join-Path $script:ROOT ".fi" }
New-Item -ItemType Directory -Force -Path $script:FI_HOME | Out-Null

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Ok([string]$msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Stop-WithError([string]$msg) {
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

function Format-HumanSize([int64]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N1} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N1} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N1} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

function Get-FileSha256([string]$path) {
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Detects CPU, RAM, and GPU (specifically identifying AMD Radeon iGPUs such as Ryzen 7 5825U Vega 8)
function Get-HardwareProfile {
    $cpuName = "Unknown CPU"
    $physCores = 8
    $logCores = [Environment]::ProcessorCount
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cpu) {
            $cpuName = ($cpu.Name -replace '\s+', ' ').Trim()
            if ($cpu.NumberOfCores) { $physCores = [int]$cpu.NumberOfCores }
        }
    } catch {}

    $ramBytes = 16GB
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs -and $cs.TotalPhysicalMemory) {
            $ramBytes = [int64]$cs.TotalPhysicalMemory
        }
    } catch {}
    $ramGB = [math]::Round($ramBytes / 1GB, 1)

    $gpuName = "AMD Radeon Graphics"
    $vramMB = 512
    $isAmd = $false
    $isNvidia = $false
    $isIGPU = $true

    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
        $selected = $null
        foreach ($g in $gpus) {
            if ($g.Name -match "NVIDIA") { $selected = $g; break }
            if ($g.Name -match "AMD|Radeon") { $selected = $g }
        }
        if (-not $selected -and $gpus.Count -gt 0) { $selected = $gpus[0] }
        if ($selected) {
            $gpuName = ($selected.Name -replace '\s+', ' ').Trim()
            if ($selected.AdapterRAM -and $selected.AdapterRAM -gt 0) {
                $vramMB = [int][math]::Round($selected.AdapterRAM / 1MB)
            }
        }
    } catch {}

    if ($gpuName -match "NVIDIA") {
        $isNvidia = $true
        $isIGPU = $false
    } elseif ($gpuName -match "AMD|Radeon" -or $cpuName -match "AMD|Ryzen") {
        $isAmd = $true
        if ($gpuName -match "RX \d{4}" -and $vramMB -ge 6000) {
            $isIGPU = $false
        } else {
            $isIGPU = $true
        }
    }

    $platform = if ($env:FI_PLATFORM) {
        $env:FI_PLATFORM
    } else {
        "vulkan"
    }

    $lowMem = ($ramGB -le 18.0) -or ($env:FI_LOW_MEM -eq "1")
    $deviceSummary = if ($isIGPU) {
        "$gpuName ($cpuName | $ramGB GB shared RAM)"
    } else {
        "$gpuName ($vramMB MB VRAM | $ramGB GB RAM)"
    }

    return [PSCustomObject]@{
        Platform      = $platform
        CPUName       = $cpuName
        PhysicalCores = $physCores
        LogicalCores  = $logCores
        RAMBytes      = $ramBytes
        RAMGB         = $ramGB
        GPUName       = $gpuName
        VRAMMB        = $vramMB
        IsAMD         = $isAmd
        IsIGPU        = $isIGPU
        LowMem        = $lowMem
        DeviceSummary = $deviceSummary
    }
}

function Get-LlmModelPath([PSCustomObject]$hw) {
    $modelsDir = Join-Path $script:FI_HOME "models"
    $q4 = Join-Path $modelsDir "Qwen3-4B-Q4_K_M.gguf"
    $q8 = Join-Path $modelsDir "Qwen3-4B-Q8_0.gguf"

    if ($env:FI_LLM_QUANT -eq "q8" -and (Test-Path $q8)) { return $q8 }
    if ($env:FI_LLM_QUANT -eq "q4" -and (Test-Path $q4)) { return $q4 }

    if ($hw.LowMem -or $hw.IsIGPU) {
        if (Test-Path $q4) { return $q4 }
        if (Test-Path $q8) { return $q8 }
        return $q4
    } else {
        if (Test-Path $q8) { return $q8 }
        if (Test-Path $q4) { return $q4 }
        return $q8
    }
}

function Get-EngineArgs([PSCustomObject]$hw) {
    $modelsDir = Join-Path $script:FI_HOME "models"
    $diffusion = Join-Path $modelsDir "z_image_turbo_int8_convrot.safetensors"
    $vae       = Join-Path $modelsDir "ae.safetensors"
    $llm       = Get-LlmModelPath $hw

    $argsList = @(
        "--diffusion-model", $diffusion,
        "--vae", $vae,
        "--llm", $llm,
        "--cfg-scale", "1.0"
    )

    $threads = if ($env:FI_THREADS) { [int]$env:FI_THREADS } else { $hw.PhysicalCores }
    if ($threads -gt 0) {
        $argsList += @("--threads", "$threads")
    }

    if ($hw.IsIGPU -or $hw.LowMem) {
        $argsList += "--mmap"
        $argsList += "--offload-to-cpu"
        $maxVram = if ($env:FI_MAX_VRAM) { $env:FI_MAX_VRAM } elseif ($hw.RAMGB -le 18) { "3" } else { "6" }
        if ($maxVram -ne "0") {
            $argsList += @("--max-vram", "$maxVram")
        }
        $argsList += @("--flash-attn", "on")
        if ($env:FI_VAE_TILING -ne "0") {
            $argsList += "--vae-tiling"
        }
        if ($env:FI_TE_CPU -eq "1") {
            $argsList += @("--backend", "te=cpu")
        }
    } else {
        $argsList += @("--flash-attn", "on")
        if ($hw.VRAMMB -lt 12000 -or $env:FI_OFFLOAD -eq "1") {
            $argsList += "--offload-to-cpu"
        }
    }

    return $argsList
}

function Find-PythonExe {
    $portablePy = Join-Path $script:FI_HOME "python\python.exe"
    if (Test-Path $portablePy) { return $portablePy }

    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        foreach ($cmd in @("python", "python3")) {
            $found = Get-Command $cmd -ErrorAction SilentlyContinue
            if ($found -and $found.Source -notmatch "WindowsApps") {
                $ver = & $found.Source -c "import sys; print(sys.version_info.major)" 2>$null
                if ("$ver".Trim() -eq "3") { return $found.Source }
            }
        }
    } catch {} finally {
        $ErrorActionPreference = $oldEAP
    }
    return $null
}

function Assert-Installation([PSCustomObject]$hw) {
    $sdCli = Join-Path $script:FI_HOME "bin\sd-cli.exe"
    $sdSrv = Join-Path $script:FI_HOME "bin\sd-server.exe"
    if (-not ((Test-Path $sdCli) -and (Test-Path $sdSrv))) {
        Stop-WithError "Engine not installed yet. Double-click install.bat or run: .\install.bat"
    }
    $diff = Join-Path $script:FI_HOME "models\z_image_turbo_int8_convrot.safetensors"
    $vae  = Join-Path $script:FI_HOME "models\ae.safetensors"
    $llm  = Get-LlmModelPath $hw
    if (-not ((Test-Path $diff) -and (Test-Path $vae) -and (Test-Path $llm))) {
        Stop-WithError "Models are missing. Double-click install.bat or run: .\install.bat --models"
    }
}
