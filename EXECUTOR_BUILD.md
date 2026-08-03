markdown
# EXECUTOR_BUILD.md – Turning HarnessX into a Live Executor

**This document is provided for educational and research purposes only.**  
It describes modifications to the HarnessX codebase that enable it to function outside the Roblox Studio environment and to intercept remote calls at runtime.

**Important:** Using this modified version of HarnessX against Roblox's Terms of Service may result in account suspension or termination. Only apply these changes to games you own or have explicit permission to test.

---

## Overview

By default, HarnessX is a Studio‑only debugging suite. It uses source‑rewriting and manual proxies to log remote calls. The following steps transform the same codebase into a live client executor that:

- Loads in the Roblox client (not just Studio).
- Automatically hooks `RemoteEvent.FireServer` and `RemoteFunction.InvokeServer` globally.
- Provides memory read/write capabilities via the Flask server.

These changes are isolated to a separate branch or fork, leaving the main branch intact for legitimate Studio debugging.

---

## Prerequisites

- A fork or clone of the HarnessX repository (`https://github.com/n4thyan/HarnessX`).
- Python 3.8+ with the `flask` and `psutil` packages installed.
- Administrator privileges (required for opening process handles with memory access).
- A Roblox client (not Studio) for testing.

---

## Step 1 – Fork or Clone

If you haven't already:

