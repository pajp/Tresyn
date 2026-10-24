"""TLS + bounded JSON-lines control channel with single-use display pairing."""

from dataclasses import dataclass, field
import hashlib
import hmac
import json
import os
from pathlib import Path
import queue
import secrets
import socket
import ssl
import subprocess
import threading
import time

from drawing import CommandError, PRIMITIVES, MAX_OBJECTS, MAX_POINTS, MAX_SCENE_POINTS, Scene


MAX_MESSAGE = 256 * 1024


def identity(directory):
    directory = Path(directory)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    key, cert = directory / "key.pem", directory / "cert.pem"
    if not key.exists() or not cert.exists():
        # Restrict permissions from creation, including the openssl child process.
        previous = os.umask(0o077)
        try:
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", str(key), "-out", str(cert), "-days", "3650",
                            "-subj", "/CN=Torus Drawing Server"],
                           check=True, capture_output=True, timeout=30)
        finally:
            os.umask(previous)
    key.chmod(0o600)
    fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    return context, fingerprint


class Pairing:
    def __init__(self):
        self.lock = threading.Lock()
        self.code = ""
        self.expires = 0
        self.blocked_until = 0
        self.failures = 0
        self.active_count = 0
        self.issue()

    @property
    def active(self):
        return self.active_count > 0

    def issue(self):
        with self.lock:
            if time.monotonic() < self.blocked_until:
                return
            self.code = f"{secrets.randbelow(1000000):06d}"
            self.expires = time.monotonic() + 120
            self.failures = 0

    def consume(self, code):
        return self.authenticate(code) is None

    def authenticate(self, code):
        with self.lock:
            now = time.monotonic()
            if now < self.blocked_until:
                return "pairing_locked"
            if now >= self.expires or not self.code:
                return "pairing_expired"
            if (not isinstance(code, str) or len(code) != 6 or not code.isascii()
                    or not hmac.compare_digest(code, self.code)):
                self.failures += 1
                if self.failures >= 5:
                    self.code = ""
                    self.blocked_until = now + 60
                return "pairing_locked" if self.failures >= 5 else "invalid_code"
            self.code = ""
            self.active_count += 1
            return None

    def release(self):
        with self.lock:
            self.active_count = max(0, self.active_count - 1)
            inactive = self.active_count == 0
        if inactive:
            self.issue()
        return inactive

    def claim(self):
        """Register a previously paired client."""
        with self.lock:
            self.active_count += 1
            return None

    def display(self):
        with self.lock:
            if time.monotonic() < self.blocked_until:
                return ["Pairing locked", "Press P after one minute"]
            seconds = max(0, int(self.expires - time.monotonic()))
            if self.active and (not self.code or not seconds):
                return ["Drawing client connected"]
            if not self.code or not seconds:
                return ["Pairing expired", "Press P for a new code"]
            return ["Pair with this display", f"Code: {self.code}", f"Expires in {seconds}s"]

    def snapshot(self):
        with self.lock:
            now = time.monotonic()
            seconds = max(0, int(self.expires - now))
            retry = max(0, int(self.blocked_until - now) + 1)
            status = ("locked" if now < self.blocked_until
                      else "ready" if self.code and seconds
                      else "connected" if self.active else "expired")
            return {"status": status, "code": self.code if status == "ready" else "",
                    "remaining": seconds, "retry_after": retry}


class ResumeCredentials:
    """Persistent, opaque reconnect credentials; only SHA-256 digests reach disk."""
    def __init__(self, directory):
        self.file = Path(directory) / "drawing-clients.json"
        self.lock = threading.Lock()
        self.digests = []
        try:
            values = json.loads(self.file.read_text())
            if isinstance(values, list) and all(isinstance(value, str) and len(value) == 64 for value in values):
                self.digests = list(dict.fromkeys(values))[-8:]
        except (OSError, ValueError, json.JSONDecodeError):
            pass

    def issue(self):
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        with self.lock:
            if digest in self.digests:
                self.digests.remove(digest)
            self.digests.append(digest)
            # Keep the eight most recently paired clients.
            self.digests = self.digests[-8:]
            temporary = self.file.with_suffix(".tmp")
            temporary.write_text(json.dumps(self.digests))
            temporary.chmod(0o600)
            temporary.replace(self.file)
            self.file.chmod(0o600)
        return token

    def accepts(self, token):
        if not isinstance(token, str) or not 32 <= len(token) <= 128:
            return False
        candidate = hashlib.sha256(token.encode()).hexdigest()
        with self.lock:
            return any(hmac.compare_digest(candidate, digest) for digest in self.digests)


