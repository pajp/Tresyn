"""Validated protocol scene and CPU geometry; all mutation happens on the render thread."""

import math
import numpy as np


PRIMITIVES = ("sphere", "box", "torus", "tetrahedron", "cylinder", "cone",
              "capsule", "line", "polyline")
MAX_OBJECTS = 128
MAX_POINTS = 1024
MAX_SCENE_POINTS = 8192


class CommandError(ValueError):
    pass


def number(value, low, high):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CommandError("Expected a number")
    if not math.isfinite(value) or not low <= value <= high:
        raise CommandError(f"Number must be finite and between {low} and {high}")
    return float(value)


def vector(value, size, low, high):
    if not isinstance(value, list) or len(value) != size:
        raise CommandError(f"Expected an array of {size} numbers")
    return [number(item, low, high) for item in value]


def identifier(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 64:
        raise CommandError("Object ID must contain 1-64 characters")
    return value


def points(value, minimum=2):
    if not isinstance(value, list) or not minimum <= len(value) <= MAX_POINTS:
        raise CommandError(f"Expected {minimum}-{MAX_POINTS} points")
    result = [vector(point, 3, -10, 10) for point in value]
    if any(np.linalg.norm(np.subtract(a, b)) < 1e-5 for a, b in zip(result, result[1:])):
        raise CommandError("Adjacent points must be distinct")
    return result


def validate_object(value):
    if not isinstance(value, dict):
        raise CommandError("object must be a JSON object")
    kind = value.get("type")
    if kind not in PRIMITIVES:
        raise CommandError("Unsupported primitive type")
    obj = {"id": identifier(value.get("id")), "type": kind,
           "position": vector(value.get("position", [0, 0, 0]), 3, -10, 10),
           "rotation": vector(value.get("rotation", [0, 0, 0, 1]), 4, -1, 1),
           "scale": vector(value.get("scale", [1, 1, 1]), 3, 0.001, 10),
           "color": vector(value.get("color", [0.1, 0.8, 0.7]), 3, 0, 1)}
    norm = np.linalg.norm(obj["rotation"])
    if norm < 1e-6:
        raise CommandError("Rotation quaternion must be nonzero")
    obj["rotation"] = (np.array(obj["rotation"]) / norm).tolist()
    if kind in ("box", "tetrahedron"):
        obj["size"] = vector(value.get("size", [0.5, 0.5, 0.5]), 3, 0.001, 5)
    elif kind in ("cylinder", "cone", "capsule"):
        obj["size"] = vector(value.get("size", [0.5, 0.5, 0.5]), 3, 0.001, 5)
        obj["radius"] = number(value.get("radius", 0.25), 0.005, 2.5)
    elif kind == "torus":
        obj["major_radius"] = number(value.get("major_radius", 0.4), 0.01, 2)
        obj["minor_radius"] = number(value.get("minor_radius", 0.12), 0.005, 1)
        if obj["minor_radius"] >= obj["major_radius"]:
            raise CommandError("minor_radius must be smaller than major_radius")
    elif kind in ("line", "polyline"):
        obj["points"] = points(value.get("points"))
        if kind == "line" and len(obj["points"]) != 2:
            raise CommandError("A line requires exactly two points")
        obj["radius"] = number(value.get("radius", 0.015), 0.002, 0.3)
    else:
        obj["radius"] = number(value.get("radius", 0.25), 0.005, 3)
    return obj


class Scene:
    def __init__(self):
        self.mode = "dashboard"
        self.objects = {}
        self.revision = 0

    def apply(self, message):
        op = message.get("op")
        if op == "mode":
            if message.get("mode") not in ("dashboard", "drawing"):
                raise CommandError("mode must be dashboard or drawing")
            self.mode = message["mode"]
        elif op == "put":
            obj = validate_object(message.get("object"))
            if obj["id"] not in self.objects and len(self.objects) >= MAX_OBJECTS:
                raise CommandError("Scene object limit reached")
            self._store(obj)
        elif op == "append":
            key = identifier(message.get("object_id"))
            if key not in self.objects or self.objects[key]["type"] != "polyline":
                raise CommandError("append requires an existing polyline")
            obj = dict(self.objects[key])
            obj["points"] = points(obj["points"] + points(message.get("points"), 1))
            self._store(obj)
        elif op == "delete":
            self.objects.pop(identifier(message.get("object_id")), None)
        elif op == "clear":
            self.objects.clear()
        elif op != "state":
            raise CommandError("Unknown operation")
        if op != "state":
            self.revision += 1
        # A full snapshot lets remote clients faithfully rebuild their local 3D previews
        # after reconnecting, rather than showing only objects created this session.
        return {"mode": self.mode, "object_ids": list(self.objects),
                "objects": list(self.objects.values()), "revision": self.revision}

    def _store(self, obj):
        total = sum(len(item.get("points", [])) for key, item in self.objects.items()
                    if key != obj["id"]) + len(obj.get("points", []))
        if total > MAX_SCENE_POINTS:
            raise CommandError("Scene point limit reached")
        self.objects[obj["id"]] = obj


def model_matrix(obj):
    x, y, z, w = obj["rotation"]
    matrix = np.eye(4, dtype=np.float32)
    matrix[:3, :3] = np.array([
        [1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
        [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
        [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]) @ np.diag(obj["scale"])
    matrix[:3, 3] = obj["position"]
    return matrix


def grid_triangles(positions, normals):
    grid = np.concatenate((positions, normals), axis=-1)
    return np.stack((grid[:-1, :-1], grid[1:, :-1], grid[1:, 1:],
                     grid[:-1, :-1], grid[1:, 1:], grid[:-1, 1:]),
                    axis=2).reshape(-1, 6).astype(np.float32)


def flat_triangles(vertices, faces):
    """Expand indexed triangles with a unit face normal for each vertex."""
    rows = []
    vertices = np.asarray(vertices, dtype=np.float32)
    for a, b, c in faces:
        triangle = vertices[[a, b, c]]
        normal = np.cross(triangle[1] - triangle[0], triangle[2] - triangle[0])
        normal /= np.linalg.norm(normal)
        rows.extend(np.concatenate((point, normal)) for point in triangle)
    return np.asarray(rows, dtype=np.float32)


def radial_geometry(radius, height, top_radius=None, sides=32):
    """Build a closed Y-axis cylinder or cone with flat caps."""
    top_radius = radius if top_radius is None else top_radius
    vertices = []
    for y, ring_radius in ((-height / 2, radius), (height / 2, top_radius)):
        vertices.extend((ring_radius * math.cos(angle), y, ring_radius * math.sin(angle))
                        for angle in np.linspace(0, math.tau, sides, endpoint=False))
    vertices.extend(((0, -height / 2, 0), (0, height / 2, 0)))
    faces = []
    for side in range(sides):
        next_side = (side + 1) % sides
        if top_radius > 0:
            faces.extend(((side, sides + side, next_side),
                          (next_side, sides + side, sides + next_side)))
        else:
            faces.append((side, sides + side, next_side))
        faces.append((2 * sides, next_side, side))
        if top_radius > 0:
            faces.append((2 * sides + 1, sides + side, sides + next_side))
    return flat_triangles(vertices, faces)


def geometry(obj):
    kind = obj["type"]
    if kind in ("sphere", "torus"):
        u, v = np.meshgrid(np.linspace(0, math.tau, 49),
                           np.linspace(0, math.pi if kind == "sphere" else math.tau, 25),
                           indexing="ij")
        if kind == "sphere":
            n = np.stack((np.cos(u)*np.sin(v), np.sin(u)*np.sin(v), np.cos(v)), axis=-1)
            p = n * obj["radius"]
        else:
            n = np.stack((np.cos(u)*np.cos(v), np.sin(u)*np.cos(v), np.sin(v)), axis=-1)
            p = n * obj["minor_radius"]
            p[..., 0] += obj["major_radius"] * np.cos(u)
            p[..., 1] += obj["major_radius"] * np.sin(u)
        return grid_triangles(p, n)
    if kind == "box":
        rows = []
        for axis in range(3):
            for sign in (-1, 1):
                normal = np.zeros(3)
                normal[axis] = sign
                corners = []
                for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                    point = normal.copy()
                    point[(axis + 1) % 3], point[(axis + 2) % 3] = a, b
                    corners.append(np.concatenate((point * np.array(obj["size"]) / 2, normal)))
                rows.extend(corners[index] for index in (0, 1, 2, 0, 2, 3))
        return np.array(rows, dtype=np.float32)
    if kind == "tetrahedron":
        width, height, depth = obj["size"]
        vertices = ((0, height / 2, 0), (-width / 2, -height / 2, depth / 2),
                    (width / 2, -height / 2, depth / 2), (0, -height / 2, -depth / 2))
        return flat_triangles(vertices, ((0, 1, 2), (0, 2, 3), (0, 3, 1), (1, 3, 2)))
    if kind in ("cylinder", "cone"):
        return radial_geometry(obj["radius"], obj["size"][1], 0 if kind == "cone" else None)
    if kind == "capsule":
        radius = obj["radius"]
        half_segment = max(obj["size"][1] / 2 - radius, 0)
        u, v = np.meshgrid(np.linspace(0, math.tau, 49),
                           np.linspace(-math.pi / 2, math.pi / 2, 25), indexing="ij")
        n = np.stack((np.cos(u) * np.cos(v), np.sin(v), np.sin(u) * np.cos(v)), axis=-1)
        p = n * radius
        p[..., 1] += np.where(v < 0, -half_segment, half_segment)
        return grid_triangles(p, n)
    # Volumetric tubes avoid platform-dependent OpenGL line-width limitations.
    path = np.array(obj["points"], dtype=np.float32)
    tangents = np.diff(path, axis=0)
    tangents /= np.linalg.norm(tangents, axis=1)[:, None]
    directions = np.vstack((tangents[0], tangents[:-1] + tangents[1:], tangents[-1]))
    rings, normals = [], []
    side = None
    for i, direction in enumerate(directions):
        if np.linalg.norm(direction) < 1e-5:
            direction = tangents[min(i, len(tangents)-1)]
        direction = direction / np.linalg.norm(direction)
        # Transport the previous frame to avoid abrupt ring twists along a stroke.
        if side is not None:
            side = side - np.dot(side, direction) * direction
        if side is None or np.linalg.norm(side) < 1e-5:
            reference = np.eye(3)[np.argmin(np.abs(direction))]
            side = np.cross(direction, reference)
        side /= np.linalg.norm(side)
        up = np.cross(direction, side)
        angle = np.linspace(0, math.tau, 9)
        normal = np.cos(angle)[:, None]*side + np.sin(angle)[:, None]*up
        rings.append(path[i] + obj["radius"] * normal)
        normals.append(normal)
    vertices = grid_triangles(np.array(rings), np.array(normals))
    caps = []
    for index, normal in ((0, -tangents[0]), (-1, tangents[-1])):
        for j in range(8):
            caps.extend(np.concatenate((point, normal)) for point in
                        (path[index], rings[index][j], rings[index][j+1]))
    return np.vstack((vertices, caps)).astype(np.float32)
