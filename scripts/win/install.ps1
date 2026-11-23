# freeimage-local Windows Portable Installer (Tuned for AMD Ryzen iGPU + 16 GB RAM)
# Pure 7-bit ASCII for universal Windows PowerShell 5.1 codepage compatibility.
#
#   .\install.bat              install Vulkan engine + portable Python + 16 GB optimized models (~9.0 GB)
#   .\install.bat --build      only download / verify the prebuilt Vulkan engine & portable Python
#   .\install.bat --models     only download / verify the models
#   .\install.bat --q8         use the larger 4.3 GB Qwen3-4B-Q8_0 text encoder instead of 2.5 GB Q4_K_M

param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsList
)

. (Join-Path $PSScriptRoot "common.ps1")

$SDCPP_RELEASE = "master-1106-532d2c1"
$SDCPP_VULKAN_URL = "https://github.com/leejet/stable-diffusion.cpp/releases/download/$SDCPP_RELEASE/sd-master-532d2c1-bin-win-vulkan-x64.zip"
$SDCPP_VULKAN_SHA = "3e66222c87ca27074e1fd8ce79706eef17a8aaf39949906aa1bee7e060f22ecc"

$SDCPP_CPU_URL = "https://github.com/leejet/stable-diffusion.cpp/releases/download/$SDCPP_RELEASE/sd-master-532d2c1-bin-win-cpu-x64.zip"
$SDCPP_CPU_SHA = "abef332cfca7861cc567910e79bedb70bfb2920bb4eedac97fcbb6db477f1596"

$PY_EMBED_URL = "https://www.python.org/ftp/python/3.12.8/python-3.12.8-embed-amd64.zip"

function Invoke-FileDownload([string]$url, [string]$dest, [string]$expectedSha = "", [int64]$expectedBytes = 0) {
    $curlExe = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path $curlExe)) { $curlExe = "curl.exe" }
    $leaf = Split-Path $dest -Leaf

    if (Test-Path $dest) {
        if ($expectedBytes -gt 0 -and (Get-Item $dest).Length -eq $expectedBytes) {
            Write-Info "$leaf : already downloaded"
        } elseif ($expectedBytes -eq 0 -and $expectedSha -ne "" -and (Get-FileSha256 $dest) -eq $expectedSha.ToLowerInvariant()) {
            Write-Info "$leaf : already downloaded"
        } else {
            $sizeLabel = if ($expectedBytes -gt 0) { " ($(Format-HumanSize $expectedBytes))" } else { "" }
            Write-Info "Resuming $leaf$sizeLabel..."
            & $curlExe -fL --retry 5 --retry-delay 3 -C - --progress-bar -o $dest $url
            if ($LASTEXITCODE -ne 0) {
                Write-Info "Resume not supported by server, restarting download for $leaf..."
                Remove-Item -Force $dest -ErrorAction SilentlyContinue
                & $curlExe -fL --retry 5 --retry-delay 3 --progress-bar -o $dest $url
                if ($LASTEXITCODE -ne 0) { Stop-WithError "Download failed for $leaf. Run install.bat again to retry." }
            }
        }
    } else {
        $sizeLabel = if ($expectedBytes -gt 0) { " ($(Format-HumanSize $expectedBytes))" } else { "" }
        Write-Info "Downloading $leaf$sizeLabel..."
        & $curlExe -fL --retry 5 --retry-delay 3 --progress-bar -o $dest $url
        if ($LASTEXITCODE -ne 0) { Stop-WithError "Download failed for $leaf. Run install.bat again to resume." }
    }

    if ($expectedSha -ne "" -and $env:FI_SKIP_VERIFY -ne "1") {
        Write-Host "    verifying SHA-256... " -NoNewline -ForegroundColor DarkGray
        $actualSha = Get-FileSha256 $dest
        if ($actualSha -ne $expectedSha.ToLowerInvariant()) {
            Write-Host "mismatch!" -ForegroundColor Red
            Stop-WithError "Checksum mismatch for $dest (expected $expectedSha, got $actualSha). Delete $dest and re-run install.bat."
        }
        Write-Host "ok" -ForegroundColor Green
    }
}

