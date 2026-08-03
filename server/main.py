from __future__ import annotations

import atexit
import hmac
import json
import logging
import re
import shutil
import time
import uuid
from collections import deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from threading import Condition, Lock
from typing import Any, Iterable

from flask import Flask, Response, jsonify, request, stream_with_context

from encoder import EncoderError, decode
from scanner import ProcessSnapshot, StudioMetricsScanner

PROJECT_ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = PROJECT_ROOT / "config.json"
LOOPBACK_HOST = "127.0.0.1"
TRAFFIC_CAPACITY = 1000
STREAM_BATCH_LIMIT = 100
MAX_FUZZ_DURATION_SECONDS = 3600


def load_config() -> dict[str, Any]:
    with CONFIG_PATH.open("r", encoding="utf-8") as handle:
        config = json.load(handle)

    bridge = config.get("bridge")
    profiles = config.get("profiles")
    active_profile = config.get("active_profile")
    plugin_config = config.get("plugin")
    fuzzer_config = config.get("fuzzer")
    backup_config = config.get("backup")
    profiling_config = config.get("profiling")

    if not isinstance(bridge, dict):
        raise ValueError("config.bridge must be an object")

    if bridge.get("host") != LOOPBACK_HOST:
        raise ValueError("bridge.host must be exactly 127.0.0.1")

    if not isinstance(bridge.get("token"), str) or len(bridge["token"]) < 16:
        raise ValueError("bridge.token must contain at least 16 characters")

    if not isinstance(profiles, dict) or active_profile not in profiles:
        raise ValueError("active_profile must reference a configured profile")

    for profile_name, profile in profiles.items():
        if not isinstance(profile, dict):
            raise ValueError(f"profiles.{profile_name} must be an object")

        for field in ("scan_interval_ms", "batch_size", "encoder_rounds"):
            if not isinstance(profile.get(field), int) or profile[field] < 1:
                raise ValueError(
                    f"profiles.{profile_name}.{field} must be a positive integer"
                )

        if not 1 <= profile["encoder_rounds"] <= 16:
            raise ValueError(
                f"profiles.{profile_name}.encoder_rounds must be 1..16"
            )

    if not isinstance(plugin_config, dict):
        raise ValueError("config.plugin must be an object")

    if not isinstance(fuzzer_config, dict):
        raise ValueError("config.fuzzer must be an object")

    if not isinstance(fuzzer_config.get("default_rate"), int):
        raise ValueError("fuzzer.default_rate must be an integer")

    if not isinstance(fuzzer_config.get("max_rate"), int):
        raise ValueError("fuzzer.max_rate must be an integer")

    if not isinstance(fuzzer_config.get("default_duration_seconds"), int):
        raise ValueError("fuzzer.default_duration_seconds must be an integer")

    if not 1 <= fuzzer_config["default_rate"] <= fuzzer_config["max_rate"]:
        raise ValueError("fuzzer.default_rate must be within the configured cap")

    if not isinstance(backup_config, dict):
        raise ValueError("config.backup must be an object")

    output_dir = backup_config.get("output_dir")
    if not isinstance(output_dir, str) or not output_dir.strip():
        raise ValueError("backup.output_dir must be a non-empty string")

    output_path = Path(output_dir)
    if output_path.is_absolute() or ".." in output_path.parts:
        raise ValueError("backup.output_dir must be a safe relative path")

    if not isinstance(backup_config.get("max_backups"), int):
        raise ValueError("backup.max_backups must be an integer")

    if not isinstance(profiling_config, dict):
        raise ValueError("config.profiling must be an object")

    if not isinstance(profiling_config.get("enabled"), bool):
        raise ValueError("profiling.enabled must be a boolean")

    if not isinstance(profiling_config.get("window_seconds"), int):
        raise ValueError("profiling.window_seconds must be an integer")

    return config


CONFIG = load_config()
BRIDGE = CONFIG["bridge"]
PROFILES: dict[str, dict[str, Any]] = CONFIG["profiles"]
TOKEN = BRIDGE["token"]
MAX_BODY_BYTES = int(BRIDGE.get("max_body_bytes", 8_388_608))
FUZZER_CONFIG: dict[str, Any] = CONFIG["fuzzer"]
BACKUP_CONFIG: dict[str, Any] = CONFIG["backup"]
PROFILING_CONFIG: dict[str, Any] = CONFIG["profiling"]

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_BODY_BYTES

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("harnessx")