```bash
git clone https://github.com/n4thyan/HarnessX.git
cd HarnessX
Create a new branch for the executor build:

bash
 git checkout -b executor-build
Step 2 – Remove the Studio Guard
Every Luau module in the roblox/ folder contains the following line at the top:

lua
if not game:GetService("RunService"):IsStudio() then return nil end
Delete this line from the following files:

roblox/Core.lua

roblox/UNC.lua

roblox/SUNC.lua

roblox/RemoteProxy.lua

roblox/AutoProxy.lua

roblox/Fuzzer.lua

roblox/Fuzzer.client.lua

After removal, the modules will load in the live client if the attribute HarnessXEnabled is set to true.

Step 3 – Install Global Hooks (roblox/GlobalHooks.lua)
Create a new file roblox/GlobalHooks.lua with the following content:

lua
-- HarnessX GlobalHooks (Live Executor Mode)
-- Overrides engine methods – use at your own risk.

if game:GetAttribute("HarnessXEnabled") ~= true then return nil end

local RemoteProxy = require(script.Parent.RemoteProxy)

local function installGlobalHooks()
    -- Save original methods
    local originalFireServer = RemoteEvent.FireServer
    local originalInvokeServer = RemoteFunction.InvokeServer

    -- Override RemoteEvent.FireServer
    RemoteEvent.FireServer = function(self, ...)
        if self:GetAttribute("HarnessXIgnore") == true then
            return originalFireServer(self, ...)
        end
        local proxy = RemoteProxy.wrap(self)
        return proxy:FireServer(...)
    end

    -- Override RemoteFunction.InvokeServer
    RemoteFunction.InvokeServer = function(self, ...)
        if self:GetAttribute("HarnessXIgnore") == true then
            return originalInvokeServer(self, ...)
        end
        local proxy = RemoteProxy.wrap(self)
        return proxy:InvokeServer(...)
    end

    print("[HarnessX] Global hooks installed – all remote calls intercepted.")
end

return {
    install = installGlobalHooks,
}
Step 4 – Load Global Hooks from Core.lua
In roblox/Core.lua, after the existing initialisation calls, add the following block:

lua
if game:GetAttribute("HarnessXEnabled") == true then
    local GlobalHooks = require(packageFolder:WaitForChild("GlobalHooks"))
    GlobalHooks.install()
end
Place this near the end of the file, after the print("HarnessX runtime ready...") line.

##Step 5 – Enable Memory Read/Write in Python
Replace the entire server/scanner.py file with the code below. This version retains the existing metrics scanner and adds ctypes‑based memory operations.

python
from __future__ import annotations

import ctypes
import ctypes.wintypes
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable, Optional

import psutil

kernel32 = ctypes.windll.kernel32

PROCESS_VM_READ = 0x0010
PROCESS_VM_WRITE = 0x0020
PROCESS_VM_OPERATION = 0x0008


@dataclass(frozen=True)
class ProcessSnapshot:
    timestamp: float
    pid: int
    name: str
    rss_bytes: int
    vms_bytes: int
    cpu_percent: float
    thread_count: int
    handle_count: int | None

    def as_dict(self) -> dict[str, Any]:
        return {
            "timestamp": self.timestamp,
            "pid": self.pid,
            "name": self.name,
            "rssBytes": self.rss_bytes,
            "vmsBytes": self.vms_bytes,
            "cpuPercent": self.cpu_percent,
            "threadCount": self.thread_count,
            "handleCount": self.handle_count,
        }


def find_studio_process(process_names: Iterable[str]) -> psutil.Process | None:
    expected = {name.casefold() for name in process_names}
    matches = []
    for proc in psutil.process_iter(["pid", "name", "create_time"]):
        try:
            name = proc.info.get("name") or ""
            if name.casefold() in expected:
                created = float(proc.info.get("create_time") or 0.0)
                matches.append((created, proc))
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    if not matches:
        return None
    matches.sort(key=lambda item: item[0], reverse=True)
    return matches[0][1]


def take_snapshot(process: psutil.Process) -> ProcessSnapshot:
    with process.oneshot():
        memory = process.memory_info()
        handle_count = None
        num_handles = getattr(process, "num_handles", None)
        if callable(num_handles):
            try:
                handle_count = int(num_handles())
            except (psutil.AccessDenied, psutil.NoSuchProcess, OSError):
                handle_count = None
        return ProcessSnapshot(
            timestamp=time.time(),
            pid=process.pid,
            name=process.name(),
            rss_bytes=int(memory.rss),
            vms_bytes=int(memory.vms),
            cpu_percent=float(process.cpu_percent(interval=None)),
            thread_count=int(process.num_threads()),
            handle_count=handle_count,
        )


class MemoryScanner:
    """
    Background metrics sampler with additional memory read/write capabilities.
    """
    def __init__(
        self,
        *,
        process_names: Iterable[str],
        interval_ms: int,
        on_snapshot: Callable[[ProcessSnapshot], None],
    ):
        self._process_names = tuple(process_names)
        self._interval_seconds = max(interval_ms / 1000.0, 0.05)
        self._on_snapshot = on_snapshot
        self._stop_event = threading.Event()
        self._thread = None
        self._target_pid = None

    def start(self):
        if self._thread and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._run, name="studio-metrics", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop_event.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)

    def _run(self):
        process = None
        while not self._stop_event.wait(self._interval_seconds):
            if process is None or not process.is_running():
                process = find_studio_process(self._process_names)
                if process is None:
                    continue
                try:
                    process.cpu_percent(interval=None)
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    process = None
                    continue
            try:
                snapshot = take_snapshot(process)
                if self._target_pid is None:
                    self._target_pid = process.pid
            except (psutil.NoSuchProcess, psutil.AccessDenied, OSError):
                process = None
                continue
            self._on_snapshot(snapshot)

    def _open_process(self, pid: int, access: int) -> Optional[int]:
        handle = kernel32.OpenProcess(access, False, pid)
        if not handle:
            return None
        return handle

    def read_memory(self, address: int, size: int) -> Optional[bytes]:
        if self._target_pid is None:
            return None
        handle = self._open_process(self._target_pid, PROCESS_VM_READ)
        if not handle:
            return None
        buffer = ctypes.create_string_buffer(size)
        bytes_read = ctypes.c_size_t(0)
        success = kernel32.ReadProcessMemory(handle, address, buffer, size, ctypes.byref(bytes_read))
        kernel32.CloseHandle(handle)
        if success:
            return buffer.raw[:bytes_read.value]
        return None

    def write_memory(self, address: int, data: bytes) -> bool:
        if self._target_pid is None:
            return False
        handle = self._open_process(self._target_pid, PROCESS_VM_WRITE | PROCESS_VM_OPERATION)
        if not handle:
            return False
        bytes_written = ctypes.c_size_t(0)
        success = kernel32.WriteProcessMemory(handle, address, data, len(data), ctypes.byref(bytes_written))
        kernel32.CloseHandle(handle)
        return success and bytes_written.value == len(data)


# Maintain backward compatibility with the existing main.py
StudioMetricsScanner = MemoryScanner
Step 6 – Add Memory Endpoints to Flask (server/main.py)
Open server/main.py and insert the following two routes after the /v1/invoke endpoint, but before the if __name__ == "__main__": block.

python
@app.post("/v1/memory/read")
def memory_read() -> Response | tuple[Response, int]:
    auth_error = require_auth()
    if auth_error is not None:
        return auth_error

    data = request.get_json()
    if not data:
        return jsonify({"ok": False, "error": "Missing JSON body"}), 400

    address = data.get("address")
    size = data.get("size")

    if not isinstance(address, int) or not isinstance(size, int) or size <= 0 or size > 4096:
        return jsonify({"ok": False, "error": "Invalid address or size (max 4096)"}), 400

    result = scanner.read_memory(address, size)
    if result is None:
        return jsonify({"ok": False, "error": "Read failed"}), 500

    return jsonify({
        "ok": True,
        "address": address,
        "size": len(result),
        "data": result.hex()
    })


@app.post("/v1/memory/write")
def memory_write() -> Response | tuple[Response, int]:
    auth_error = require_auth()
    if auth_error is not None:
        return auth_error

    data = request.get_json()
    if not data:
        return jsonify({"ok": False, "error": "Missing JSON body"}), 400

    address = data.get("address")
    hex_data = data.get("data")

    if not isinstance(address, int):
        return jsonify({"ok": False, "error": "Invalid address"}), 400
    if not isinstance(hex_data, str) or len(hex_data) % 2 != 0:
        return jsonify({"ok": False, "error": "Invalid hex data"}), 400

    try:
        bytes_to_write = bytes.fromhex(hex_data)
    except ValueError:
        return jsonify({"ok": False, "error": "Malformed hex string"}), 400

    if len(bytes_to_write) > 4096:
        return jsonify({"ok": False, "error": "Payload too large (max 4096 bytes)"}), 400

    success = scanner.write_memory(address, bytes_to_write)
    if not success:
        return jsonify({"ok": False, "error": "Write failed"}), 500

    return jsonify({
        "ok": True,
        "address": address,
        "written": len(bytes_to_write)
    })
Important: The scanner variable in main.py is already an instance of MemoryScanner – no additional changes are required for these routes to function.

Step 7 – Install Python Dependencies
bash
pip install flask psutil
Step 8 – Run the Server and Test
Start the Flask server (run as Administrator on Windows):

bash
python server\main.py
Launch Roblox and join your test game.

Inject HarnessX using your preferred executor. A minimal injection script is:

lua
game:SetAttribute("HarnessXEnabled", true)
local HarnessX = require(game:GetService("ReplicatedStorage"):WaitForChild("HarnessX"))
local GlobalHooks = require(HarnessX:WaitForChild("GlobalHooks"))
GlobalHooks.install()
Once the hooks are installed, every FireServer and InvokeServer call is intercepted and logged through the Flask server. Use the /v1/memory/read and /v1/memory/write endpoints for process memory operations.

Optional Configuration
If you want to add a "live_mode": true flag in config.json for future UI integration, you may do so, but it is not required for the core functionality.

Important Warnings
This modification may violate Roblox's Terms of Service. Use it only for testing on games that you own or have explicit permission to analyse.

Administrator privileges are required on Windows for OpenProcess to succeed with memory access rights.

Do not use this on public servers or games you do not own – doing so is unethical and may lead to legal consequences.

The main branch of HarnessX remains a legitimate Studio debugging tool; this executor build is intended for a separate branch or fork.

