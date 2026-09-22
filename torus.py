#!/usr/bin/env python3
"""Trackpad-controlled torus for Looking Glass Bridge and a local preview."""

import argparse
from collections import OrderedDict
from datetime import datetime
import locale
import math
from pathlib import Path
import sys
import subprocess
import time

import glfw
import numpy as np
from OpenGL import GL
from PIL import Image, ImageDraw, ImageFont

from bridge_python_sdk.BridgeApi import BridgeAPI, PixelFormats
from bridge_python_sdk.Rendering.Mesh import Mesh
from bridge_python_sdk.Rendering.Shader import Shader
from bridge_python_sdk.Rendering.Window import Window
from schedule_feed import ScheduleFeed
from drawing import Scene
from drawing_renderer import DrawingRenderer
from drawing_server import DrawingServer
from pairing_ui import PairingScreen


VERTEX = """#version 330 core
layout(location=0) in vec3 position;
layout(location=1) in vec3 normal;
layout(location=2) in vec2 uv;
uniform mat4 model;
uniform mat4 vp;
out vec3 N;
out vec3 P;
out vec2 UV;
void main() {
    vec4 world = model * vec4(position, 1.0);
    P = world.xyz;
    N = mat3(model) * normal;
    UV = uv;
    gl_Position = vp * world;
}
"""

FRAGMENT = """#version 330 core
in vec3 N;
in vec3 P;
in vec2 UV;
uniform vec3 eye;
out vec4 color;
void main() {
    vec3 n = normalize(N);
    vec3 v = normalize(eye - P);
    vec3 light = normalize(vec3(-0.6, 0.9, 1.4));
    float diffuse = max(dot(n, light), 0.0);
    float specular = pow(max(dot(n, normalize(light + v)), 0.0), 70.0);
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    float stripe = smoothstep(0.91, 0.97, cos(UV.x * 6.2831853 * 12.0));
    vec3 base = mix(vec3(0.06, 0.65, 0.63), vec3(0.92, 0.40, 0.19), stripe);
    vec3 lit = base * (0.24 + 0.76 * diffuse);
    lit += vec3(0.85, 0.95, 1.0) * specular * 0.65;
    lit += vec3(0.16, 0.30, 0.42) * rim;
    color = vec4(pow(lit, vec3(1.0 / 2.2)), 1.0);
}
"""


def torus_vertices(segments=96, sides=32):
    """Interleaved positions, outward normals, and UVs, as triangles."""
    u, v = np.meshgrid(np.arange(segments + 1) / segments,
                       np.arange(sides + 1) / sides, indexing="ij")
    a, b = u * math.tau, v * math.tau
    radius = 0.69 + 0.24 * np.cos(b)
    grid = np.stack((radius * np.cos(a), radius * np.sin(a),
                     0.24 * np.sin(b), np.cos(b) * np.cos(a),
                     np.cos(b) * np.sin(a), np.sin(b), u, v), axis=-1)
    return np.stack((grid[:-1, :-1], grid[1:, :-1], grid[1:, 1:],
                     grid[:-1, :-1], grid[1:, 1:], grid[:-1, 1:]),
                    axis=2).reshape(-1, 8).astype(np.float32)


def rotation(axis, angle):
    x, y, z = axis
    c, s, t = math.cos(angle), math.sin(angle), 1 - math.cos(angle)
    return np.array(((t*x*x+c, t*x*y-s*z, t*x*z+s*y),
                     (t*x*y+s*z, t*y*y+c, t*y*z-s*x),
                     (t*x*z-s*y, t*y*z+s*x, t*z*z+c)), dtype=np.float32)


class Pose:
    def __init__(self):
        self.reset()

    def reset(self):
        self.position = np.zeros(3, dtype=np.float32)
        self.orientation = rotation((1, 0, 0), 0.45) @ rotation((0, 1, 0), -0.3)

    def rotate(self, dx, dy, roll=False):
        delta = (rotation((0, 0, 1), -dx * 0.008) if roll else
                 rotation((0, 1, 0), dx * 0.008) @ rotation((1, 0, 0), dy * 0.008))
        # Re-orthogonalize to prevent accumulated trackpad input distorting the mesh.
        u, _, vh = np.linalg.svd(delta @ self.orientation)
        self.orientation = u @ vh

    def move(self, dx=0, dy=0, dz=0):
        self.position = np.clip(self.position + (dx, dy, dz),
                                (-0.65, -1.65, -1.2), (0.65, 1.65, 1.2))

    def matrix(self):
        result = np.eye(4, dtype=np.float32)
        result[:3, :3] = self.orientation
        result[:3, 3] = self.position
        return result