@dataclass
class RuntimeConfig:
    active_profile: str
    sunc_mode: str
    mock_returns: list[Any]


runtime_lock = Lock()
runtime_config = RuntimeConfig(
    active_profile=str(CONFIG["active_profile"]),
    sunc_mode=str(CONFIG.get("sunc", {}).get("mode", "observe")).lower(),
    mock_returns=list(CONFIG.get("sunc", {}).get("mock_returns", [])),
)

latest_snapshot: dict[str, Any] | None = None
snapshot_lock = Lock()
sample_count = 0

diagnostics_lock = Lock()
latest_diagnostics: dict[str, dict[str, Any] | None] = {
    "instance_counts": None,
    "gc_stats": None,
    "connection_counts": None,
}

latest_profiling: dict[str, Any] | None = None
profiling_lock = Lock()

latest_runtime_status: dict[str, Any] | None = None
runtime_status_lock = Lock()

latest_stackdump: dict[str, Any] | None = None
stackdump_lock = Lock()

control_lock = Lock()
diagnostic_trigger_id = 0
stack_request: dict[str, Any] = {"id": 0, "target": None}

fuzz_lock = Lock()
fuzz_sessions: dict[str, dict[str, Any]] = {}


class EventBus:
    def __init__(self, capacity: int) -> None:
        self._events: deque[dict[str, Any]] = deque(maxlen=capacity)
        self._condition = Condition()
        self._sequence = 0

    def publish(self, event_type: str, payload: Any) -> dict[str, Any]:
        with self._condition:
            self._sequence += 1
            envelope = {
                "seq": self._sequence,
                "type": event_type,
                "at": int(time.time() * 1000),
                "payload": payload,
            }
            self._events.append(envelope)
            self._condition.notify_all()
            return envelope

    def after(self, sequence: int, limit: int) -> list[dict[str, Any]]:
        with self._condition:
            return [
                event
                for event in self._events
                if int(event["seq"]) > sequence
            ][:limit]

    def wait_after(
        self,
        sequence: int,
        timeout: float,
        limit: int,
    ) -> list[dict[str, Any]]:
        with self._condition:
            events = [
                event
                for event in self._events
                if int(event["seq"]) > sequence
            ][:limit]

            if events:
                return events

            self._condition.wait(timeout=timeout)

            return [
                event
                for event in self._events
                if int(event["seq"]) > sequence
            ][:limit]

    def size(self) -> int:
        with self._condition:
            return len(self._events)

    def sequence(self) -> int:
        with self._condition:
            return self._sequence


event_bus = EventBus(TRAFFIC_CAPACITY)


def authorized() -> bool:
    supplied = request.headers.get("X-Debug-Token", "")
    return hmac.compare_digest(supplied, TOKEN)


@app.before_request
def authenticate_v1_routes() -> Response | tuple[Response, int] | None:
    if request.path.startswith("/v1/") and not authorized():
        return jsonify({"ok": False, "error": "unauthorized"}), 401
    return None


def decode_request() -> Any:
    body = request.get_data(cache=False, as_text=True)
    if not body:
        raise EncoderError("Request body is empty")
    return decode(body)


def extract_payload(message: Any, expected_kind: str) -> Any:
    if not isinstance(message, dict):
        raise EncoderError("Decoded message must be an object")

    if message.get("kind") != expected_kind:
        raise EncoderError(
            f"Expected kind {expected_kind!r}, received {message.get('kind')!r}"
        )

    if "payload" not in message:
        raise EncoderError("Decoded message has no payload")

    return message["payload"]


