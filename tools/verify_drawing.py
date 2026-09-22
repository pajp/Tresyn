"""Exercise the real Swift TLS client against the OpenGL app, then save previews."""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np
from OpenGL import GL
from PIL import Image
from torus import App, configure_time_locale


def capture(app, path):
    app.frame()
    width, height = app.window.framebuffer_size()
    data = GL.glReadPixels(0, 0, width, height, GL.GL_RGB, GL.GL_UNSIGNED_BYTE)
    pixels = np.frombuffer(data, dtype=np.uint8).reshape(height, width, 3)
    assert np.count_nonzero(pixels.max(axis=2) - pixels.min(axis=2) > 35) > 1000, "Blank drawing"
    Image.frombytes("RGB", (width, height), data).transpose(Image.Transpose.FLIP_TOP_BOTTOM).save(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    configure_time_locale()
    app = App(argparse.Namespace(preview=not args.bridge, server=True, host="127.0.0.1",
              port=0, display=-1, message=Path.home() / "torusmessage.txt", frames=0, screenshot=None))
    client = None
    trust_directory = tempfile.TemporaryDirectory()
    try:
        app.frame()
        w, h = app.window.framebuffer_size()
        Image.frombytes("RGB", (w, h), GL.glReadPixels(0, 0, w, h, GL.GL_RGB, GL.GL_UNSIGNED_BYTE)).transpose(
            Image.Transpose.FLIP_TOP_BOTTOM).save("/tmp/torus-pairing.png")
        client = subprocess.Popen([str(root / ".build/torus-client"), "--port", str(app.server.port),
                     "--trust-directory", trust_directory.name,
                     "--code", app.server.pairing.code, "--demo"],
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 45
        while client.poll() is None and time.monotonic() < deadline:
            app.window.poll_events()
            app.frame()
            app.window.swap_buffers()
        if client.poll() is None:
            client.kill()
            raise RuntimeError("Swift demo timed out")
        stdout, stderr = client.communicate()
        print(stdout)
        if client.returncode:
            raise RuntimeError(stderr)
        assert app.scene.mode == "drawing"
        assert len(app.scene.objects) == 5
        assert len(app.scene.objects["stroke"]["points"]) == 150
        app.server.pairing_needed.wait(2)
        app.server.pairing_needed.clear()
        app.show_pairing = False
        capture(app, "/tmp/torus-drawing.png")
        app.window.set_size(700, 500)
        app.window.poll_events()
        capture(app, "/tmp/torus-drawing-wide.png")
        print(f"Swift demo verified: {app.scene.revision} scene changes; GL error {GL.glGetError()}")
    finally:
        if client is not None and client.poll() is None:
            client.kill()
            client.wait()
        app.close()
        trust_directory.cleanup()


if __name__ == "__main__":
    main()
