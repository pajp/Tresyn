"""Exercise the compiled Swift trust-on-first-use client against real TLS."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

from drawing import Scene
from drawing_server import DrawingServer


CLIENT = Path(__file__).resolve().parents[1] / ".build/torus-client"


@unittest.skipUnless(CLIENT.exists(), "Build swift-client/build.sh first")
class SwiftTrustTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.trust = root / "trust"
        self.script = root / "commands.jsonl"
        self.script.write_text('{"op":"state"}\n')
        self.server = DrawingServer("127.0.0.1", 0, root / "server")
        self.scene = Scene()
        self.stop = threading.Event()
        self.worker = threading.Thread(target=self.pump)
        self.worker.start()
        self.endpoint = f"127.0.0.1:{self.server.port}"
        self.record = self.trust / (hashlib.sha256(self.endpoint.encode()).hexdigest() + ".json")

    def pump(self):
        while not self.stop.wait(0.002):
            self.server.process(self.scene.apply)

    def tearDown(self):
        self.server.close()
        self.stop.set()
        self.worker.join()
        self.directory.cleanup()

    def run_client(self, answer="", code=None):
        deadline = time.monotonic() + 3
        while self.server.pairing.active and time.monotonic() < deadline:
            time.sleep(0.01)
        return subprocess.run([str(CLIENT), "--port", str(self.server.port),
            "--trust-directory", str(self.trust), "--code", code or self.server.pairing.code,
            "--script", str(self.script)], input=answer, capture_output=True, text=True, timeout=20)

    def change_saved_identity(self):
        self.trust.mkdir()
        self.record.write_text(json.dumps({"endpoint": self.endpoint, "fingerprint": "0" * 64}))

    def test_first_pair_and_reconnect_without_fingerprint(self):
        first = self.run_client()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(json.loads(self.record.read_text())["fingerprint"], self.server.fingerprint)
        second = self.run_client()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertNotIn("WARNING", second.stderr)

    def test_changed_certificate_warns_and_decline_preserves_identity(self):
        self.change_saved_identity()
        result = self.run_client(answer="n\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("WARNING", result.stderr)
        self.assertEqual(json.loads(self.record.read_text())["fingerprint"], "0" * 64)
        self.assertFalse(self.server.pairing.active)

    def test_changed_certificate_can_be_accepted_and_saved(self):
        self.change_saved_identity()
        result = self.run_client(answer="yes\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARNING", result.stderr)
        self.assertEqual(json.loads(self.record.read_text())["fingerprint"], self.server.fingerprint)

    def test_incorrect_code_does_not_save_new_server(self):
        result = self.run_client(code="invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record.exists())

    def test_bad_code_can_be_retried_without_restarting_client(self):
        result = self.run_client(code="invalid", answer=self.server.pairing.code + "\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("New code", result.stdout)
        self.assertIn("Paired over encrypted TLS", result.stdout)