def numeric_table_values(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value

    if isinstance(value, dict):
        numeric_items: list[tuple[int, Any]] = []

        for key, item in value.items():
            try:
                numeric_key = int(key)
            except (TypeError, ValueError):
                continue

            numeric_items.append((numeric_key, item))

        numeric_items.sort(key=lambda pair: pair[0])
        return [item for _, item in numeric_items]

    return []


def current_runtime() -> tuple[str, dict[str, Any], str, list[Any]]:
    with runtime_lock:
        profile_name = runtime_config.active_profile
        return (
            profile_name,
            dict(PROFILES[profile_name]),
            runtime_config.sunc_mode,
            list(runtime_config.mock_returns),
        )


def on_snapshot(snapshot: ProcessSnapshot) -> None:
    global latest_snapshot, sample_count

    value = snapshot.as_dict()

    with snapshot_lock:
        latest_snapshot = value
        sample_count += 1
        current_count = sample_count

    print_every = max(
        int(CONFIG.get("scanner", {}).get("print_every_samples", 10)),
        1,
    )

    if current_count % print_every == 0:
        logger.info(
            "Studio metrics pid=%s rss=%.1fMiB vms=%.1fMiB "
            "cpu=%.1f%% threads=%s handles=%s",
            value["pid"],
            value["rssBytes"] / (1024 * 1024),
            value["vmsBytes"] / (1024 * 1024),
            value["cpuPercent"],
            value["threadCount"],
            value["handleCount"],
        )


scanner: StudioMetricsScanner | None = None
scanner_config = CONFIG.get("scanner", {})

if scanner_config.get("enabled", True):
    initial_profile = PROFILES[str(CONFIG["active_profile"])]

    scanner = StudioMetricsScanner(
        process_names=scanner_config.get(
            "process_names",
            [
                "RobloxStudioBeta.exe",
                "RobloxStudio.exe",
                "RobloxStudio",
            ],
        ),
        interval_ms=int(initial_profile["scan_interval_ms"]),
        on_snapshot=on_snapshot,
    )
    scanner.start()
    atexit.register(scanner.stop)


def store_diagnostic(name: str, payload: Any) -> dict[str, Any]:
    record = {
        "receivedAt": int(time.time() * 1000),
        "payload": payload,
    }

    with diagnostics_lock:
        latest_diagnostics[name] = record

    event_bus.publish("diagnostic", {"name": name, "record": record})
    return record


def latest_diagnostic_timestamp() -> int | None:
    with diagnostics_lock:
        timestamps = [
            int(record["receivedAt"])
            for record in latest_diagnostics.values()
            if record is not None
        ]

    return max(timestamps) if timestamps else None


def refresh_fuzz_session(session: dict[str, Any]) -> None:
    now = time.time()

    if session["status"] == "running":
        ends_at = session.get("endsAt")
        if isinstance(ends_at, (int, float)) and now >= float(ends_at):
            session["status"] = "completed"
            session["finishedAt"] = now

    if session["status"] == "queued":
        expires_at = session.get("queueExpiresAt")
        if isinstance(expires_at, (int, float)) and now >= float(expires_at):
            session["status"] = "expired"
            session["finishedAt"] = now


def public_fuzz_session(session: dict[str, Any]) -> dict[str, Any]:
    refresh_fuzz_session(session)
    latency_count = int(session.get("latencyCount", 0))
    average_latency = (
        float(session.get("totalLatencyMs", 0.0)) / latency_count
        if latency_count > 0
        else 0.0
    )

    return {
        "id": session["id"],
        "status": session["status"],
        "target": session["target"],
        "targetSegments": list(session["targetSegments"]),
        "targetClass": session["targetClass"],
        "argTypes": session["argTypes"],
        "rate": session["rate"],
        "duration": session["duration"],
        "createdAt": session["createdAt"],
        "startedAt": session.get("startedAt"),
        "endsAt": session.get("endsAt"),
        "finishedAt": session.get("finishedAt"),
        "assignedClient": session.get("assignedClient"),
        "calls": int(session.get("calls", 0)),
        "errors": int(session.get("errors", 0)),
        "averageLatencyMs": average_latency,
        "lastLatencyMs": session.get("lastLatencyMs"),
        "lastError": session.get("lastError"),
    }


def safe_backup_segment(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._ -]+", "_", value).strip(" .")
    return cleaned[:120] or "unnamed"


def backup_root() -> Path:
    relative = Path(str(BACKUP_CONFIG["output_dir"]))
    output = (PROJECT_ROOT / relative).resolve()
    project = PROJECT_ROOT.resolve()

    if output != project and project not in output.parents:
        raise ValueError("Backup output resolved outside the project root")

    return output


def prune_old_backups(root: Path) -> None:
    max_backups = max(int(BACKUP_CONFIG["max_backups"]), 1)
    folders = sorted(
        [path for path in root.iterdir() if path.is_dir()],
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )

    for old_folder in folders[max_backups:]:
        shutil.rmtree(old_folder, ignore_errors=True)


@app.get("/v1/health")
def health() -> Response:
    profile_name, _, mode, _ = current_runtime()

    return jsonify(
        {
            "ok": True,
            "service": "harnessx",
            "loopbackOnly": True,
            "activeProfile": profile_name,
            "suncMode": mode,
        }
    )


@app.get("/v1/config")
def public_config() -> Response:
    profile_name, profile, mode, _ = current_runtime()

    return jsonify(
        {
            "ok": True,
            "active_profile": profile_name,
            "profile": profile,
            "sunc_mode": mode,
            "plugin": CONFIG["plugin"],
            "fuzzer": FUZZER_CONFIG,
            "backup": BACKUP_CONFIG,
            "profiling": PROFILING_CONFIG,
        }
    )


@app.post("/v1/config/update")
def update_config() -> Response | tuple[Response, int]:
    body = request.get_json(silent=True)

    if not isinstance(body, dict):
        return jsonify({"ok": False, "error": "JSON object required"}), 400

    changes: dict[str, Any] = {}

    with runtime_lock:
        if "sunc_mode" in body:
            mode = str(body["sunc_mode"]).lower()
            if mode not in {"observe", "mock", "fuzz"}:
                return (
                    jsonify(
                        {
                            "ok": False,
                            "error": "sunc_mode must be observe, mock, or fuzz",
                        }
                    ),
                    400,
                )

            runtime_config.sunc_mode = mode
            changes["sunc_mode"] = mode

        if "mock_returns" in body:
            mock_returns = body["mock_returns"]
            if not isinstance(mock_returns, list):
                return (
                    jsonify(
                        {
                            "ok": False,
                            "error": "mock_returns must be a JSON array",
                        }
                    ),
                    400,
                )

            runtime_config.mock_returns = mock_returns
            changes["mock_returns"] = mock_returns

        if "active_profile" in body:
            profile_name = str(body["active_profile"]).lower()
            if profile_name not in PROFILES:
                return (
                    jsonify(
                        {
                            "ok": False,
                            "error": "unknown active_profile",
                            "allowed": sorted(PROFILES),
                        }
                    ),
                    400,
                )

            runtime_config.active_profile = profile_name
            changes["active_profile"] = profile_name

    profile_name, profile, mode, mock_returns = current_runtime()

    event_bus.publish(
        "config",
        {
            "changes": changes,
            "activeProfile": profile_name,
            "profile": profile,
            "suncMode": mode,
            "mockReturns": mock_returns,
        },
    )

    return jsonify(
        {
            "ok": True,
            "changes": changes,
            "activeProfile": profile_name,
            "profile": profile,
            "suncMode": mode,
            "mockReturns": mock_returns,
        }
    )


@app.get("/v1/status")
def status() -> Response:
    profile_name, profile, mode, _ = current_runtime()

    with runtime_status_lock:
        runtime_status = (
            dict(latest_runtime_status)
            if latest_runtime_status is not None
            else None
        )

    with control_lock:
        trigger_id = diagnostic_trigger_id
        current_stack_request = dict(stack_request)

    pending_queue_size = 0
    if isinstance(runtime_status, dict):
        payload = runtime_status.get("payload")
        if isinstance(payload, dict):
            pending_queue_size = int(payload.get("pendingQueueSize", 0))

    with fuzz_lock:
        active_fuzz = sum(
            1
            for session in fuzz_sessions.values()
            if public_fuzz_session(session)["status"] in {"queued", "running"}
        )

    return jsonify(
        {
            "ok": True,
            "activeProfile": profile_name,
            "profile": profile,
            "suncMode": mode,
            "profiling": PROFILING_CONFIG,
            "pendingQueueSize": pending_queue_size,
            "trafficBufferSize": event_bus.size(),
            "latestSequence": event_bus.sequence(),
            "lastDiagnosticsTimestamp": latest_diagnostic_timestamp(),
            "diagnosticTriggerId": trigger_id,
            "stackRequest": current_stack_request,
            "runtimeStatus": runtime_status,
            "activeFuzzSessions": active_fuzz,
        }
    )


@app.get("/v1/metrics")
def metrics() -> Response:
    with snapshot_lock:
        snapshot = (
            dict(latest_snapshot)
            if latest_snapshot is not None
            else None
        )

    return jsonify({"ok": True, "snapshot": snapshot})


@app.get("/v1/diagnostics")
def diagnostics() -> Response:
    with diagnostics_lock:
        snapshot = {
            key: dict(value) if value is not None else None
            for key, value in latest_diagnostics.items()
        }

    return jsonify({"ok": True, "diagnostics": snapshot})


@app.post("/v1/diagnostics/trigger")
def trigger_diagnostics() -> Response:
    global diagnostic_trigger_id

    with control_lock:
        diagnostic_trigger_id += 1
        trigger_id = diagnostic_trigger_id

    event_bus.publish("status", {"diagnosticTriggerId": trigger_id})

    return jsonify({"ok": True, "diagnosticTriggerId": trigger_id})


@app.post("/v1/runtime/status")
def runtime_status_update() -> Response | tuple[Response, int]:
    global latest_runtime_status

    try:
        message = decode_request()
        payload = extract_payload(message, "runtime_status")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    record = {
        "receivedAt": int(time.time() * 1000),
        "payload": payload,
    }

    with runtime_status_lock:
        latest_runtime_status = record

    return jsonify({"ok": True})


@app.post("/v1/ingest")
def ingest() -> Response | tuple[Response, int]:
    try:
        message = decode_request()
        payload = extract_payload(message, "remote_batch")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    records: Iterable[Any] = []
    if isinstance(payload, dict):
        records = numeric_table_values(payload.get("records"))

    accepted = 0
    for record in records:
        accepted += 1
        event_bus.publish("traffic", {"record": record, "source": "batch"})

    logger.info(
        "REMOTE TRACE BATCH accepted=%s\n%s",
        accepted,
        json.dumps(message, indent=2, ensure_ascii=False),
    )

    return jsonify({"ok": True, "accepted": accepted})


@app.post("/v1/invoke")
def invoke() -> Response | tuple[Response, int]:
    try:
        message = decode_request()
        payload = extract_payload(message, "sunc_preflight")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    event_bus.publish(
        "traffic",
        {"record": payload, "source": "preflight"},
    )

    logger.info(
        "REMOTE FUNCTION PREFLIGHT\n%s",
        json.dumps(message, indent=2, ensure_ascii=False),
    )

    _, _, mode, mock_returns = current_runtime()

    return jsonify(
        {
            "ok": True,
            "mode": mode,
            "mockReturns": mock_returns,
        }
    )


@app.get("/v1/traffic")
def traffic() -> Response | tuple[Response, int]:
    try:
        after = max(int(request.args.get("after", "0")), 0)
        limit = min(
            max(int(request.args.get("limit", "50")), 1),
            STREAM_BATCH_LIMIT,
        )
    except ValueError:
        return jsonify({"ok": False, "error": "invalid query"}), 400

    return jsonify(
        {
            "ok": True,
            "events": event_bus.after(after, limit),
            "latestSequence": event_bus.sequence(),
        }
    )


@app.get("/v1/stream")
def stream() -> Response:
    try:
        after = max(int(request.args.get("after", "0")), 0)
    except ValueError:
        after = 0

    @stream_with_context
    def generate():
        sequence = after
        yield "retry: 2000\n\n"

        while True:
            events = event_bus.wait_after(
                sequence,
                timeout=15.0,
                limit=STREAM_BATCH_LIMIT,
            )

            if not events:
                yield ": keepalive\n\n"
                continue

            for envelope in events:
                sequence = int(envelope["seq"])
                payload = json.dumps(
                    envelope,
                    ensure_ascii=False,
                    separators=(",", ":"),
                )

                yield (
                    f"id: {sequence}\n"
                    f"event: {envelope['type']}\n"
                    f"data: {payload}\n\n"
                )

    return Response(
        generate(),
        mimetype="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.post("/v1/instance_counts")
def instance_counts() -> Response | tuple[Response, int]:
    try:
        message = decode_request()
        payload = extract_payload(message, "instance_counts")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    record = store_diagnostic("instance_counts", payload)
    return jsonify({"ok": True, "instanceCounts": record})


@app.post("/v1/gc_stats")
def gc_stats() -> Response | tuple[Response, int]:
    try:
        message = decode_request()
        payload = extract_payload(message, "gc_stats")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    record = store_diagnostic("gc_stats", payload)
    return jsonify({"ok": True, "gcStats": record})


@app.post("/v1/connection_counts")
def connection_counts() -> Response | tuple[Response, int]:
    try:
        message = decode_request()
        payload = extract_payload(message, "connection_counts")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    record = store_diagnostic("connection_counts", payload)
    return jsonify({"ok": True, "connectionCounts": record})


@app.post("/v1/profiling/sunc")
def profiling_sunc_update() -> Response | tuple[Response, int]:
    global latest_profiling

    try:
        message = decode_request()
        payload = extract_payload(message, "profiling_sunc")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    record = {
        "receivedAt": int(time.time() * 1000),
        "payload": payload,
    }

    with profiling_lock:
        latest_profiling = record

    event_bus.publish("profiling", record)
    return jsonify({"ok": True, "profiling": record})


@app.get("/v1/profiling/sunc")
def profiling_sunc_get() -> Response:
    with profiling_lock:
        record = (
            dict(latest_profiling)
            if latest_profiling is not None
            else None
        )

    return jsonify(
        {
            "ok": True,
            "profiling": record,
            "config": PROFILING_CONFIG,
        }
    )


@app.post("/v1/stackdump/request")
def request_stackdump() -> Response | tuple[Response, int]:
    body = request.get_json(silent=True)

    if not isinstance(body, dict):
        return jsonify({"ok": False, "error": "JSON object required"}), 400

    target = body.get("target")
    if not isinstance(target, str) or not target.strip():
        return jsonify({"ok": False, "error": "target string required"}), 400

    with control_lock:
        stack_request["id"] = int(stack_request["id"]) + 1
        stack_request["target"] = target
        request_copy = dict(stack_request)

    event_bus.publish("status", {"stackRequest": request_copy})
    return jsonify({"ok": True, "stackRequest": request_copy})


@app.post("/v1/stackdump")
def stackdump() -> Response | tuple[Response, int]:
    global latest_stackdump

    try:
        message = decode_request()
        payload = extract_payload(message, "stackdump")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    record = {
        "receivedAt": int(time.time() * 1000),
        "payload": payload,
    }

    with stackdump_lock:
        latest_stackdump = record

    logger.info(
        "STACK DUMP\n%s",
        json.dumps(record, indent=2, ensure_ascii=False),
    )

    event_bus.publish("stackdump", record)
    return jsonify({"ok": True, "stackdump": record})


@app.get("/v1/stackdump/latest")
def stackdump_latest() -> Response:
    with stackdump_lock:
        record = (
            dict(latest_stackdump)
            if latest_stackdump is not None
            else None
        )

    return jsonify({"ok": True, "stackdump": record})


@app.post("/v1/backup/sources")
def backup_sources() -> Response | tuple[Response, int]:
    body = request.get_json(silent=True)

    if not isinstance(body, dict):
        return jsonify({"ok": False, "error": "JSON object required"}), 400

    sources = body.get("sources", body)
    if not isinstance(sources, dict):
        return jsonify({"ok": False, "error": "sources mapping required"}), 400

    if len(sources) > 5000:
        return jsonify({"ok": False, "error": "too many source files"}), 400

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    folder_name = f"{timestamp}-{uuid.uuid4().hex[:8]}"

    try:
        root = backup_root()
        root.mkdir(parents=True, exist_ok=True)
        destination = root / folder_name
        destination.mkdir(parents=False, exist_ok=False)
    except (OSError, ValueError) as exc:
        return jsonify({"ok": False, "error": str(exc)}), 500

    written: list[str] = []

    try:
        for script_path, source in sources.items():
            if not isinstance(script_path, str) or not isinstance(source, str):
                raise ValueError("Every backup entry must map a string path to source text")

            parts = [
                safe_backup_segment(part)
                for part in script_path.split(".")
                if part.strip()
            ]

            if not parts:
                parts = ["unnamed"]

            relative = Path(*parts).with_suffix(".lua")
            output = destination / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(source, encoding="utf-8", newline="\n")
            written.append(str(relative).replace("\\", "/"))

        manifest = {
            "createdAt": timestamp,
            "sourceCount": len(written),
            "files": written,
        }
        (destination / "manifest.json").write_text(
            json.dumps(manifest, indent=2),
            encoding="utf-8",
            newline="\n",
        )

        prune_old_backups(root)
    except (OSError, ValueError) as exc:
        shutil.rmtree(destination, ignore_errors=True)
        return jsonify({"ok": False, "error": str(exc)}), 400

    relative_folder = destination.relative_to(PROJECT_ROOT)

    event_bus.publish(
        "backup",
        {
            "folder": str(relative_folder).replace("\\", "/"),
            "fileCount": len(written),
        },
    )

    return jsonify(
        {
            "ok": True,
            "folder": str(relative_folder).replace("\\", "/"),
            "written": written,
        }
    )


@app.post("/v1/fuzz/start")
def fuzz_start() -> Response | tuple[Response, int]:
    body = request.get_json(silent=True)

    if not isinstance(body, dict):
        return jsonify({"ok": False, "error": "JSON object required"}), 400

    target = body.get("target")
    target_segments = body.get("target_segments")
    target_class = body.get("target_class")
    arg_types = body.get("arg_types", [])
    rate = body.get("rate", FUZZER_CONFIG["default_rate"])
    duration = body.get(
        "duration",
        FUZZER_CONFIG["default_duration_seconds"],
    )

    if not isinstance(target, str) or not target.strip():
        return jsonify({"ok": False, "error": "target string required"}), 400

    if not isinstance(target_segments, list) or not all(
        isinstance(segment, str) and segment
        for segment in target_segments
    ):
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "target_segments must be a string array",
                }
            ),
            400,
        )

    if target_class not in {"RemoteEvent", "RemoteFunction"}:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": "target_class must be RemoteEvent or RemoteFunction",
                }
            ),
            400,
        )

    if not isinstance(arg_types, list):
        return jsonify({"ok": False, "error": "arg_types must be an array"}), 400

    try:
        rate_value = float(rate)
        duration_value = float(duration)
    except (TypeError, ValueError):
        return jsonify({"ok": False, "error": "rate and duration must be numeric"}), 400

    max_rate = float(FUZZER_CONFIG["max_rate"])

    if not 1 <= rate_value <= max_rate:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": f"rate must be between 1 and {max_rate:g}",
                }
            ),
            400,
        )

    if not 0.1 <= duration_value <= MAX_FUZZ_DURATION_SECONDS:
        return (
            jsonify(
                {
                    "ok": False,
                    "error": (
                        f"duration must be between 0.1 and "
                        f"{MAX_FUZZ_DURATION_SECONDS} seconds"
                    ),
                }
            ),
            400,
        )

    now = time.time()
    session_id = uuid.uuid4().hex
    session = {
        "id": session_id,
        "status": "queued",
        "target": target,
        "targetSegments": target_segments,
        "targetClass": target_class,
        "argTypes": arg_types,
        "rate": rate_value,
        "duration": duration_value,
        "createdAt": now,
        "queueExpiresAt": now + max(duration_value, 60.0),
        "startedAt": None,
        "endsAt": None,
        "finishedAt": None,
        "assignedClient": None,
        "calls": 0,
        "errors": 0,
        "totalLatencyMs": 0.0,
        "latencyCount": 0,
        "lastLatencyMs": None,
        "lastError": None,
    }

    with fuzz_lock:
        fuzz_sessions[session_id] = session

    public = public_fuzz_session(session)
    event_bus.publish("fuzz", {"action": "started", "session": public})

    return jsonify({"ok": True, "sessionId": session_id, "session": public})