def camera(view, aspect, cone, flip_y=False):
    distance, half_height = 8.0, 2.6
    eye_x = (view - 0.5) * 2 * distance * math.tan(math.radians(cone / 2))
    projection = np.zeros((4, 4), dtype=np.float32)
    projection[0, 0] = distance / (half_height * aspect)
    projection[1, 1] = distance / half_height * (-1 if flip_y else 1)
    # Off-axis cameras converge exactly on the display plane (world z=0).
    projection[0, 2] = -eye_x / (half_height * aspect)
    near, far = 0.1, 40.0
    projection[2, 2] = (far + near) / (near - far)
    projection[2, 3] = 2 * far * near / (near - far)
    projection[3, 2] = -1
    transform = np.eye(4, dtype=np.float32)
    transform[:3, 3] = (-eye_x, 0, -distance)
    return projection @ transform, (eye_x, 0, distance)


TEXT_VERTEX = """#version 330 core
layout(location=0) in vec2 position;
uniform mat4 model;
uniform mat4 vp;
out vec2 uv;
out vec3 localPosition;
void main() {
    uv = position + 0.5;
    vec4 local = model * vec4(position, 0.0, 1.0);
    localPosition = local.xyz;
    gl_Position = vp * local;
}
"""

TEXT_FRAGMENT = """#version 330 core
in vec2 uv;
uniform sampler2D lettering;
uniform float opacity;
uniform bool ticker;
in vec3 localPosition;
out vec4 color;
void main() {
    float alpha = texture(lettering, uv).r * opacity;
    if (ticker) {
        alpha *= 1.0 - smoothstep(0.90, 1.05, abs(localPosition.x));
    }
    if (alpha < 0.02) discard;
    color = vec4(1.0, 0.93, 0.68, alpha);
}
"""


def message_words(text):
    # Split long tokens so every piece remains legible inside the aperture.
    return [word[i:i + 18] for word in text.split() for i in range(0, len(word), 18)]


def configure_time_locale():
    candidates = []
    if sys.platform == "darwin":
        try:
            result = subprocess.run(["defaults", "read", "-g", "AppleLocale"],
                                    capture_output=True, text=True, timeout=2, check=True)
            name = result.stdout.strip().split("@", 1)[0]
            candidates.extend((name + ".UTF-8", name))
        except (OSError, subprocess.SubprocessError):
            pass
    candidates.append("")
    for candidate in candidates:
        try:
            return locale.setlocale(locale.LC_TIME, candidate)
        except locale.Error:
            continue
    return locale.setlocale(locale.LC_TIME)


def expand_message(template, moment=None, schedule=None):
    if "%schedule%" in template and schedule is not None:
        template = template.replace("%schedule%", schedule)
    if "%datetime%" not in template and "%greeting%" not in template:
        return template
    moment = moment or datetime.now()
    if moment.hour < 5 or moment.hour >= 23:
        greeting = "god natt"
    elif moment.hour < 10:
        greeting = "god morgon"
    elif moment.hour < 12:
        greeting = "god f\u00f6rmiddag"
    elif moment.hour < 18:
        greeting = "god eftermiddag"
    else:
        greeting = "god kv\u00e4ll"
    template = template.replace("%greeting%", greeting)
    formatted = (moment.strftime("%A ") + str(moment.day)
                 + moment.strftime(" %B %Y %H:%M:%S"))
    return template.replace("%datetime%", formatted)


def stream_positions(elapsed, count):
    if not count:
        return []
    travel, spacing = elapsed * 0.45, 1.35
    first = math.ceil((travel - 2.2) / spacing)
    last = math.floor((travel + 2.2) / spacing)
    return [(i % count, travel - i * spacing) for i in range(first, last + 1)]


def message_lines(text):
    return (text.splitlines() + ["", "", ""])[:3]


