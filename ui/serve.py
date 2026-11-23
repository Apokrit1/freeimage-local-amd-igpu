"""Tiny local web UI for freeimage-local (with AMD iGPU status, live RAM telemetry, step previews, and CORS/PNA for hosted PWA).
Standard library only.

Started by `start-app.bat` / `fi serve`. Talks to sd-server (stable-diffusion.cpp) and saves every image to outputs/.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
import platform
import random
import re
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).parent
SD_URL = os.environ.get("FI_SD_URL", "http://127.0.0.1:7860")
OUT = Path(os.environ.get("FI_OUT", HERE.parent / "outputs"))
OUT.mkdir(parents=True, exist_ok=True)
GPU = threading.Lock()  # one image at a time; the GPU is the bottleneck anyway
NAME = re.compile(r"^[\w.-]+\.png$")


def get_ram_usage() -> dict:
    """Return total and used system RAM in GB using stdlib only (Windows GlobalMemoryStatusEx / Linux /proc/meminfo)."""
    try:
        if platform.system() == "Windows":
            class MEMORYSTATUSEX(ctypes.Structure):
                _fields_ = [
                    ("dwLength", ctypes.c_ulong),
                    ("dwMemoryLoad", ctypes.c_ulong),
                    ("ullTotalPhys", ctypes.c_ulonglong),
                    ("ullAvailPhys", ctypes.c_ulonglong),
                    ("ullTotalPageFile", ctypes.c_ulonglong),
                    ("ullAvailPageFile", ctypes.c_ulonglong),
                    ("ullTotalVirtual", ctypes.c_ulonglong),
                    ("ullAvailVirtual", ctypes.c_ulonglong),
                    ("sullAvailExtendedVirtual", ctypes.c_ulonglong),
                ]

            stat = MEMORYSTATUSEX()
            stat.dwLength = ctypes.sizeof(MEMORYSTATUSEX)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(stat)):
                total_gb = stat.ullTotalPhys / (1024 ** 3)
                avail_gb = stat.ullAvailPhys / (1024 ** 3)
                used_gb = max(0.0, total_gb - avail_gb)
                return {
                    "total_gb": round(total_gb, 1),
                    "used_gb": round(used_gb, 1),
                    "avail_gb": round(avail_gb, 1),
                    "percent": int(stat.dwMemoryLoad),
                }
        elif Path("/proc/meminfo").is_file():
            info = {}
            for line in Path("/proc/meminfo").read_text().splitlines():
                parts = line.split(":")
                if len(parts) == 2:
                    k = parts[0].strip()
                    v = int(parts[1].strip().split()[0])  # kB
                    info[k] = v
            total_kb = info.get("MemTotal", 0)
            avail_kb = info.get("MemAvailable", info.get("MemFree", 0))
            if total_kb > 0:
                total_gb = total_kb / (1024 ** 2)
                avail_gb = avail_kb / (1024 ** 2)
                used_gb = max(0.0, total_gb - avail_gb)
                return {
                    "total_gb": round(total_gb, 1),
                    "used_gb": round(used_gb, 1),
                    "avail_gb": round(avail_gb, 1),
                    "percent": int(round((used_gb / total_gb) * 100)),
                }
    except Exception:
        pass
    fallback_total = float(os.environ.get("FI_RAM_GB", "16.0") or 16.0)
    return {"total_gb": fallback_total, "used_gb": 0.0, "avail_gb": fallback_total, "percent": 0}


def get_status() -> dict:
    is_igpu = os.environ.get("FI_IS_IGPU", "1") == "1"
    return {
        "device": os.environ.get("FI_DEVICE", "AMD Radeon Graphics (Vulkan · 16 GB Unified RAM)"),
        "gpu_name": os.environ.get("FI_GPU_NAME", "AMD Radeon Graphics"),
        "cpu_name": os.environ.get("FI_CPU_NAME", ""),
        "platform": os.environ.get("FI_PLATFORM", "vulkan"),
        "is_igpu": is_igpu,
        "llm_name": os.environ.get("FI_LLM_NAME", "Qwen3-4B-Q4_K_M.gguf" if is_igpu else "Qwen3-4B-Q8_0.gguf"),
        "ram": get_ram_usage(),
        "busy": GPU.locked(),
    }


def get_progress() -> dict:
    try:
        r = urllib.request.urlopen(f"{SD_URL}/sdapi/v1/progress", timeout=2)
        data = json.loads(r.read())
        state = data.get("state") or {}
        step = int(state.get("sampling_step") or 0)
        total = int(state.get("sampling_steps") or 0)
        prog = float(data.get("progress") or 0.0)
        img_b64 = data.get("current_image")
        return {
            "active": GPU.locked(),
            "step": step,
            "total_steps": total,
            "progress": round(prog, 3),
            "preview": f"data:image/jpeg;base64,{img_b64}" if img_b64 else None,
            "ram": get_ram_usage(),
        }
    except Exception:
        return {
            "active": GPU.locked(),
            "step": 0,
            "total_steps": 0,
            "progress": 0.0,
            "preview": None,
            "ram": get_ram_usage(),
        }


def generate(body: dict) -> dict:
    prompt = str(body.get("prompt", "")).strip()[:2000]
    if not prompt:
        raise ValueError("Write a prompt first.")
    w, h = int(body.get("width", 768)), int(body.get("height", 768))
    if not (256 <= w <= 2048 and 256 <= h <= 2048 and w % 64 == 0 and h % 64 == 0):
        raise ValueError("Width and height must be multiples of 64 between 256 and 2048.")
    steps = max(1, min(int(body.get("steps", 6)), 30))
    seed = body.get("seed")
    seed = int(seed) if str(seed or "").isdigit() else random.randint(0, 2**31 - 1)
    req = json.dumps({"prompt": prompt, "width": w, "height": h, "steps": steps,
                      "cfg_scale": 1.0, "seed": seed}).encode()
    with GPU:
        t0 = time.time()
        r = urllib.request.urlopen(urllib.request.Request(
            f"{SD_URL}/sdapi/v1/txt2img", req, {"content-type": "application/json"}), timeout=1200)
        png = base64.b64decode(json.loads(r.read())["images"][0])
        secs = time.time() - t0
    name = f"{time.strftime('%Y%m%d-%H%M%S')}-{seed}.png"
    (OUT / name).write_bytes(png)
    (OUT / (name + ".json")).write_text(json.dumps(
        {"prompt": prompt, "width": w, "height": h, "steps": steps, "seed": seed, "seconds": round(secs, 1)}))
    return {"url": f"/outputs/{name}", "name": name, "seed": seed, "seconds": round(secs, 1),
            "width": w, "height": h, "prompt": prompt}


def history(limit: int = 60) -> list[dict]:
    items = []
    for p in sorted(OUT.glob("*.png"), reverse=True)[:limit]:
        meta = {}
        try:
            meta = json.loads((OUT / (p.name + ".json")).read_text())
        except (OSError, ValueError):
            pass
        items.append({"url": f"/outputs/{p.name}", "name": p.name, **meta})
    return items


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def send_cors_headers(self):
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-allow-methods", "GET, POST, OPTIONS")
        self.send_header("access-control-allow-headers", "Content-Type")
        self.send_header("access-control-allow-private-network", "true")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_cors_headers()
        self.send_header("content-length", "0")
        self.end_headers()

    def send(self, code: int, body: bytes, ctype: str, extra: dict | None = None):
        self.send_response(code)
        self.send_cors_headers()
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.send_header("cache-control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def json(self, code: int, obj):
        self.send(code, json.dumps(obj).encode(), "application/json")

    STATIC_PWA = {
        "/manifest.webmanifest": ("manifest.webmanifest", "application/manifest+json; charset=utf-8"),
        "/sw.js": ("sw.js", "application/javascript; charset=utf-8"),
        "/icon.svg": ("icon.svg", "image/svg+xml"),
        "/icon-192.png": ("icon-192.png", "image/png"),
        "/icon-512.png": ("icon-512.png", "image/png"),
    }

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self.send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        if path in self.STATIC_PWA:
            fname, ctype = self.STATIC_PWA[path]
            fpath = HERE / fname
            if fpath.is_file():
                extra = {"service-worker-allowed": "/"} if path == "/sw.js" else None
                return self.send(200, fpath.read_bytes(), ctype, extra)
        if path == "/api/status":
            return self.json(200, get_status())
        if path == "/api/progress":
            return self.json(200, get_progress())
        if path == "/api/history":
            return self.json(200, history())
        if path.startswith("/outputs/") and NAME.match(path[9:]) and (OUT / path[9:]).is_file():
            extra = {"content-disposition": f'attachment; filename="{path[9:]}"'} if "dl=1" in self.path else None
            return self.send(200, (OUT / path[9:]).read_bytes(), "image/png", extra)
        self.send(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path != "/api/generate":
            return self.send(404, b"not found", "text/plain")
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("content-length", 0)) or 0) or b"{}")
            self.json(200, generate(body))
        except ValueError as e:
            self.json(400, {"error": str(e)})
        except Exception as e:  # engine down, timeout…
            self.json(502, {"error": f"Engine error: {e}"})


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7861)
    ap.add_argument("--host", default="127.0.0.1")
    a = ap.parse_args()
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
