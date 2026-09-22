"""Bitmap pairing surface, rendered into every Looking Glass view."""

import socket
import numpy as np
from OpenGL import GL
from PIL import Image, ImageDraw, ImageFont
from bridge_python_sdk.Rendering.Mesh import Mesh
from bridge_python_sdk.Rendering.Shader import Shader


class PairingScreen:
    WIDTH, HEIGHT = 720, 1280
    BUTTONS = {"refresh": (64, 1015, 350, 1091), "back": (370, 1015, 656, 1091)}

    def __init__(self):
        self.signature = None
        self.host = socket.gethostname()
        self.texture = GL.glGenTextures(1)
        self.mesh = Mesh(np.array([[-.5, -.5], [.5, -.5], [.5, .5],
                                   [-.5, -.5], [.5, .5], [-.5, .5]], dtype=np.float32),
                         [(0, 2, GL.GL_FLOAT, False, 8, 0)])
        self.shader = Shader("""#version 330 core
layout(location=0) in vec2 p;
uniform mat4 mvp;
out vec2 uv;
void main() { uv = p + 0.5; gl_Position = mvp * vec4(p, 0, 1); }
""", """#version 330 core
in vec2 uv;
uniform sampler2D panel;
out vec4 color;
void main() { color = texture(panel, uv); }
""")
        self.mvp = GL.glGetUniformLocation(self.shader.id, "mvp")
        self.sampler = GL.glGetUniformLocation(self.shader.id, "panel")

    @staticmethod
    def font(size, bold=False, mono=False):
        name = "Courier New Bold.ttf" if mono else ("Arial Bold.ttf" if bold else "Arial.ttf")
        return ImageFont.truetype("/System/Library/Fonts/Supplemental/" + name, size)

    def update(self, state, port):
        signature = (tuple(state.items()), port)
        if signature == self.signature:
            return
        self.signature = signature
        image = Image.new("RGB", (self.WIDTH, self.HEIGHT), "#101517")
        draw = ImageDraw.Draw(image)
        white, muted, cyan, gold = "#eef3f1", "#95aaa8", "#58d6c5", "#f3cf83"

        def text(x, y, value, size, fill=white, bold=False, mono=False, max_width=592):
            font = self.font(size, bold, mono)
            while draw.textbbox((0, 0), value, font=font)[2] > max_width and size > 12:
                size -= 1
                font = self.font(size, bold, mono)
            draw.text((x, y), value, font=font, fill=fill)

        draw.rectangle((64, 86, 111, 93), fill=cyan)
        text(64, 112, "TORUS", 26, bold=True)
        text(64, 157, "DRAWING CONNECTION", 15, muted)
        draw.line((64, 215, 656, 215), fill="#344443", width=1)
        text(64, 265, "Pair your device", 47, bold=True)
        text(64, 330, "A private connection to this display.", 22, muted)
        status = state["status"]
        badge = {"ready": "READY TO PAIR", "expired": "CODE EXPIRED",
                 "locked": "PLEASE WAIT", "connected": "DEVICE CONNECTED"}[status]
        text(64, 419, badge, 17, cyan if status in ("ready", "connected") else gold, bold=True)
        draw.rounded_rectangle((64, 466, 656, 704), radius=8, fill="#1b2628", outline="#415957", width=2)
        text(94, 492, "ONE-TIME CODE", 15, muted)
        code = state["code"] if status == "ready" else "------"
        font = self.font(116, mono=True)
        bbox = draw.textbbox((0, 0), code, font=font)
        draw.text(((720 - (bbox[2] - bbox[0])) / 2, 535), code, font=font, fill=white)
        seconds = state["remaining"]
        label = {"ready": f"Expires in {seconds // 60}:{seconds % 60:02d}",
                 "expired": "Generate a new code to connect.",
                 "locked": f"Try again in {state['retry_after']} seconds.",
                 "connected": "Disconnect below to pair another device."}[status]
        text(64, 729, label, 20, muted)
        draw.rectangle((64, 778, 656, 782), fill="#304342")
        if status == "ready":
            draw.rectangle((64, 778, 64 + int(592 * seconds / 120), 782), fill=cyan)
        text(64, 829, "SERVER", 14, muted, bold=True)
        text(64, 858, self.host, 24, max_width=580)
        text(64, 904, f"Port {port}    /    TLS encrypted", 18, cyan)
        labels = {"refresh": "Disconnect & re-pair" if status == "connected" else "New code",
                  "back": "Back to scene"}
        for action, rectangle in self.BUTTONS.items():
            left, top, right, bottom = rectangle
            fill = cyan if action == "refresh" else "#202e30"
            draw.rounded_rectangle(rectangle, radius=6, fill=fill)
            font = self.font(21, bold=True)
            label = labels[action]
            width = draw.textbbox((0, 0), label, font=font)[2]
            draw.text(((left + right - width) / 2, top + 25), label, font=font,
                      fill="#122724" if action == "refresh" else white)
        text(64, 1145, "Your drawing stays here when you disconnect.", 17, muted)
        GL.glBindTexture(GL.GL_TEXTURE_2D, self.texture)
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 1)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGB8, self.WIDTH, self.HEIGHT, 0,
                        GL.GL_RGB, GL.GL_UNSIGNED_BYTE,
                        image.transpose(Image.Transpose.FLIP_TOP_BOTTOM).tobytes())
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
        for parameter in (GL.GL_TEXTURE_MIN_FILTER, GL.GL_TEXTURE_MAG_FILTER):
            GL.glTexParameteri(GL.GL_TEXTURE_2D, parameter, GL.GL_LINEAR)

    def draw(self, vp, aspect):
        self.shader.use()
        model = np.diag([5.2 * aspect, 5.2, 1, 1]).astype(np.float32)
        GL.glUniformMatrix4fv(self.mvp, 1, GL.GL_TRUE, vp @ model)
        GL.glUniform1i(self.sampler, 0)
        GL.glActiveTexture(GL.GL_TEXTURE0)
        GL.glBindTexture(GL.GL_TEXTURE_2D, self.texture)
        self.mesh.draw()

    @classmethod
    def hit(cls, x, y, width, height, aspect):
        w, h = min(width, height * aspect), min(height, width / aspect)
        if w <= 0 or h <= 0:
            return None
        x = (x - (width-w)/2) / w * cls.WIDTH
        y = (y - (height-h)/2) / h * cls.HEIGHT
        for action, (left, top, right, bottom) in cls.BUTTONS.items():
            if left <= x <= right and top <= y <= bottom:
                return action
        return None

    def close(self):
        del self.mesh
        GL.glDeleteTextures(1, [self.texture])
        GL.glDeleteProgram(self.shader.id)
