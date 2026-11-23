# Troubleshooting

Start with `./fi doctor`. It shows what was detected and which flags the engine gets.

**`missing 'cmake'` / `missing 'nvcc'`**
Install the build tools listed in the README. On NVIDIA, `nvcc` comes with the CUDA toolkit, not with the driver.

**`RTX 50-series (sm_120) needs CUDA 12.8 or newer`**
Update the CUDA toolkit. The driver alone isn't enough.

**CUDA build fails with "unsupported GNU version"**
Your gcc is newer than your CUDA release supports. Install an older one (for example `sudo apt install g++-13`).
The installer picks the newest `g++-14/13/12` it finds automatically.

**A download stopped halfway**
Run `./install.sh --models` again. Downloads resume where they left off and are checked against SHA-256.

**Out of memory on NVIDIA**
Force weight offloading: `FI_OFFLOAD=1 ./fi serve`. It's already on automatically for cards under 12 GB.

**AMD Ryzen iGPU on Windows (e.g. Acer Aspire Lite 15 Ryzen 7 5825U / Vega 8 / 16 GB RAM)**
- Run `fi.bat doctor` to verify that Vulkan detects your `AMD Radeon(TM) Graphics` device and that `Qwen3-4B-Q4_K_M.gguf` is selected.
- **Keep BIOS UMA Frame Buffer at Auto / 512 MB – 2 GB:** On a 16 GB laptop, do **not** lock 4 GB or 8 GB as fixed UMA VRAM in BIOS — Windows and Vulkan dynamically share up to 8 GB of system RAM with the Vega 8 iGPU automatically, while locking 8 GB starves the CPU of RAM needed for `--offload-to-cpu`.
- **If Windows RAM is tight (many browser tabs open):** Lower the active Vulkan graph-cut budget to 2 GiB before launching:
  ```bat
  set FI_MAX_VRAM=2
  start-app.bat
  ```
  Or run the text encoder strictly on the 8-core Zen 3 CPU:
  ```bat
  set FI_TE_CPU=1
  start-app.bat
  ```
- **Update AMD Adrenalin Driver:** If `fi.bat doctor` shows no Vulkan device, install the latest AMD Software: Adrenalin Edition driver for Ryzen 5000 series from amd.com.

**It's slower than the numbers in the README**
- Make sure you're timing `start-app.bat`, `fi serve`, or `fi bench`, not single `fi "…"` runs, which include loading the model.
- On an AMD Vega 8 iGPU, use the **768p iGPU** or **512p Draft** tier with **Fast (6 steps)** in the UI for 2–4× faster generation than 1024p.
- Laptop? Plug into AC power (Windows throttles the Ryzen 7 5825U 15W APU heavily on battery) and elevate the back of the laptop for airflow.
- Close other apps that use the GPU (browsers with many tabs, games).

**Port already in use**
`FI_SD_PORT=7870 FI_UI_PORT=7871 ./fi serve` (or on Windows: `set FI_SD_PORT=7870 && set FI_UI_PORT=7871 && start-app.bat`)

**Logs**
`.fi/build.log` (build), `.fi/server.log` (engine), `.fi/last.log` (last single image).