@dataclass
class Pending:
    message: dict
    connection: object
    done: threading.Event = field(default_factory=threading.Event)
    lock: threading.Lock = field(default_factory=threading.Lock)
    cancelled: bool = False
    response: dict = field(default_factory=dict)
    broadcast_scene: dict = None


def error(request_id, code, detail):
    return {"v": 1, "id": request_id, "ok": False, "error": {"code": code, "message": detail}}


class DrawingServer:
    def __init__(self, host="0.0.0.0", port=8765, directory=None):
        directory = directory or Path(__file__).with_name(".drawing-local")
        self.context, self.fingerprint = identity(directory)
        self.credentials = ResumeCredentials(directory)
        self.scene_file = Path(directory) / "drawing-scene.json"
        self.pairing = Pairing()
        self.commands = queue.Queue(maxsize=64)
        self.stop = threading.Event()
        self.slots = threading.BoundedSemaphore(4)
        self.connections = set()
        self.authenticated_connections = set()
        self.locally_disconnected_connections = set()
        self.send_locks = {}
        self.pairing_needed = threading.Event()
        self.lock = threading.Lock()
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.listener.bind((host, port))
            self.listener.listen(4)
        except Exception:
            self.listener.close()
            raise
        self.port = self.listener.getsockname()[1]
        self.listener.settimeout(0.5)
        self.thread = threading.Thread(target=self._accept, name="drawing-server", daemon=True)
        self.thread.start()

    def load_scene(self):
        """Return the last complete scene, or a new scene if none can be restored."""
        scene = Scene()
        try:
            saved = json.loads(self.scene_file.read_text())
            if not isinstance(saved, dict) or saved.get("version") != 1:
                return scene
            objects = saved.get("objects")
            if not isinstance(objects, list):
                return scene
            restored = Scene()
            restored.apply({"op": "mode", "mode": saved.get("mode")})
            for obj in objects:
                restored.apply({"op": "put", "object": obj})
            return restored
        except (OSError, ValueError, TypeError, json.JSONDecodeError, CommandError):
            return scene

    def save_scene(self, scene):
        """Atomically persist a validated snapshot for the next server launch."""
        payload = {"version": 1, "mode": scene.mode, "objects": list(scene.objects.values())}
        temporary = self.scene_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(payload, allow_nan=False, separators=(",", ":")))
        temporary.chmod(0o600)
        temporary.replace(self.scene_file)
        self.scene_file.chmod(0o600)

    def _accept(self):
        while not self.stop.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            if not self.slots.acquire(blocking=False):
                connection.close()
                continue
            with self.lock:
                self.connections.add(connection)
                self.send_locks[connection] = threading.Lock()
            threading.Thread(target=self._client, args=(connection,), daemon=True).start()

    def _client(self, raw):
        connection = raw
        authenticated = False
        pending = None
        try:
            raw.settimeout(10)
            connection = self.context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False)
            with self.lock:
                send_lock = self.send_locks.pop(raw)
                self.connections.discard(raw)
                self.connections.add(connection)
                self.send_locks[connection] = send_lock
            connection.do_handshake()
            with connection.makefile("rb") as reader:
                while not self.stop.is_set():
                    line = reader.readline(MAX_MESSAGE + 1)
                    if not line:
                        break
                    if len(line) > MAX_MESSAGE or not line.endswith(b"\n"):
                        break
                    request_id = None
                    try:
                        message = json.loads(line, parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))
                        if not isinstance(message, dict):
                            raise ValueError("Expected an object")
                        request_id = message.get("id")
                        if (not isinstance(request_id, str) or not 1 <= len(request_id) <= 64
                                or type(message.get("v")) is not int or message["v"] != 1
                                or not isinstance(message.get("op"), str)):
                            raise ValueError("Expected v=1, string id (1-64 chars), and string op")
                    except (ValueError, UnicodeError, RecursionError):
                        self._send(connection, error(None, "bad_message", "Invalid version 1 JSON message"))
                        break
                    if not authenticated:
                        resume_token = None
                        if message["op"] == "resume":
                            reason = None if self.credentials.accepts(message.get("token")) else "unknown_client"
                            if reason is None:
                                reason = self.pairing.claim()
                        elif message["op"] == "pair":
                            reason = self.pairing.authenticate(message.get("code"))
                            if reason is None:
                                resume_token = self.credentials.issue()
                        else:
                            reason = "authentication_required"
                        if reason:
                            detail = {
                                "client_busy": "Another client is connected. Close it, or press Shift+P in the server window to disconnect it and show a fresh code.",
                                "pairing_locked": "Too many incorrect codes. Wait one minute, then press P in the server window for a new code.",
                                "pairing_expired": "The code expired or was already used. Press P in the server window for a fresh code.",
                                "invalid_code": "That code is incorrect or was already used. Press P in the server window and enter the fresh code.",
                                "unknown_client": "This device has not paired with the server. Enter the one-time display code.",
                                "authentication_required": "Pair with the one-time code before sending commands.",
                            }[reason]
                            self._send(connection, error(request_id, reason, detail))
                            break
                        authenticated = True
                        with self.lock:
                            self.authenticated_connections.add(connection)
                        connection.settimeout(60)
                        self._send(connection, {"v": 1, "id": request_id, "ok": True,
                                   "result": {"protocol": "torus-drawing", "primitives": PRIMITIVES,
                                              "limits": {"objects": MAX_OBJECTS, "points_per_object": MAX_POINTS,
                                                         "scene_points": MAX_SCENE_POINTS, "message_bytes": MAX_MESSAGE},
                                              **({"resume_token": resume_token} if resume_token else {})}})
                        continue
                    if message["op"] == "ping":
                        self._send(connection, {"v": 1, "id": request_id, "ok": True, "result": {}})
                        continue
                    pending = Pending(message, connection)
                    try:
                        self.commands.put_nowait(pending)
                    except queue.Full:
                        self._send(connection, error(request_id, "busy", "Render queue is full"))
                        continue
                    if not pending.done.wait(5):
                        with pending.lock:
                            if not pending.done.is_set():
                                pending.cancelled = True
                                pending.response = error(request_id, "timeout", "Renderer did not apply command")
                    self._send(connection, pending.response)
                    if pending.broadcast_scene is not None:
                        self._broadcast_scene(pending.broadcast_scene, excluding=connection)
                    pending = None
        except (OSError, ValueError):
            pass
        finally:
            if pending is not None:
                with pending.lock:
                    pending.cancelled = True
            with self.lock:
                self.connections.discard(raw)
                self.connections.discard(connection)
                self.send_locks.pop(raw, None)
                self.send_locks.pop(connection, None)
                locally_disconnected = connection in self.locally_disconnected_connections
                self.locally_disconnected_connections.discard(connection)
            connection.close()
            if authenticated:
                with self.lock:
                    self.authenticated_connections.discard(connection)
                if self.pairing.release() and locally_disconnected:
                    self.pairing_needed.set()
            self.slots.release()

    def _send(self, connection, message):
        payload = json.dumps(message, allow_nan=False, separators=(",", ":")).encode() + b"\n"
        with self.lock:
            send_lock = self.send_locks.get(connection)
        if send_lock is None:
            return
        with send_lock:
            connection.sendall(payload)

    def _broadcast_scene(self, scene, excluding):
        event = {"v": 1, "event": "scene_changed", "result": scene}
        with self.lock:
            connections = tuple(self.authenticated_connections - {excluding})
        for connection in connections:
            try:
                self._send(connection, event)
            except OSError:
                # The owning client thread performs connection cleanup.
                pass

    def disconnect_client(self):
        """Disconnect all clients locally; remote unauthenticated callers cannot evict them."""
        with self.lock:
            connections = tuple(self.authenticated_connections)
            for connection in connections:
                self.locally_disconnected_connections.add(connection)
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        if not connections:
            self.pairing.issue()
            self.pairing_needed.set()

    def process(self, apply):
        for _ in range(16):
            try:
                pending = self.commands.get_nowait()
            except queue.Empty:
                break
            with pending.lock:
                if pending.cancelled:
                    continue
                request_id = pending.message["id"]
                try:
                    result = apply(pending.message)
                    pending.response = {"v": 1, "id": request_id, "ok": True, "result": result}
                    if pending.message["op"] != "state":
                        pending.broadcast_scene = result
                except CommandError as exc:
                    pending.response = error(request_id, "invalid_command", str(exc))
                except Exception:
                    pending.response = error(request_id, "internal_error", "Cannot apply command")
                pending.done.set()

    def close(self, scene=None):
        self.stop.set()
        self.listener.close()
        with self.lock:
            for connection in self.connections:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
        self.thread.join(timeout=1)
        if scene is not None:
            self.save_scene(scene)
