"""In-process Prometheus text metrics for the Web console (stdlib only)."""

from __future__ import annotations

import threading
import time
from typing import Dict, Iterable, Mapping, Optional, Tuple


def _escape_label_value(value: str) -> str:
    return (
        str(value)
        .replace("\\", "\\\\")
        .replace("\n", "\\n")
        .replace('"', '\\"')
    )


def _format_labels(labels: Mapping[str, str]) -> str:
    if not labels:
        return ""
    parts = [f'{key}="{_escape_label_value(value)}"' for key, value in sorted(labels.items())]
    return "{" + ",".join(parts) + "}"


class MetricsRegistry:
    """Thread-safe counter/gauge registry with Prometheus text rendering."""

    def __init__(self, process_start_time: Optional[float] = None) -> None:
        self._lock = threading.Lock()
        self._counters: Dict[Tuple[str, Tuple[Tuple[str, str], ...]], float] = {}
        self._gauges: Dict[Tuple[str, Tuple[Tuple[str, str], ...]], float] = {}
        self._help: Dict[str, str] = {}
        self._type: Dict[str, str] = {}
        self.process_start_time = float(
            process_start_time if process_start_time is not None else time.time()
        )

    def _label_key(self, labels: Optional[Mapping[str, str]]) -> Tuple[Tuple[str, str], ...]:
        if not labels:
            return ()
        return tuple(sorted((str(k), str(v)) for k, v in labels.items()))

    def register_counter(self, name: str, help_text: str) -> None:
        with self._lock:
            self._help[name] = help_text
            self._type[name] = "counter"

    def register_gauge(self, name: str, help_text: str) -> None:
        with self._lock:
            self._help[name] = help_text
            self._type[name] = "gauge"

    def inc(self, name: str, amount: float = 1.0, labels: Optional[Mapping[str, str]] = None) -> None:
        if amount < 0:
            raise ValueError("counter increments must be non-negative")
        key = (name, self._label_key(labels))
        with self._lock:
            self._type.setdefault(name, "counter")
            self._counters[key] = self._counters.get(key, 0.0) + float(amount)

    def set_gauge(self, name: str, value: float, labels: Optional[Mapping[str, str]] = None) -> None:
        key = (name, self._label_key(labels))
        with self._lock:
            self._type.setdefault(name, "gauge")
            self._gauges[key] = float(value)

    def get_counter(self, name: str, labels: Optional[Mapping[str, str]] = None) -> float:
        key = (name, self._label_key(labels))
        with self._lock:
            return float(self._counters.get(key, 0.0))

    def get_gauge(self, name: str, labels: Optional[Mapping[str, str]] = None) -> float:
        key = (name, self._label_key(labels))
        with self._lock:
            return float(self._gauges.get(key, 0.0))

    def render_prometheus_text(self, extra_gauges: Optional[Iterable[Tuple[str, Mapping[str, str], float]]] = None) -> str:
        """Render Prometheus exposition format (0.0.4 text)."""
        with self._lock:
            counters = dict(self._counters)
            gauges = dict(self._gauges)
            help_map = dict(self._help)
            type_map = dict(self._type)

        if extra_gauges:
            for name, labels, value in extra_gauges:
                key = (name, self._label_key(labels))
                gauges[key] = float(value)
                type_map.setdefault(name, "gauge")

        names = sorted(set(type_map) | {name for name, _ in counters} | {name for name, _ in gauges})
        lines = []
        for name in names:
            if name in help_map:
                lines.append(f"# HELP {name} {help_map[name]}")
            metric_type = type_map.get(name, "untyped")
            lines.append(f"# TYPE {name} {metric_type}")
            series = []
            for (metric_name, label_key), value in counters.items():
                if metric_name == name:
                    series.append((label_key, value))
            for (metric_name, label_key), value in gauges.items():
                if metric_name == name:
                    series.append((label_key, value))
            series.sort(key=lambda item: item[0])
            for label_key, value in series:
                labels = dict(label_key)
                lines.append(f"{name}{_format_labels(labels)} {self._format_value(value)}")
        lines.append("")
        return "\n".join(lines)

    @staticmethod
    def _format_value(value: float) -> str:
        if value == int(value) and abs(value) < 1e15:
            return str(int(value))
        return repr(float(value))


def normalize_route(path: str) -> str:
    """Map request paths onto low-cardinality route keys."""
    raw = str(path or "")
    if not raw.startswith("/"):
        raw = "/" + raw
    if raw == "/api/metrics":
        return "metrics"
    if raw == "/api/health":
        return "health"
    if raw == "/api/schema":
        return "schema"
    if raw == "/api/jobs":
        return "jobs"
    if raw.startswith("/api/jobs/"):
        rest = raw[len("/api/jobs/") :]
        if rest.endswith("/cancel"):
            return "jobs_cancel"
        if rest.endswith("/retry"):
            return "jobs_retry"
        return "jobs_detail"
    if raw.startswith("/api/"):
        # /api/foo/bar -> foo_bar
        parts = [part for part in raw[len("/api/") :].split("/") if part]
        if not parts:
            return "api"
        return "_".join(parts)
    return "static"


def create_default_registry(process_start_time: Optional[float] = None) -> MetricsRegistry:
    registry = MetricsRegistry(process_start_time=process_start_time)
    registry.register_counter(
        "linux_agent_http_requests_total",
        "Total HTTP API requests handled by the Web console.",
    )
    registry.register_gauge(
        "linux_agent_build_info",
        "Build metadata; value is always 1.",
    )
    registry.register_gauge(
        "linux_agent_process_start_time_seconds",
        "UNIX timestamp when the Web process started.",
    )
    registry.register_gauge(
        "linux_agent_jobs",
        "Current Job counts by status.",
    )
    registry.register_gauge(
        "linux_agent_jobs_active",
        "Current active (queued+running) Job count.",
    )
    registry.register_counter(
        "linux_agent_jobs_completed_total",
        "Jobs that reached a terminal status.",
    )
    registry.register_counter(
        "linux_agent_job_duration_seconds_sum",
        "Sum of Job wall durations in seconds.",
    )
    registry.register_counter(
        "linux_agent_job_duration_seconds_count",
        "Count of Jobs that contributed to duration sum.",
    )
    registry.register_counter(
        "linux_agent_web_audit_events_total",
        "Audit events appended by the Web process.",
    )
    return registry


__all__ = [
    "MetricsRegistry",
    "create_default_registry",
    "normalize_route",
]