def crawl_rows(text, aspect, max_width=1.95, height=0.24):
    """Wrap measured words, preserving event boundaries and indivisible words."""
    rows = []
    for paragraph in text.split("\n"):
        paragraph = " ".join(paragraph.split())
        # Modest scaling keeps short fields such as a full date on one row.
        if paragraph and aspect(paragraph) * height <= max_width * 1.25:
            rows.append(paragraph)
            continue
        line = ""
        for word in paragraph.split():
            candidate = f"{line} {word}" if line else word
            if line and aspect(candidate) * height > max_width:
                rows.append(line)
                line = word
            else:
                line = candidate
        rows.append(line)
    return rows if any(rows) else []


def text_layout(lines, elapsed, aspect):
    """Text, local transform, opacity, and clipping for all three animations."""
    items = []

    def add(text, x, y, z, max_width, height, tilt=0, opacity=1, ticker=False):
        width = aspect(text) * height
        if width > max_width:
            height *= max_width / width
            width = max_width
        model = np.eye(4, dtype=np.float32)
        model[:3, :3] = rotation((1, 0, 0), tilt) @ np.diag([width, height, 1])
        model[:3, 3] = (x, y, z)
        items.append((text, model, opacity, ticker))

    words = message_words(lines[1])
    for index, z in stream_positions(elapsed, len(words)):
        add(words[index], 0, 0, z, 0.78, 0.25,
            opacity=min(1.0, (2.2 - abs(z)) / 0.4))

    rows = crawl_rows(lines[0], aspect)
    if rows:
        # Successive rows move up a tilted plane away from the viewer.
        travel, spacing, length = elapsed * 0.22, 0.36, 1.7
        for i in range(math.ceil((travel - length) / spacing), math.floor(travel / spacing) + 1):
            progress = travel - i * spacing
            fade = min(1.0, progress / 0.18, (length - progress) / 0.5)
            row = rows[i % len(rows)]
            if row:
                add(row, 0, 1.15 + progress * 0.48, -progress * 0.9,
                    1.95, 0.24, tilt=-math.radians(55), opacity=max(0, fade))

    words = message_words(lines[2])
    if words:
        widths = [aspect(word) * 0.19 for word in words]
        advances = [width + 0.09 for width in widths]
        cycle = sum(advances) + 0.5
        offset = (elapsed * 0.32) % cycle
        cursor = 0
        for word, width, advance in zip(words, widths, advances):
            for repeat in range(math.floor((offset - cursor - width - 1.05) / cycle),
                                math.ceil((offset - cursor + 1.05) / cycle) + 1):
                x = cursor + width / 2 + repeat * cycle - offset
                if x + width / 2 > -1.05 and x - width / 2 < 1.05:
                    add(word, x, -1.75, 0, width, 0.19, ticker=True)
            cursor += advance
    return items


