"""Short-lived authentication bootstrap for the local Web launcher."""

import secrets
import threading
import time


class BootstrapCredential:
    """Issue and consume one short-lived credential at a time."""

    def __init__(self, clock=time.monotonic):
        self._clock = clock
        self._lock = threading.Lock()
        self._secret = ""
        self._expires_at = 0.0
        self._consumed = True

    def issue(self, ttl_seconds=90):
        ttl = float(ttl_seconds)
        if ttl <= 0:
            raise ValueError("bootstrap credential lifetime must be positive")
        with self._lock:
            self._secret = secrets.token_urlsafe(32)
            self._expires_at = self._clock() + ttl
            self._consumed = False
            return self._secret

    def consume(self, candidate, api_token):
        supplied = str(candidate or "").strip()
        with self._lock:
            if self._consumed:
                return ""
            if self._clock() >= self._expires_at:
                self._secret = ""
                self._consumed = True
                return ""
            if not supplied or not secrets.compare_digest(supplied, self._secret):
                return ""
            self._consumed = True
            self._secret = ""
            return str(api_token or "")
