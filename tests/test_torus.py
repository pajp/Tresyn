import unittest
from datetime import datetime
import locale
from pathlib import Path
import tempfile
from unittest.mock import patch

import numpy as np

from torus import (Pose, TextStream, camera, expand_message, message_words,
                   message_lines, crawl_rows, text_layout, stream_positions, torus_vertices)


class GeometryTests(unittest.TestCase):
    def test_crawl_wraps_measured_words_without_breaking_them(self):
        text = "Religion / Livsaskadningskunskap\n08:15-09:00\n\nNext event"
        rows = crawl_rows(text, lambda text: len(text) * 0.5)
        self.assertIn("Livsaskadningskunskap", rows)
        self.assertIn("08:15-09:00", rows)
        self.assertIn("", rows)
        self.assertEqual(" ".join(rows).split(), text.split())
        self.assertEqual(crawl_rows("", lambda text: 0), [])

    def test_localized_datetime(self):
        previous = locale.setlocale(locale.LC_TIME)
        try:
            try:
                locale.setlocale(locale.LC_TIME, "sv_FI.UTF-8")
            except locale.Error:
                self.skipTest("Swedish locale is unavailable")
            moment = datetime(2026, 9, 16, 22, 32, 15)
            expected = "onsdag 16 september 2026 22:32:15"
            self.assertEqual(expand_message("%datetime% / %datetime%", moment),
                             expected + " / " + expected)
            self.assertIn(" 6 september ", expand_message("%datetime%", moment.replace(day=6)))
            self.assertEqual(expand_message("hello world", moment), "hello world")
        finally:
            locale.setlocale(locale.LC_TIME, previous)

    def test_clock_updates_without_restarting_stream(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "message.txt"
            path.write_text("\nTime: %datetime%", encoding="utf-8")
            stream = TextStream.__new__(TextStream)
            stream.path = path
            stream.words = []
            stream.template = ""
            stream.rendered_text = None
            stream.signature = None
            stream.next_check = 0
            stream.started = 0
            stream.last_error = None
            stream.texture = lambda word: word
            stream.aspect = lambda word: len(word) * 0.5
            stream.textures = {}
            with patch("torus.datetime") as clock:
                clock.now.return_value = datetime(2026, 9, 16, 22, 32, 15)
                stream.update(10)
                self.assertIn("22:32:15", stream.words)
                clock.now.return_value = datetime(2026, 9, 16, 22, 32, 16)
                stream.update(10.1)
                self.assertIn("22:32:16", stream.words)
                self.assertEqual(stream.started, 10)
                self.assertEqual(path.read_text(), "\nTime: %datetime%")

    def test_three_line_layout(self):
        self.assertEqual(message_lines("top\r\n\r\nbottom\nignored"), ["top", "", "bottom"])
        self.assertEqual(message_lines("top"), ["top", "", ""])
        self.assertEqual(text_layout(["", "", ""], 1, lambda text: 2), [])
        before = text_layout(["top", "middle", "bottom"], 1, lambda text: 2)
        after = text_layout(["top", "middle", "bottom"], 1.1, lambda text: 2)
        for items in (before, after):
            for text, model, opacity, ticker in items:
                self.assertTrue(0 <= opacity <= 1)
                if text == "top":
                    self.assertGreater(model[1, 3], 1)
                    self.assertLess(model[2, 3], 0)
                elif text == "middle":
                    self.assertEqual(model[1, 3], 0)
                else:
                    self.assertLess(model[1, 3], -1)
                    self.assertTrue(ticker)
        x_before = next(m[0, 3] for text, m, _, _ in before if text == "bottom")
        x_after = next(m[0, 3] for text, m, _, _ in after if text == "bottom")
        self.assertLess(x_after, x_before)

    def test_message_stream(self):
        self.assertEqual(message_words("hello\nworld"), ["hello", "world"])
        self.assertEqual(message_words("  "), [])
        self.assertTrue(all(len(word) <= 18 for word in message_words("x" * 50)))
        self.assertEqual(stream_positions(1, 0), [])
        self.assertIn((0, 0.0), stream_positions(0, 2))
        self.assertIn((0, 0.45), stream_positions(1, 2))
        for index, z in stream_positions(1000, 2):
            self.assertIn(index, (0, 1))
            self.assertLessEqual(abs(z), 2.2)

    def test_normals_and_winding(self):
        vertices = torus_vertices()
        self.assertEqual(vertices.shape, (96 * 32 * 6, 8))
        np.testing.assert_allclose(np.linalg.norm(vertices[:, 3:6], axis=1), 1, atol=1e-6)
        triangles = vertices.reshape(-1, 3, 8)
        cross = np.cross(triangles[:, 1, :3] - triangles[:, 0, :3],
                         triangles[:, 2, :3] - triangles[:, 0, :3])
        self.assertTrue(np.all(np.sum(cross * triangles[:, 0, 3:6], axis=1) > 0))

    def test_display_plane_converges_across_views(self):
        point = np.array((0.2, 0.3, 0, 1))
        projected = []
        for view in (0, 0.5, 1):
            matrix, _ = camera(view, 0.5625, 40)
            p = matrix @ point
            projected.append(p[:2] / p[3])
        np.testing.assert_allclose(projected[0], projected[1], atol=1e-6)
        np.testing.assert_allclose(projected[1], projected[2], atol=1e-6)

    def test_depth_creates_parallax(self):
        positions = []
        for view in (0, 1):
            matrix, _ = camera(view, 0.5625, 40)
            p = matrix @ np.array((0, 0, 0.5, 1))
            positions.append(p[0] / p[3])
        self.assertGreater(positions[0], positions[1])

    def test_pose_stays_rigid_and_resets(self):
        pose = Pose()
        initial = pose.matrix().copy()
        for i in range(1000):
            pose.rotate(3, -2, roll=i % 5 == 0)
        np.testing.assert_allclose(pose.orientation.T @ pose.orientation, np.eye(3), atol=1e-5)
        self.assertAlmostEqual(np.linalg.det(pose.orientation), 1, places=5)
        pose.move(100, -100, 100)
        np.testing.assert_allclose(pose.position, (0.65, -1.65, 1.2))
        pose.reset()
        np.testing.assert_allclose(pose.matrix(), initial)


if __name__ == "__main__":
    unittest.main()