@app.post("/v1/fuzz/claim")
def fuzz_claim() -> Response | tuple[Response, int]:
    body = request.get_json(silent=True)

    if not isinstance(body, dict):
        return jsonify({"ok": False, "error": "JSON object required"}), 400

    client = body.get("client")
    if not isinstance(client, dict):
        return jsonify({"ok": False, "error": "client object required"}), 400

    user_id = client.get("userId")
    client_name = client.get("name")
    client_key = f"{user_id}:{client_name}"

    with fuzz_lock:
        selected: dict[str, Any] | None = None

        for session in fuzz_sessions.values():
            refresh_fuzz_session(session)

            if session["status"] == "running":
                assigned = session.get("assignedClient")
                if isinstance(assigned, dict) and assigned.get("key") == client_key:
                    selected = session
                    break

            if selected is None and session["status"] == "queued":
                selected = session

        if selected is None:
            return jsonify({"ok": True, "session": None})

        if selected["status"] == "queued":
            now = time.time()
            selected["status"] = "running"
            selected["startedAt"] = now
            selected["endsAt"] = now + float(selected["duration"])
            selected["assignedClient"] = {
                "key": client_key,
                "userId": user_id,
                "name": client_name,
            }

        public = public_fuzz_session(selected)

    event_bus.publish("fuzz", {"action": "claimed", "session": public})
    return jsonify({"ok": True, "session": public})


