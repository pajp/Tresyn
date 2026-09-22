import unittest
import numpy as np

from drawing import CommandError, Scene, geometry, model_matrix, validate_object
from drawing_server import Pairing
from pairing_ui import PairingScreen


class SceneTests(unittest.TestCase):
    def test_modes_replace_delete_and_clear(self):
        scene = Scene()
        scene.apply({"op": "mode", "mode": "drawing"})
        scene.apply({"op": "put", "object": {"id": "a", "type": "sphere"}})
        scene.apply({"op": "put", "object": {"id": "a", "type": "box"}})
        self.assertEqual(len(scene.objects), 1)
        self.assertEqual(scene.objects["a"]["type"], "box")
        scene.apply({"op": "mode", "mode": "dashboard"})
        self.assertEqual(len(scene.objects), 1)
        scene.apply({"op": "delete", "object_id": "a"})
        scene.apply({"op": "delete", "object_id": "a"})
        scene.apply({"op": "clear"})
        self.assertEqual(scene.objects, {})

    def test_invalid_update_is_atomic(self):
        scene = Scene()
        scene.apply({"op": "put", "object": {"id": "a", "type": "sphere"}})
        before = scene.objects["a"].copy()
        for fields in ({"radius": -1}, {"position": [float("nan"), 0, 0]},
                       {"rotation": [0, 0, 0, 0]}, {"color": [1, 2, 0]},
                       {"scale": [1, 0, 1]}, {"type": "future-shape"}):
            with self.assertRaises(CommandError):
                scene.apply({"op": "put", "object": {"id": "a", "type": "sphere", **fields}})
            self.assertEqual(scene.objects["a"], before)

    def test_incremental_stroke(self):
        scene = Scene()
        scene.apply({"op": "put", "object": {"id": "stroke", "type": "polyline",
                                               "points": [[0, 0, 0], [1, 0, 0]]}})
        scene.apply({"op": "append", "object_id": "stroke", "points": [[1, 1, 0]]})
        self.assertEqual(len(scene.objects["stroke"]["points"]), 3)
        with self.assertRaises(CommandError):
            scene.apply({"op": "append", "object_id": "stroke", "points": [[1, 1, 0]]})
        self.assertEqual(len(scene.objects["stroke"]["points"]), 3)

    def test_geometry_and_transform(self):
        for kind in ("sphere", "box", "torus", "line", "polyline"):
            obj = validate_object({"id": "shape", "type": kind,
                                   "points": [[0, 0, 0], [1, 1, 1]],
                                   "position": [0.1, 0.2, 0.3], "scale": [2, 1, 0.5]})
            vertices = geometry(obj)
            self.assertEqual(vertices.shape[1], 6)
            self.assertEqual(len(vertices) % 3, 0)
            self.assertTrue(np.isfinite(vertices).all())
            np.testing.assert_allclose(np.linalg.norm(vertices[:, 3:], axis=1), 1, atol=1e-5)
            np.testing.assert_allclose(model_matrix(obj)[:3, 3], [0.1, 0.2, 0.3])

    def test_stroke_reversal_does_not_generate_nan(self):
        obj = validate_object({"id": "s", "type": "polyline", "points": [[0, 0, 0], [1, 0, 0], [0, 0, 0]]})
        self.assertTrue(np.isfinite(geometry(obj)).all())


class PairingTests(unittest.TestCase):
    def test_pairing_buttons_respect_letterboxing(self):
        self.assertEqual(PairingScreen.hit(200, 1050, 720, 1280, 0.5625), "refresh")
        self.assertEqual(PairingScreen.hit(500, 1050, 720, 1280, 0.5625), "back")
        self.assertIsNone(PairingScreen.hit(5, 5, 1400, 800, 0.5625))
        self.assertIsNone(PairingScreen.hit(0, 0, 0, 0, 0.5625))

    def test_one_use_expiry_and_lockout(self):
        pairing = Pairing()
        code = pairing.code
        self.assertTrue(pairing.consume(code))
        self.assertFalse(pairing.consume(code))
        pairing.release()
        pairing.expires = 0
        self.assertFalse(pairing.consume(pairing.code))
        pairing.issue()
        for _ in range(5):
            self.assertFalse(pairing.consume("wrong"))
        pairing.issue()
        self.assertEqual(pairing.code, "")
        self.assertIn("locked", pairing.display()[0])


if __name__ == "__main__":
    unittest.main()