class TextStream:
    def __init__(self, path):
        self.path = path.expanduser()
        self.words = []
        self.lines = ["", "", ""]
        self.template = ""
        self.rendered_text = None
        self.schedule = ScheduleFeed()
        self.signature = None
        self.next_check = 0
        self.started = time.monotonic()
        self.textures = OrderedDict()
        self.items = []
        self.last_error = None
        font_path = "/System/Library/Fonts/Supplemental/Arial.ttf"
        self.font = ImageFont.truetype(font_path, 64) if Path(font_path).exists() else ImageFont.load_default(size=64)
        self.mesh = Mesh(np.array([[-.5, -.5], [.5, -.5], [.5, .5],
                                   [-.5, -.5], [.5, .5], [-.5, .5]], dtype=np.float32),
                         [(0, 2, GL.GL_FLOAT, False, 8, 0)])
        self.shader = Shader(TEXT_VERTEX, TEXT_FRAGMENT)
        self.uniforms = {name: GL.glGetUniformLocation(self.shader.id, name)
                         for name in ("model", "vp", "lettering", "opacity", "ticker")}

    def aspect(self, text):
        left, _, right, _ = self.font.getbbox(text)
        return (max(1, right - left) + 8) / 80

    def update(self, now):
        if now >= self.next_check:
            self.next_check = now + 0.5
            try:
                stat = self.path.stat()
                signature = (stat.st_mtime_ns, stat.st_size, stat.st_ino)
                if signature != self.signature:
                    template = self.path.read_text(encoding="utf-8-sig")
                    if template != self.template:
                        self.template = template
                        self.started = now
                    self.signature = signature
                self.last_error = None
            except (OSError, UnicodeError) as exc:
                if str(exc) != self.last_error:
                    print(f"Message file: {exc}", file=sys.stderr)
                    self.last_error = str(exc)
                self.template = ""
                self.signature = None
        # Expand once per frame, before all quilt views, without restarting motion.
        rendered_text = tuple(expand_message(line, schedule=self.schedule.snapshot(crawl=index == 0)
                              if "%schedule%" in line else None)
                              for index, line in enumerate(message_lines(self.template)))
        if rendered_text != self.rendered_text:
            self.lines = list(rendered_text)
            self.words = message_words(self.lines[1])
            self.rendered_text = rendered_text
        self.items = [(self.texture(text), model, opacity, ticker)
                      for text, model, opacity, ticker in
                      text_layout(self.lines, now - self.started, self.aspect)]
        active = {item[0] for item in self.items}
        self.prune_textures(active)

    def prune_textures(self, active):
        for text, texture in list(self.textures.items()):
            if len(self.textures) <= 64:
                break
            if texture not in active:
                GL.glDeleteTextures(1, [self.textures.pop(text)])

    def texture(self, word):
        if word in self.textures:
            self.textures.move_to_end(word)
            return self.textures[word]
        left, _, right, _ = self.font.getbbox(word)
        image = Image.new("L", (max(1, right - left) + 8, 80))
        ImageDraw.Draw(image).text((4 - left, 62), word, font=self.font, fill=255, anchor="ls")
        texture = GL.glGenTextures(1)
        GL.glBindTexture(GL.GL_TEXTURE_2D, texture)
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 1)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_R8, *image.size, 0,
                        GL.GL_RED, GL.GL_UNSIGNED_BYTE,
                        image.transpose(Image.Transpose.FLIP_TOP_BOTTOM).tobytes())
        GL.glPixelStorei(GL.GL_UNPACK_ALIGNMENT, 4)
        for parameter in (GL.GL_TEXTURE_MIN_FILTER, GL.GL_TEXTURE_MAG_FILTER):
            GL.glTexParameteri(GL.GL_TEXTURE_2D, parameter, GL.GL_LINEAR)
        for parameter in (GL.GL_TEXTURE_WRAP_S, GL.GL_TEXTURE_WRAP_T):
            GL.glTexParameteri(GL.GL_TEXTURE_2D, parameter, GL.GL_CLAMP_TO_EDGE)
        self.textures[word] = texture
        return self.textures[word]

    def draw(self, vp, eye, pose, items=None):
        self.shader.use()
        GL.glUniformMatrix4fv(self.uniforms["vp"], 1, GL.GL_TRUE, vp @ pose)
        GL.glUniform1i(self.uniforms["lettering"], 0)
        GL.glActiveTexture(GL.GL_TEXTURE0)
        GL.glEnable(GL.GL_BLEND)
        GL.glBlendFunc(GL.GL_SRC_ALPHA, GL.GL_ONE_MINUS_SRC_ALPHA)
        GL.glDepthMask(GL.GL_FALSE)
        models = []
        for texture, local, opacity, ticker in self.items if items is None else items:
            model = pose @ local
            distance = np.linalg.norm(model[:3, 3] - eye)
            models.append((distance, texture, local, opacity, ticker))
        for _, texture, model, opacity, ticker in sorted(models, key=lambda item: -item[0]):
            GL.glBindTexture(GL.GL_TEXTURE_2D, texture)
            GL.glUniformMatrix4fv(self.uniforms["model"], 1, GL.GL_TRUE, model)
            GL.glUniform1f(self.uniforms["opacity"], opacity)
            GL.glUniform1i(self.uniforms["ticker"], ticker)
            self.mesh.draw()
        GL.glDepthMask(GL.GL_TRUE)
        GL.glDisable(GL.GL_BLEND)

    def close(self):
        self.schedule.close()
        for texture in self.textures.values():
            GL.glDeleteTextures(1, [texture])
        del self.mesh
        GL.glDeleteProgram(self.shader.id)


