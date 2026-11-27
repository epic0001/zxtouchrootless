import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_screenshot import make_device
from zxtouch.touchtypes import TOUCH_DOWN, TOUCH_MOVE, TOUCH_UP


class TouchCoordinatesTests(unittest.TestCase):
    def test_send_ocr_pixel_coordinates_directly_to_touch(self):
        device = make_device([b"0;;R0,,621,,1104,,30,,40\r\n"])
        ok, results = device.ocr((0, 0, 0, 0))
        self.assertTrue(ok)
        target = results[0]
        device.touch(TOUCH_DOWN, 1, target["x"], target["y"])
        device.touch(TOUCH_UP, 1, target["x"], target["y"])

        self.assertEqual(device.s.sent[-2:], [b"1011010621011040\r\n", b"1010010621011040\r\n"])

    def test_multitouch_preserves_fractional_screen_pixels(self):
        device = make_device([])
        device.touch_with_list([
            {"type": TOUCH_DOWN, "finger_index": 0, "x": 310.5, "y": 276.4},
            {"type": TOUCH_MOVE, "finger_index": 19, "x": 931.5, "y": 1932},
        ])

        self.assertEqual(device.s.sent, [b"10210003105027642190931519320\r\n"])

    def test_malformed_packet_is_not_sent(self):
        device = make_device([])
        with self.assertRaises(ValueError):
            device.touch(TOUCH_DOWN, 20, 50, 50)
        with self.assertRaises(ValueError):
            device.touch(TOUCH_UP, 0, 10000, 50)
        with self.assertRaises(ValueError):
            device.touch_with_list([])
        self.assertEqual(device.s.sent, [])

    def test_native_coordinate_mapping(self):
        compiler = shutil.which("cc") or shutil.which("clang")
        if compiler is None:
            self.skipTest("C compiler unavailable")
        source = Path(__file__).with_name("screen_coordinates.c")
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / "screen_coordinates_test.exe"
            subprocess.run(
                [compiler, "-std=c99", "-Wall", "-Wextra", "-Werror", str(source),
                 "-o", str(executable), "-lm"],
                check=True,
            )
            subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main()