function Install-Engine([PSCustomObject]$hw, [bool]$useCpu = $false) {
    Write-Step "Checking your Windows machine"
    Write-Info "CPU      : $($hw.CPUName) ($($hw.PhysicalCores) cores / $($hw.LogicalCores) threads)"
    Write-Info "iGPU/GPU : $($hw.GPUName)"
    Write-Info "Memory   : $($hw.RAMGB) GB total system RAM"
    if ($hw.IsIGPU) {
        Write-Info "Profile  : AMD iGPU Unified Memory Mode (Vulkan + mmap + CPU offload + 3 GiB VRAM budget + VAE tiling)"
    }

    $binDir = Join-Path $script:FI_HOME "bin"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    $zipUrl = if ($useCpu) { $SDCPP_CPU_URL } else { $SDCPP_VULKAN_URL }
    $zipSha = if ($useCpu) { $SDCPP_CPU_SHA } else { $SDCPP_VULKAN_SHA }
    $zipName = Split-Path $zipUrl -Leaf
    $zipPath = Join-Path $script:FI_HOME $zipName

    $backendLabel = if ($useCpu) { "CPU AVX2" } else { "Vulkan x64" }
    Write-Step "Installing stable-diffusion.cpp engine ($SDCPP_RELEASE | $backendLabel)"
    Invoke-FileDownload -url $zipUrl -dest $zipPath -expectedSha $zipSha

    $extractTmp = Join-Path $script:FI_HOME "extract_tmp"
    if (Test-Path $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
    Expand-Archive -Path $zipPath -DestinationPath $extractTmp -Force

    Get-ChildItem -Path $extractTmp -Recurse -File | Where-Object {
        $_.Extension -in @(".exe", ".dll")
    } | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $binDir $_.Name) -Force
    }
    Remove-Item -Recurse -Force $extractTmp

    $platformName = if ($useCpu) { "cpu" } else { "vulkan" }
    Set-Content -Path (Join-Path $script:FI_HOME "platform") -Value $platformName -Encoding ASCII
    Write-Ok "Engine ready: $binDir\sd-server.exe"

    $sdCli = Join-Path $binDir "sd-cli.exe"
    if (Test-Path $sdCli) {
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $devs = & $sdCli --list-devices 2>&1
            if ($devs) {
                Write-Info "Detected compute backends:"
                foreach ($line in $devs) {
                    Write-Info "  $line"
                }
            }
        } catch {} finally {
            $ErrorActionPreference = $oldEAP
        }
    }

    $pyExe = Find-PythonExe
    if (-not $pyExe) {
        Write-Step "Installing portable Python 3.12 for Web UI (~11 MB)"
        $pyZip = Join-Path $script:FI_HOME "python-embed.zip"
        $pyDir = Join-Path $script:FI_HOME "python"
        Invoke-FileDownload -url $PY_EMBED_URL -dest $pyZip
        New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
        Expand-Archive -Path $pyZip -DestinationPath $pyDir -Force
        $pthFile = Join-Path $pyDir "python312._pth"
        if (Test-Path $pthFile) {
            $pthContent = Get-Content $pthFile
            $pthContent = $pthContent -replace '#import site', 'import site'
            $pthContent += "."
            Set-Content -Path $pthFile -Value $pthContent -Encoding ASCII
        }
        Write-Ok "Portable Python ready: $pyDir\python.exe"
    } else {
        Write-Ok "Python found: $pyExe"
    }
}

