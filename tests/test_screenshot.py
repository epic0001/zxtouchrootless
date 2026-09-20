import os
import sys
import unittest


PYTHON_CLIENT_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "layout", "usr", "share", "zxtouch", "python")
)
sys.path.insert(0, PYTHON_CLIENT_ROOT)

from zxtouch import datahandler, tasktypes  # noqa: E402
from zxtouch.client import zxtouch  # noqa: E402


class ChunkedSocket:
    def __init__(self, chunks):
        self.chunks = [bytes(chunk) for chunk in chunks]
        self.sent = []

    def sendall(self, data):
        self.sent.append(bytes(data))

    def send(self, data):
        self.sent.append(bytes(data))
        return len(data)

    def recv(self, size):
        if not self.chunks:
            return b""

        chunk = self.chunks[0]
        result = chunk[:size]
        if len(result) == len(chunk):
            self.chunks.pop(0)
        else:
            self.chunks[0] = chunk[size:]
        return result


def make_device(chunks):
    device = zxtouch.__new__(zxtouch)
    device.s = ChunkedSocket(chunks)
    device._recv_buffer = bytearray()
    return device


class ScreenshotProtocolTests(unittest.TestCase):
    def test_header_then_body(self):
        jpeg = b"\xff\xd8header-then-body\xff\xd9"
        device = make_device([
            b"0;;image/jpeg;;%d\r\n" % len(jpeg),
            jpeg,
        ])

        self.assertEqual(device.screenshot(), jpeg)
        self.assertEqual(device.s.sent, [datahandler.format_socket_data(tasktypes.TASK_SCREENSHOT)])

    def test_header_split_across_reads(self):
        jpeg = b"\xff\xd8split-header\xff\xd9"
        device = make_device([
            b"0;;ima",
            b"ge/jpeg;;",
            str(len(jpeg)).encode("ascii") + b"\r",
            b"\n",
            jpeg,
        ])

        self.assertEqual(device.screenshot(), jpeg)

    def test_header_and_partial_body_in_same_read(self):
        jpeg = b"\xff\xd8header-and-body\xff\xd9"
        header = b"0;;image/jpeg;;%d\r\n" % len(jpeg)
        device = make_device([header + jpeg[:5], jpeg[5:]])

        self.assertEqual(device.screenshot(), jpeg)

    def test_body_split_into_small_chunks(self):
        jpeg = b"\xff\xd8many-small-jpeg-chunks\x00\x01\xff\xd9"
        header = b"0;;image/jpeg;;%d\r\n" % len(jpeg)
        device = make_device([header] + [bytes([byte]) for byte in jpeg])

        self.assertEqual(device.screenshot(), jpeg)

    def test_server_error_raises_runtime_error(self):
        device = make_device([b"-1;;Unable to capture screenshot\r\n"])

        with self.assertRaisesRegex(RuntimeError, "Unable to capture screenshot"):
            device.screenshot()

    def test_connection_closed_before_complete_body(self):
        jpeg = b"\xff\xd8truncated"
        header = b"0;;image/jpeg;;%d\r\n" % (len(jpeg) + 10)
        device = make_device([header + jpeg])

        with self.assertRaisesRegex(ConnectionError, "screenshot bytes"):
            device.screenshot()

    def test_next_response_is_preserved(self):
        jpeg = b"\xff\xd8persistent\xff\xd9"
        header = b"0;;image/jpeg;;%d\r\n" % len(jpeg)
        next_response = b"0;;1170;;2532\r\n"
        device = make_device([header + jpeg + next_response])

        self.assertEqual(device.screenshot(), jpeg)
        self.assertEqual(device.get_screen_size(), (True, {"width": "1170", "height": "2532"}))
        self.assertEqual(
            device.s.sent,
            [
                datahandler.format_socket_data(tasktypes.TASK_SCREENSHOT),
                datahandler.format_socket_data(
                    tasktypes.TASK_GET_DEVICE_INFO,
                    1,
                ),
            ],
        )


if __name__ == "__main__":
    unittest.main()
