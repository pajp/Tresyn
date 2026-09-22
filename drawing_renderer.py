"""OpenGL resources for the remotely controlled scene."""

import numpy as np
from OpenGL import GL
from bridge_python_sdk.Rendering.Mesh import Mesh
from bridge_python_sdk.Rendering.Shader import Shader

from drawing import geometry, model_matrix


VERTEX = """#version 330 core
layout(location=0) in vec3 position;
layout(location=1) in vec3 normal;
uniform mat4 model;
uniform mat4 vp;
out vec3 N;
out vec3 P;
void main() {
    vec4 p = model * vec4(position, 1.0);
    P = p.xyz;
    N = transpose(inverse(mat3(model))) * normal;
    gl_Position = vp * p;
}
"""

FRAGMENT = """#version 330 core
in vec3 N;
in vec3 P;
uniform vec3 eye;
uniform vec3 color;
out vec4 outputColor;
void main() {
    vec3 n = normalize(N);
    vec3 light = normalize(vec3(-0.6, 0.9, 1.4));
    vec3 view = normalize(eye - P);
    float diffuse = max(dot(n, light), 0.0);
    float shine = pow(max(dot(n, normalize(light + view)), 0.0), 40.0);
    outputColor = vec4(color * (0.35 + 0.65 * diffuse) + vec3(shine * 0.22), 1.0);
}
"""


class DrawingRenderer:
    def __init__(self):
        self.shader = Shader(VERTEX, FRAGMENT)
        self.uniforms = {name: GL.glGetUniformLocation(self.shader.id, name)
                         for name in ("model", "vp", "eye", "color")}
        self.meshes = {}

    def sync(self, scene):
        for key in list(self.meshes):
            if key not in scene.objects:
                del self.meshes[key]
        for key, obj in scene.objects.items():
            shape = {k: v for k, v in obj.items() if k not in ("position", "rotation", "scale", "color", "id")}
            if key not in self.meshes or self.meshes[key][0] != shape:
                mesh = Mesh(geometry(obj), [(0, 3, GL.GL_FLOAT, False, 24, 0),
                                            (1, 3, GL.GL_FLOAT, False, 24, 12)])
                self.meshes[key] = (shape, mesh)

    def draw(self, scene, vp, eye):
        self.shader.use()
        GL.glUniformMatrix4fv(self.uniforms["vp"], 1, GL.GL_TRUE, vp)
        GL.glUniform3f(self.uniforms["eye"], *eye)
        for key, obj in scene.objects.items():
            GL.glUniformMatrix4fv(self.uniforms["model"], 1, GL.GL_TRUE, model_matrix(obj))
            GL.glUniform3f(self.uniforms["color"], *obj["color"])
            self.meshes[key][1].draw()

    def close(self):
        self.meshes.clear()
        GL.glDeleteProgram(self.shader.id)
