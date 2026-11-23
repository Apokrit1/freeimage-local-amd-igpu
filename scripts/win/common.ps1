# Shared helpers for Windows (install.bat, start-app.bat, fi.bat)
# Optimized for AMD Ryzen iGPU laptops (e.g., Acer Aspire Lite 15 Ryzen 7 5825U / Vega 8 / 16 GB RAM)
# Pure 7-bit ASCII for universal Windows PowerShell 5.1 codepage compatibility.

$ErrorActionPreference = "Stop"

$script:ROOT = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:FI_HOME = if ($env:FI_HOME) { $env:FI_HOME } else { Join-Path $script:ROOT ".fi" }
New-Item -ItemType Directory -Force -Path $script:FI_HOME | Out-Null

function Write-Step([string]$msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Info([string]$msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Write-Warn([string]$msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
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

function Format-ExitCode([int]$code) {
    $u = [uint32]([int64]$code -band 0xFFFFFFFFL)
    return ("0x{0:X8} ({1})" -f $u, $code)
}

# Detects CPU, RAM, and GPU (identifying AMD Radeon iGPUs, Intel UHD/Iris iGPUs, or discrete GPUs)
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
    $isIntel = $false
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
    } elseif ($gpuName -match "AMD|Radeon") {
        $isAmd = $true
        if ($gpuName -match "RX \d{4}" -and $vramMB -ge 6000) {
            $isIGPU = $false
        } else {
            $isIGPU = $true
        }
    } elseif ($gpuName -match "Intel") {
        $isIntel = $true
        if ($gpuName -match "Arc A\d{3}|Arc B\d{3}" -and $vramMB -ge 6000) {
            $isIGPU = $false
        } else {
            $isIGPU = $true
        }
    }

    $platformFile = Join-Path $script:FI_HOME "platform"
    $savedPlatform = if (Test-Path $platformFile) { (Get-Content $platformFile -First 1).Trim() } else { "" }

    $platform = if ($env:FI_PLATFORM) {
        $env:FI_PLATFORM
    } elseif ($savedPlatform) {
        $savedPlatform
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
        IsIntel       = $isIntel
        IsIGPU        = $isIGPU
        LowMem        = $lowMem
        DeviceSummary = $deviceSummary
    }
}

# Tests whether sd-server.exe can start; if VC++ 2015-2022 Redistributable (vcomp140.dll / msvcp140.dll 14.40+)
# is missing or outdated, automatically installs/repairs it. Also verifies Vulkan vs CPU fallback.
function Ensure-EngineRuntime {
    $binDir = Join-Path $script:FI_HOME "bin"
    $sdSrv  = Join-Path $binDir "sd-server.exe"
    $sdCli  = Join-Path $binDir "sd-cli.exe"
    if (-not (Test-Path $sdSrv)) { return }

    # 1. Check if required VC++ DLLs exist and if sd-server.exe --version succeeds
    $sys32 = Join-Path $env:SystemRoot "System32"
    $neededDlls = @("vcomp140.dll", "msvcp140.dll", "msvcp140_codecvt_ids.dll", "vcruntime140.dll", "vcruntime140_1.dll")
    $missingDlls = @()
    foreach ($d in $neededDlls) {
        if (-not ((Test-Path (Join-Path $binDir $d)) -or (Test-Path (Join-Path $sys32 $d)))) {
            $missingDlls += $d
        }
    }

    # Check if msvcp140.dll is older than VS 2022 17.10 (14.40), which crashes on zero-init constexpr std::mutex
    $oldMsvcp = $false
    $msvcpPath = if (Test-Path (Join-Path $binDir "msvcp140.dll")) { Join-Path $binDir "msvcp140.dll" } elseif (Test-Path (Join-Path $sys32 "msvcp140.dll")) { Join-Path $sys32 "msvcp140.dll" } else { "" }
    if ($msvcpPath) {
        try {
            $vi = (Get-Item $msvcpPath).VersionInfo
            if ($vi.FileMajorPart -eq 14 -and $vi.FileMinorPart -lt 40) {
                $oldMsvcp = $true
            }
        } catch {}
    }

    $verOk = $false
    $verExit = 0
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Push-Location $binDir
        $null = & $sdSrv --version 2>&1
        $verExit = $LASTEXITCODE
        if ($verExit -eq 0) { $verOk = $true }
    } catch {
        $verOk = $false
    } finally {
        Pop-Location -ErrorAction SilentlyContinue
        $ErrorActionPreference = $oldEAP
    }

    if ((-not $verOk) -or ($missingDlls.Count -gt 0) -or $oldMsvcp) {
        if ($missingDlls.Count -gt 0) {
            Write-Warn "Missing Microsoft Visual C++ Runtime DLLs: $($missingDlls -join ', ')"
        } elseif ($oldMsvcp) {
            Write-Warn "System msvcp140.dll is older than v14.40 (VS 2022 17.10+ required by stable-diffusion.cpp)"
        } else {
            Write-Warn "Engine binary check returned $(Format-ExitCode $verExit) - repairing Visual C++ Runtime..."
        }

        # Step A: Download portable VC++ 14.51 runtime DLLs from NuGet (no admin required) for msvcp140 & vcruntime140
        $nupkgZip = Join-Path $script:FI_HOME "vcruntime140.zip"
        $nupkgDir = Join-Path $script:FI_HOME "vcruntime_tmp"
        $curlExe = Join-Path $env:SystemRoot "System32\curl.exe"
        if (-not (Test-Path $curlExe)) { $curlExe = "curl.exe" }
        try {
            Write-Info "Fetching portable VC++ 14.51 runtime DLLs..."
            & $curlExe -sL --retry 3 -o $nupkgZip "https://www.nuget.org/api/v2/package/ThinkGeo.Dependency.MicrosoftVisualCRuntime140/15.0.2"
            if (Test-Path $nupkgZip) {
                if (Test-Path $nupkgDir) { Remove-Item -Recurse -Force $nupkgDir }
                Expand-Archive -Path $nupkgZip -DestinationPath $nupkgDir -Force
                $x64Dir = Join-Path $nupkgDir "runtimes\win-x64\native"
                if (Test-Path $x64Dir) {
                    Get-ChildItem -Path $x64Dir -Filter "*.dll" | ForEach-Object {
                        Copy-Item -Path $_.FullName -Destination (Join-Path $binDir $_.Name) -Force
                    }
                }
                Remove-Item -Recurse -Force $nupkgDir -ErrorAction SilentlyContinue
                Remove-Item -Force $nupkgZip -ErrorAction SilentlyContinue
            }
        } catch {}

        # Step B: Copy any missing DLLs (like msvcp140_codecvt_ids.dll or vcomp140.dll) if found in local Edge / VS / Windows folders
        $searchRoots = @(
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application",
            "$env:ProgramFiles\Microsoft\Edge\Application",
            "$env:ProgramFiles\Microsoft Visual Studio",
            "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
        )
        foreach ($d in $neededDlls) {
            if (-not (Test-Path (Join-Path $binDir $d)) -and -not (Test-Path (Join-Path $sys32 $d))) {
                foreach ($sr in $searchRoots) {
                    if (Test-Path $sr) {
                        $found = Get-ChildItem -Path $sr -Filter $d -Recurse -ErrorAction SilentlyContinue |
                            Where-Object { $_.FullName -notmatch "arm64|x86|WOW64" } | Select-Object -First 1
                        if ($found) {
                            Copy-Item -Path $found.FullName -Destination (Join-Path $binDir $d) -Force
                            Write-Info "Copied $d from $($found.DirectoryName)"
                            break
                        }
                    }
                }
            }
        }

        # Re-test sd-server.exe --version
        $ErrorActionPreference = "Continue"
        try {
            Push-Location $binDir
            $null = & $sdSrv --version 2>&1
            if ($LASTEXITCODE -eq 0) { $verOk = $true }
        } catch {} finally {
            Pop-Location -ErrorAction SilentlyContinue
            $ErrorActionPreference = $oldEAP
        }

        # Step C: If still failing (e.g. VCOMP140.DLL is not installed on Windows), run official Microsoft vc_redist.x64.exe
        if (-not $verOk) {
            Write-Step "Installing Microsoft Visual C++ 2015-2022 Redistributable (x64) (required for VCOMP140.DLL OpenMP)"
            $vcExe = Join-Path $script:FI_HOME "vc_redist.x64.exe"
            & $curlExe -fL --retry 3 --progress-bar -o $vcExe "https://aka.ms/vs/17/release/vc_redist.x64.exe"
            if (Test-Path $vcExe) {
                Write-Info "Running vc_redist.x64.exe (please click Yes if Windows UAC prompts)..."
                $p = Start-Process -FilePath $vcExe -ArgumentList "/install", "/passive", "/norestart" -Wait -PassThru
                Write-Ok "Visual C++ Redistributable installer finished (code $($p.ExitCode))"
            }
        }
    }

    # 2. Test device enumeration (sd-cli.exe --list-devices). If ggml-vulkan.dll crashes on this GPU driver, fall back to CPU backend.
    if (Test-Path $sdCli) {
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $listOk = $false
        try {
            Push-Location $binDir
            $devs = & $sdCli --list-devices 2>&1
            if ($LASTEXITCODE -eq 0) { $listOk = $true }
        } catch {} finally {
            Pop-Location -ErrorAction SilentlyContinue
            $ErrorActionPreference = $oldEAP
        }

        $vkDll = Join-Path $binDir "ggml-vulkan.dll"
        if ((-not $listOk) -and (Test-Path $vkDll)) {
            Write-Warn "Vulkan backend (ggml-vulkan.dll) crashed or failed to initialize on this GPU driver."
            Write-Warn "Disabling ggml-vulkan.dll and switching to CPU AVX2 backend so the engine can run."
            Move-Item -Path $vkDll -Destination "$vkDll.disabled" -Force
            Set-Content -Path (Join-Path $script:FI_HOME "platform") -Value "cpu" -Encoding ASCII
        }
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

function Get-EngineArgs([PSCustomObject]$hw, [string]$mode = "default") {
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

    if ($mode -eq "cpu" -or $hw.Platform -eq "cpu") {
        $argsList += @("--backend", "cpu", "--mmap", "--vae-tiling")
        return $argsList
    }

    if ($hw.IsIGPU -or $hw.LowMem) {
        $argsList += "--mmap"
        $argsList += "--offload-to-cpu"
        $maxVram = if ($env:FI_MAX_VRAM) { $env:FI_MAX_VRAM } elseif ($hw.RAMGB -le 18) { "3" } else { "6" }
        if ($maxVram -ne "0" -and $mode -ne "no-flash") {
            $argsList += @("--max-vram", "$maxVram")
        }
        # Intel UHD Graphics 770 often fails on Vulkan Flash Attention shaders; only enable flash-attn by default on AMD/NVIDIA
        if ($mode -eq "no-flash" -or $hw.IsIntel) {
            $argsList += @("--flash-attn", "off")
        } else {
            $argsList += @("--flash-attn", "on")
        }
        if ($env:FI_VAE_TILING -ne "0") {
            $argsList += "--vae-tiling"
        }
        if ($env:FI_TE_CPU -eq "1") {
            $argsList += @("--backend", "te=cpu")
        }
    } else {
        if ($mode -eq "no-flash") {
            $argsList += @("--flash-attn", "off")
        } else {
            $argsList += @("--flash-attn", "on")
        }
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
    Ensure-EngineRuntime
}
