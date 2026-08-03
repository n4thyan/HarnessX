from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Any, Callable, Iterable

import psutil


@dataclass(frozen=True)
class ProcessSnapshot:
    """Read-only process-level metrics for a Roblox Studio process."""

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
    """Find the newest matching Roblox Studio process without opening memory."""

    expected = {name.casefold() for name in process_names}
    matches: list[tuple[float, psutil.Process]] = []

    for process in psutil.process_iter(["pid", "name", "create_time"]):
        try:
            name = process.info.get("name") or ""
            if name.casefold() in expected:
                created = float(process.info.get("create_time") or 0.0)
                matches.append((created, process))
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    if not matches:
        return None

    matches.sort(key=lambda item: item[0], reverse=True)
    return matches[0][1]


def take_snapshot(process: psutil.Process) -> ProcessSnapshot:
    """
    Collect read-only operating-system metrics.

    This intentionally does NOT use ctypes, OpenProcess, ReadProcessMemory,
    WriteProcessMemory, DLL injection, handles with VM_READ rights, or address
    space traversal. It cannot inspect Luau heap objects or arbitrary bytes.
    """

    with process.oneshot():
        memory = process.memory_info()
        handle_count: int | None = None

        # num_handles is Windows-specific and may be unavailable or denied.
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


class StudioMetricsScanner:
    """Background read-only process metrics sampler."""

    def __init__(
        self,
        *,
        process_names: Iterable[str],
        interval_ms: int,
        on_snapshot: Callable[[ProcessSnapshot], None],
    ) -> None:
        self._process_names = tuple(process_names)
        self._interval_seconds = max(interval_ms / 1000.0, 0.05)
        self._interval_lock = threading.Lock()
        self._on_snapshot = on_snapshot
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return

        self._thread = threading.Thread(
            target=self._run,
            name="studio-process-metrics",
            daemon=True,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)

    def set_interval_ms(self, interval_ms: int) -> None:
        """Update the sampling interval without restarting the scanner thread."""
        with self._interval_lock:
            self._interval_seconds = max(interval_ms / 1000.0, 0.05)

    def _run(self) -> None:
        process: psutil.Process | None = None

        while True:
            with self._interval_lock:
                interval_seconds = self._interval_seconds

            if self._stop_event.wait(interval_seconds):
                break

            if process is None or not process.is_running():
                process = find_studio_process(self._process_names)
                if process is None:
                    continue

                # Prime psutil's non-blocking CPU percentage measurement.
                try:
                    process.cpu_percent(interval=None)
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    process = None
                    continue

            try:
                snapshot = take_snapshot(process)
            except (psutil.NoSuchProcess, psutil.AccessDenied, OSError):
                process = None
                continue

            self._on_snapshot(snapshot)