@app.post("/v1/fuzz/stop/<session_id>")
def fuzz_stop(session_id: str) -> Response | tuple[Response, int]:
    with fuzz_lock:
        session = fuzz_sessions.get(session_id)
        if session is None:
            return jsonify({"ok": False, "error": "session not found"}), 404

        refresh_fuzz_session(session)

        if session["status"] in {"queued", "running"}:
            session["status"] = "stopped"
            session["finishedAt"] = time.time()

        public = public_fuzz_session(session)

    event_bus.publish("fuzz", {"action": "stopped", "session": public})
    return jsonify({"ok": True, "session": public})


@app.get("/v1/fuzz/status/<session_id>")
def fuzz_status(session_id: str) -> Response | tuple[Response, int]:
    with fuzz_lock:
        session = fuzz_sessions.get(session_id)
        if session is None:
            return jsonify({"ok": False, "error": "session not found"}), 404

        public = public_fuzz_session(session)

    return jsonify({"ok": True, "session": public})


@app.post("/v1/fuzz/report/<session_id>")
def fuzz_report(session_id: str) -> Response | tuple[Response, int]:
    try:
        message = decode_request()
        payload = extract_payload(message, "fuzz_report")
    except EncoderError as exc:
        return jsonify({"ok": False, "error": str(exc)}), 400

    report_message: Any = payload
    if isinstance(payload, dict) and isinstance(payload.get("message"), dict):
        report_message = payload["message"]

    if not isinstance(report_message, dict):
        return jsonify({"ok": False, "error": "invalid fuzz report"}), 400

    with fuzz_lock:
        session = fuzz_sessions.get(session_id)
        if session is None:
            return jsonify({"ok": False, "error": "session not found"}), 404

        refresh_fuzz_session(session)

        phase = str(report_message.get("phase", "attempt"))
        if phase in {"attempt_ok", "attempt_error"}:
            session["calls"] = int(session["calls"]) + 1

        if phase in {"attempt_error", "session_error"}:
            session["errors"] = int(session["errors"]) + 1
            session["lastError"] = str(report_message.get("error", "unknown error"))

        latency = report_message.get("latencyMs")
        if isinstance(latency, (int, float)):
            session["lastLatencyMs"] = float(latency)
            session["totalLatencyMs"] = float(session["totalLatencyMs"]) + float(latency)
            session["latencyCount"] = int(session["latencyCount"]) + 1

        if phase == "session_finished" and session["status"] == "running":
            session["status"] = "completed"
            session["finishedAt"] = time.time()

        public = public_fuzz_session(session)

    trace = {
        "prefix": "[FUZZ]",
        "channel": "FUZZ",
        "phase": report_message.get("phase"),
        "sessionId": session_id,
        "target": report_message.get("target"),
        "attempt": report_message.get("attempt"),
        "latencyMs": report_message.get("latencyMs"),
        "error": report_message.get("error"),
    }

    event_bus.publish("traffic", {"record": trace, "source": "fuzz"})
    event_bus.publish("fuzz", {"action": "report", "session": public, "report": trace})

    return jsonify({"ok": True, "session": public})


@app.post("/v1/memory/read")
def memory_read_disabled() -> tuple[Response, int]:
    return (
        jsonify(
            {
                "ok": False,
                "error": "arbitrary_process_memory_reads_disabled",
                "message": (
                    "Use /v1/metrics, /v1/diagnostics, profiling, and "
                    "cooperative stack snapshots instead."
                ),
            }
        ),
        403,
    )


# Deliberately no memory-write endpoint.


if __name__ == "__main__":
    host = str(BRIDGE.get("host", LOOPBACK_HOST))
    port = int(BRIDGE.get("port", 8765))

    if host != LOOPBACK_HOST:
        raise SystemExit("Refusing to bind outside 127.0.0.1")

    logger.info(
        "Starting HarnessX bridge on http://%s:%s profile=%s",
        host,
        port,
        runtime_config.active_profile,
    )

    app.run(
        host=LOOPBACK_HOST,
        port=port,
        threaded=True,
        use_reloader=False,
    )