class App:
    def __init__(self, args):
        self.args = args
        self.window = Window(420, 740, "Torus | Connecting")
        self.pose = Pose()
        self.bridge = None
        self.connected = False
        self.texture = self.depth = self.fbo = 0
        self.aspect, self.cone = 0.5625, 40.0
        self.status = "Preview"
        self.last_cursor = None
        self.mesh = Mesh(torus_vertices(), [
            (0, 3, GL.GL_FLOAT, False, 32, 0),
            (1, 3, GL.GL_FLOAT, False, 32, 12),
            (2, 2, GL.GL_FLOAT, False, 32, 24)])
        self.shader = Shader(VERTEX, FRAGMENT)
        self.uniforms = {name: GL.glGetUniformLocation(self.shader.id, name)
                         for name in ("model", "vp", "eye")}
        self.text_stream = TextStream(args.message)
        self.scene = Scene()
        self.drawing = DrawingRenderer()
        self.server = None
        self.pair_screen = PairingScreen() if args.server else None
        self.show_pairing = False
        self.client_was_active = False
        self.last_title = None
        if args.server:
            self.server = DrawingServer(args.host, args.port)
            self.show_pairing = True
            print(f"Drawing server: TLS {args.host}:{self.server.port}", flush=True)
        if not args.preview:
            self.connect()
        self.window.set_title(f"Torus | {self.status}")
        self.window.center_on_screen()
        self.window.set_cursor_pos_callback(self.cursor)
        self.window.set_mouse_button_callback(self.mouse_button)
        self.window.set_scroll_callback(self.scroll)
        self.window.set_key_callback(self.key)
        glfw.set_window_focus_callback(self.window.handle, self.focus)
        self.window.focus()

    def connect(self):
        try:
            self.bridge = BridgeAPI()
            if not self.bridge.initialize("TrackpadTorus"):
                raise RuntimeError("Bridge initialization failed")
            if not self.bridge.get_displays():
                raise RuntimeError("No Looking Glass display found")
            self.handle = self.bridge.instance_window_gl(self.args.display)
            self.aspect, self.qw, self.qh, self.cols, self.rows = (
                self.bridge.get_default_quilt_settings(self.handle))
            self.cone = self.bridge.get_viewcone(self.handle)
            if not (self.aspect > 0 and self.qw > 0 and self.qh > 0
                    and self.cols > 0 and self.rows > 0 and 0 < self.cone < 180):
                raise RuntimeError("Bridge returned invalid display settings")
            glfw.make_context_current(self.window.handle)
            self.init_quilt()
            self.connected = True
            self.status = "Looking Glass connected"
            print(f"Bridge ready: {self.qw}x{self.qh}, {self.cols}x{self.rows} views, "
                  f"aspect {self.aspect:.4f}, view cone {self.cone:.1f}", flush=True)
        except Exception as exc:
            self.status = "Preview | Bridge unavailable"
            print(f"Preview only: {exc}\nStart Looking Glass Bridge, connect the Go, "
                  "then restart this app.", file=sys.stderr, flush=True)
        finally:
            glfw.make_context_current(self.window.handle)

    def init_quilt(self):
        self.texture = GL.glGenTextures(1)
        GL.glBindTexture(GL.GL_TEXTURE_2D, self.texture)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MIN_FILTER, GL.GL_LINEAR)
        GL.glTexParameteri(GL.GL_TEXTURE_2D, GL.GL_TEXTURE_MAG_FILTER, GL.GL_LINEAR)
        GL.glTexImage2D(GL.GL_TEXTURE_2D, 0, GL.GL_RGBA8, self.qw, self.qh,
                        0, GL.GL_RGBA, GL.GL_UNSIGNED_BYTE, None)
        self.depth = GL.glGenRenderbuffers(1)
        GL.glBindRenderbuffer(GL.GL_RENDERBUFFER, self.depth)
        GL.glRenderbufferStorage(GL.GL_RENDERBUFFER, GL.GL_DEPTH_COMPONENT24,
                                 self.qw, self.qh)
        self.fbo = GL.glGenFramebuffers(1)
        GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, self.fbo)
        GL.glFramebufferTexture2D(GL.GL_FRAMEBUFFER, GL.GL_COLOR_ATTACHMENT0,
                                  GL.GL_TEXTURE_2D, self.texture, 0)
        GL.glFramebufferRenderbuffer(GL.GL_FRAMEBUFFER, GL.GL_DEPTH_ATTACHMENT,
                                      GL.GL_RENDERBUFFER, self.depth)
        if GL.glCheckFramebufferStatus(GL.GL_FRAMEBUFFER) != GL.GL_FRAMEBUFFER_COMPLETE:
            raise RuntimeError("Cannot allocate quilt framebuffer")
        GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0)

    def held(self, *keys):
        return any(glfw.get_key(self.window.handle, key) == glfw.PRESS for key in keys)

    def focus(self, window, focused):
        self.last_cursor = None

    def cursor(self, window, x, y):
        previous, self.last_cursor = self.last_cursor, (x, y)
        if previous is None or self.show_pairing:
            return
        dx, dy = x - previous[0], y - previous[1]
        left = glfw.get_mouse_button(window, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
        right = glfw.get_mouse_button(window, glfw.MOUSE_BUTTON_RIGHT) == glfw.PRESS
        shift = self.held(glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT)
        if right or (left and shift):
            height = max(1, self.window.get_size()[1])
            self.pose.move(dx * 5.2 / height, -dy * 5.2 / height)
        elif left:
            self.pose.rotate(dx, dy, self.held(glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT))

    def scroll(self, window, dx, dy):
        if self.show_pairing:
            return
        if self.held(glfw.KEY_LEFT_SHIFT, glfw.KEY_RIGHT_SHIFT):
            self.pose.move(dz=dy * 0.055)
        elif self.held(glfw.KEY_LEFT_ALT, glfw.KEY_RIGHT_ALT):
            self.pose.rotate((dx + dy) * 3, 0, roll=True)
        else:
            self.pose.move(dx * 0.035, dy * 0.035)

    def mouse_button(self, window, button, action, mods):
        if self.show_pairing and button == glfw.MOUSE_BUTTON_LEFT and action == glfw.PRESS:
            x, y = glfw.get_cursor_pos(window)
            command = self.pair_screen.hit(x, y, *self.window.get_size(), self.aspect)
            if command == "refresh":
                if self.server.pairing.active:
                    self.server.disconnect_client()
                else:
                    self.server.pairing.issue()
            elif command == "back":
                self.show_pairing = False

    def key(self, window, key, scancode, action, mods):
        if action == glfw.PRESS:
            if key == glfw.KEY_ESCAPE:
                glfw.set_window_should_close(window, True)
            elif key in (glfw.KEY_R, glfw.KEY_HOME):
                self.pose.reset()
            elif key == glfw.KEY_TAB:
                self.scene.apply({"op": "mode", "mode": "drawing" if self.scene.mode == "dashboard" else "dashboard"})
                self.show_pairing = False
            elif key == glfw.KEY_P and self.server:
                if mods & glfw.MOD_SHIFT:
                    self.server.disconnect_client()
                else:
                    self.server.pairing.issue()
                self.show_pairing = True

    def draw(self, view=0.5, quilt=False):
        vp, eye = camera(view, self.aspect, self.cone, quilt)
        if self.show_pairing:
            self.pair_screen.draw(vp, self.aspect)
            return
        if self.scene.mode == "drawing":
            self.drawing.draw(self.scene, vp, eye)
            return
        self.shader.use()
        GL.glUniformMatrix4fv(self.uniforms["model"], 1, GL.GL_TRUE, self.pose.matrix())
        GL.glUniformMatrix4fv(self.uniforms["vp"], 1, GL.GL_TRUE, vp)
        GL.glUniform3f(self.uniforms["eye"], *eye)
        self.mesh.draw()
        self.text_stream.draw(vp, np.array(eye), self.pose.matrix())

    def frame(self):
        glfw.make_context_current(self.window.handle)
        if not self.show_pairing and self.scene.mode == "dashboard":
            self.text_stream.update(time.monotonic())
        if self.server:
            self.server.process(self.scene.apply)
            if self.server.pairing_needed.is_set():
                self.server.pairing_needed.clear()
                self.show_pairing = True
            active = self.server.pairing.active
            if active and not self.client_was_active:
                self.show_pairing = False
            self.client_was_active = active
            if self.show_pairing:
                self.pair_screen.update(self.server.pairing.snapshot(), self.server.port)
        self.drawing.sync(self.scene)
        title = f"Torus | {self.scene.mode.title()} | {self.status}"
        if self.server:
            title += " | Client paired" if self.server.pairing.active else f" | TLS :{self.server.port}"
        if title != self.last_title:
            self.window.set_title(title)
            self.last_title = title
        GL.glEnable(GL.GL_DEPTH_TEST)
        GL.glDisable(GL.GL_CULL_FACE)
        GL.glDisable(GL.GL_SCISSOR_TEST)
        if self.connected:
            GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, self.fbo)
            GL.glClearColor(0, 0, 0, 1)
            GL.glClear(GL.GL_COLOR_BUFFER_BIT | GL.GL_DEPTH_BUFFER_BIT)
            vw, vh = self.qw // self.cols, self.qh // self.rows
            total = self.cols * self.rows
            for i in range(total):
                GL.glViewport((i % self.cols) * vw,
                              (self.rows - 1 - i // self.cols) * vh, vw, vh)
                self.draw(i / (total - 1) if total > 1 else 0.5, quilt=True)
            GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0)
            self.bridge.draw_interop_quilt_texture_gl(
                self.handle, self.texture, PixelFormats.RGBA, self.qw, self.qh,
                self.cols, self.rows, self.aspect, 1.0)
            glfw.make_context_current(self.window.handle)
        GL.glBindFramebuffer(GL.GL_FRAMEBUFFER, 0)
        width, height = self.window.framebuffer_size()
        GL.glViewport(0, 0, width, height)
        GL.glClearColor(0.025, 0.03, 0.035, 1)
        GL.glClear(GL.GL_COLOR_BUFFER_BIT | GL.GL_DEPTH_BUFFER_BIT)
        # Letterbox the preview to preserve the actual display's framing on resize.
        w = min(width, int(height * self.aspect))
        h = min(height, int(width / self.aspect))
        GL.glViewport((width - w) // 2, (height - h) // 2, w, h)
        self.draw()

    def run(self):
        print("Drag: rotate | Two-finger scroll: move | Shift-scroll: depth\n"
              "Shift-drag: move | Option-drag/scroll: roll | R: reset | Esc: quit",
              flush=True)
        if self.server:
            print("P: show pairing code | Shift+P: disconnect client and re-pair | Tab: dashboard/drawing", flush=True)
        frames, start = 0, time.monotonic()
        while not self.window.should_close():
            self.window.poll_events()
            self.frame()
            frames += 1
            if self.args.frames and frames >= self.args.frames:
                if self.args.screenshot:
                    width, height = self.window.framebuffer_size()
                    pixels = GL.glReadPixels(0, 0, width, height, GL.GL_RGB, GL.GL_UNSIGNED_BYTE)
                    Image.frombytes("RGB", (width, height), pixels).transpose(
                        Image.Transpose.FLIP_TOP_BOTTOM).save(self.args.screenshot)
                print(f"Rendered {frames} frames in {time.monotonic() - start:.2f}s; "
                      f"GL error: {GL.glGetError()}", flush=True)
                break
            self.window.swap_buffers()

    def close(self):
        if self.server:
            self.server.close()
        glfw.make_context_current(self.window.handle)
        if self.bridge:
            try:
                self.bridge.uninitialize()
            except Exception as exc:
                print(f"Bridge shutdown: {exc}", file=sys.stderr)
        glfw.make_context_current(self.window.handle)
        GL.glDeleteFramebuffers(1, [self.fbo])
        GL.glDeleteTextures(1, [self.texture])
        GL.glDeleteRenderbuffers(1, [self.depth])
        del self.mesh
        self.text_stream.close()
        self.drawing.close()
        if self.pair_screen:
            self.pair_screen.close()
        GL.glDeleteProgram(self.shader.id)
        self.window.terminate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", action="store_true", help="Run without Bridge")
    parser.add_argument("--server", action="store_true", help="Enable paired TLS drawing control")
    parser.add_argument("--host", default="0.0.0.0", help="Server bind address; default allows LAN clients")
    parser.add_argument("--port", type=int, default=8765, help="TLS server port")
    parser.add_argument("--message", type=Path, default=Path.home() / "torusmessage.txt",
                        help="UTF-8 message file, reloaded automatically")
    parser.add_argument("--display", type=int, default=-1, help="Bridge display index (default: primary)")
    parser.add_argument("--frames", type=int, default=0, help="Exit after N frames (smoke test)")
    parser.add_argument("--screenshot", type=Path, help="Save preview on the last test frame")
    args = parser.parse_args()
    configure_time_locale()
    app = App(args)
    try:
        app.run()
    finally:
        app.close()


if __name__ == "__main__":
    main()