function Install-Models([PSCustomObject]$hw, [bool]$forceQ8 = $false) {
    $useQ4 = (-not $forceQ8) -and ($hw.LowMem -or $hw.IsIGPU)
    $totalLabel = if ($useQ4) { "~9.0 GB (16 GB iGPU optimized: int8 diffusion + Q4_K_M text encoder + VAE)" } else { "~10.8 GB (int8 diffusion + Q8_0 text encoder + VAE)" }

    Write-Step "Downloading models ($totalLabel, resumable)"
    $modelsDir = Join-Path $script:FI_HOME "models"
    New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

    $models = @(
        @{
            Name  = "diffusion (int8_convrot)"
            Url   = "https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/main/split_files/diffusion_models/z_image_turbo_int8_convrot.safetensors"
            Sha   = "be517ebd47c912a5626a588e1aeea43e6be4a43c0cdcd2b48a2a780d9f358635"
            Bytes = 6201001296
        }
    )

    if ($useQ4) {
        $models += @{
            Name  = "text-encoder (Qwen3-4B-Q4_K_M - saves 1.8 GB RAM on 16 GB iGPU)"
            Url   = "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q4_K_M.gguf"
            Sha   = "f6f851777709861056efcdad3af01da38b31223a3ba26e61a4f8bf3a2195813a"
            Bytes = 0
        }
    } else {
        $models += @{
            Name  = "text-encoder (Qwen3-4B-Q8_0)"
            Url   = "https://huggingface.co/unsloth/Qwen3-4B-GGUF/resolve/main/Qwen3-4B-Q8_0.gguf"
            Sha   = "eed555233267a33c7e8ee31682762cc7751b3f6d224039086e0e846f05fffa5d"
            Bytes = 4280405792
        }
    }

    $models += @{
        Name  = "vae (ae.safetensors)"
        Url   = "https://huggingface.co/Comfy-Org/Z-Image-Turbo/resolve/main/split_files/vae/ae.safetensors"
        Sha   = "afc8e28272cd15db3919bacdb6918ce9c1ed22e96cb12c4d5ed0fba823529e38"
        Bytes = 335304388
    }

    foreach ($m in $models) {
        $fileName = Split-Path $m.Url -Leaf
        $destPath = Join-Path $modelsDir $fileName
        Write-Info "$($m.Name)"
        Invoke-FileDownload -url $m.Url -dest $destPath -expectedSha $m.Sha -expectedBytes $m.Bytes
    }

    Write-Ok "Models ready: $modelsDir"
}

function New-DesktopShortcut {
    try {
        $desktop = [Environment]::GetFolderPath("Desktop")
        if (-not (Test-Path $desktop)) { return }
        $lnkPath = Join-Path $desktop "freeimage local.lnk"
        $targetBat = Join-Path $script:ROOT "start-app.bat"
        $wsh = New-Object -ComObject WScript.Shell
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath = $targetBat
        $sc.WorkingDirectory = $script:ROOT
        $sc.Description = "freeimage local - Z-Image Turbo on AMD iGPU"
        $sc.IconLocation = "$env:SystemRoot\System32\shell32.dll,165"
        $sc.Save()
        Write-Ok "Desktop shortcut created: $lnkPath"
    } catch {
        # Non-fatal if desktop shortcut creation is restricted
    }
}

$hw = Get-HardwareProfile
$mode = "all"
$forceQ8 = ($env:FI_LLM_QUANT -eq "q8")
$useCpu = $false

foreach ($a in $ArgsList) {
    switch ($a) {
        "--build"  { $mode = "build" }
        "--models" { $mode = "models" }
        "--q8"     { $forceQ8 = $true }
        "--cpu"    { $useCpu = $true }
        "-h"       { $mode = "help" }
        "--help"   { $mode = "help" }
        default    { Stop-WithError "Unknown option: $a (try --help)" }
    }
}

if ($mode -eq "help") {
    Write-Host "freeimage-local Windows Portable Installer (AMD iGPU Edition)"
    Write-Host "  .\install.bat            install engine + portable Python + models"
    Write-Host "  .\install.bat --build    only install Vulkan engine + portable Python"
    Write-Host "  .\install.bat --models   only download / verify models"
    Write-Host "  .\install.bat --q8       download 4.3 GB Q8_0 text encoder instead of 2.5 GB Q4_K_M"
    Write-Host "  .\install.bat --cpu      install CPU-only engine instead of Vulkan"
    exit 0
}

if ($mode -in @("all", "build")) {
    Install-Engine -hw $hw -useCpu $useCpu
}
if ($mode -in @("all", "models")) {
    Install-Models -hw $hw -forceQ8 $forceQ8
}
if ($mode -eq "all") {
    New-DesktopShortcut
    Write-Host ""
    Write-Ok "All set for $($hw.GPUName)!"
    Write-Host "  Double-click start-app.bat (or the 'freeimage local' Desktop shortcut) to open the app." -ForegroundColor Cyan
    Write-Host "  Or from terminal:"
    Write-Host '    .\fi.bat "a red fox in fresh snow, golden hour"'
    Write-Host "    .\fi.bat serve"
    Write-Host "    .\fi.bat doctor"
}
