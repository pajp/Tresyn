import json
import socket
import ssl
import tempfile
import threading
import time
import unittest

from drawing import Scene
from drawing_server import DrawingServer, MAX_MESSAGE


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def setUp(self):
        self.server = DrawingServer("127.0.0.1", 0, self.directory.name)
        self.scene = Scene()
        self.stop = threading.Event()
        self.clients = []
        def render_loop():
            while not self.stop.wait(0.002):
                self.server.process(self.scene.apply)
        self.worker = threading.Thread(target=render_loop)
        self.worker.start()

    def tearDown(self):
        for connection, reader in self.clients:
            reader.close()
            connection.close()
        self.server.close()
        self.stop.set()
        self.worker.join()

    def connect(self, trusted=True):
        context = ssl.create_default_context(cafile=self.directory.name + "/cert.pem") if trusted else ssl.create_default_context()
        raw = socket.create_connection(("127.0.0.1", self.server.port), timeout=3)
        try:
            connection = context.wrap_socket(raw, server_hostname="Torus Drawing Server")
        except Exception:
            raw.close()
            raise
        reader = connection.makefile("rb")
        self.clients.append((connection, reader))
        return connection, reader

    def request(self, client, op, **fields):
        client[0].sendall(json.dumps({"v": 1, "id": "test", "op": op, **fields}).encode() + b"\n")
        while True:
            message = json.loads(client[1].readline())
            if message.get("id") == "test":
                return message

    def event(self, client):
        message = json.loads(client[1].readline())
        self.assertEqual(message.get("v"), 1)
        self.assertEqual(message.get("event"), "scene_changed")
        return message["result"]

    def test_authenticated_commands_and_invalid_command(self):
        client = self.connect()
        self.assertTrue(self.request(client, "pair", code=self.server.pairing.code)["ok"])
        self.assertTrue(self.request(client, "mode", mode="drawing")["ok"])
        result = self.request(client, "put", object={"id": "sphere", "type": "sphere"})
        self.assertEqual(result["result"]["object_ids"], ["sphere"])
        self.assertFalse(self.request(client, "put", object={"id": "bad", "type": "unknown"})["ok"])
        self.assertTrue(self.request(client, "delete", object_id="sphere")["ok"])
        self.assertTrue(self.request(client, "clear")["ok"])

    def test_pair_required_and_multiple_writers(self):
        client = self.connect()
        self.assertFalse(self.request(client, "clear")["ok"])
        good = self.connect()
        code = self.server.pairing.code
        self.assertTrue(self.request(good, "pair", code=code)["ok"])
        self.server.pairing.issue()
        other = self.connect()
        self.assertTrue(self.request(other, "pair", code=self.server.pairing.code)["ok"])
        self.assertTrue(self.request(good, "put", object={"id": "first", "type": "sphere"})["ok"])
        result = self.request(other, "put", object={"id": "second", "type": "box"})
        self.assertTrue(result["ok"])
        self.assertEqual(set(result["result"]["object_ids"]), {"first", "second"})

    def test_multiple_paired_clients_can_resume_together(self):
        first = self.connect()
        first_pairing = self.request(first, "pair", code=self.server.pairing.code)
        self.server.pairing.issue()
        second = self.connect()
        second_pairing = self.request(second, "pair", code=self.server.pairing.code)

        first_resumed = self.connect()
        second_resumed = self.connect()
        self.assertTrue(self.request(first_resumed, "resume", token=first_pairing["result"]["resume_token"])["ok"])
        self.assertTrue(self.request(second_resumed, "resume", token=second_pairing["result"]["resume_token"])["ok"])

    def test_scene_changes_are_pushed_to_other_clients(self):
        first = self.connect()
        self.assertTrue(self.request(first, "pair", code=self.server.pairing.code)["ok"])
        self.server.pairing.issue()
        second = self.connect()
        self.assertTrue(self.request(second, "pair", code=self.server.pairing.code)["ok"])

        applied = self.request(first, "put", object={"id": "shared", "type": "sphere"})["result"]
        pushed = self.event(second)

        self.assertEqual(pushed, applied)
        self.assertEqual(pushed["object_ids"], ["shared"])

    def test_paired_client_can_resume_without_a_display_code(self):
        client = self.connect()
        paired = self.request(client, "pair", code=self.server.pairing.code)
        token = paired["result"].get("resume_token")
        self.assertIsInstance(token, str)
        client[1].close()
        client[0].close()
        self.clients.remove(client)
        deadline = time.monotonic() + 2
        while self.server.pairing.active and time.monotonic() < deadline:
            time.sleep(0.01)
        resumed = self.connect()
        self.assertTrue(self.request(resumed, "resume", token=token)["ok"])

    def test_wrong_code_and_untrusted_tls(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.connect(trusted=False)
        client = self.connect()
        self.assertFalse(self.request(client, "pair", code="invalid")["ok"])
        self.assertFalse(self.server.pairing.active)

    def test_fragmented_and_coalesced_frames(self):
        client = self.connect()
        data = json.dumps({"v": 1, "id": "a", "op": "pair", "code": self.server.pairing.code}).encode() + b"\n"
        client[0].sendall(data[:12])
        client[0].sendall(data[12:] + b'{"v":1,"id":"b","op":"ping"}\n')
        self.assertEqual(json.loads(client[1].readline())["id"], "a")
        self.assertEqual(json.loads(client[1].readline())["id"], "b")

    def test_bad_json_does_not_mutate_scene(self):
        client = self.connect()
        self.request(client, "pair", code=self.server.pairing.code)
        client[0].sendall(b'{"v":1,"id":"nan","op":"put","object":NaN}\n')
        self.assertFalse(json.loads(client[1].readline())["ok"])
        self.assertEqual(self.scene.objects, {})

    def test_oversized_frame_is_rejected(self):
        client = self.connect()
        self.assertTrue(self.request(client, "pair", code=self.server.pairing.code)["ok"])
        try:
            client[0].sendall(b" " * (MAX_MESSAGE + 1))
            self.assertEqual(client[1].readline(), b"")
        except (ConnectionResetError, ssl.SSLError):
            pass
        self.assertEqual(self.scene.objects, {})

    def test_local_disconnect_reopens_pairing(self):
        client = self.connect()
        self.assertTrue(self.request(client, "pair", code=self.server.pairing.code)["ok"])
        self.server.disconnect_client()
        self.assertTrue(self.server.pairing_needed.wait(2))
        self.assertFalse(self.server.pairing.active)
        self.assertEqual(self.server.pairing.snapshot()["status"], "ready")
        other = self.connect()
        self.assertTrue(self.request(other, "pair", code=self.server.pairing.code)["ok"])

    def test_remote_disconnect_does_not_request_pairing_screen(self):
        client = self.connect()
        self.assertTrue(self.request(client, "pair", code=self.server.pairing.code)["ok"])
        client[1].close()
        client[0].close()

        deadline = time.monotonic() + 2
        while self.server.pairing.active and time.monotonic() < deadline:
            time.sleep(0.01)

        self.assertFalse(self.server.pairing.active)
        self.assertFalse(self.server.pairing_needed.is_set())
        self.assertEqual(self.server.pairing.snapshot()["status"], "ready")


if __name__ == "__main__":
    unittest.main()
