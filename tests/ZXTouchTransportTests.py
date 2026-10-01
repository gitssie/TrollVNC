import socket
import time
import subprocess
import sys
from pathlib import Path
import unittest


class TransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            cls.port = probe.getsockname()[1]
        cls.server = subprocess.Popen([sys.argv[1], str(cls.port)], stdout=subprocess.PIPE)
        assert cls.server.stdout.readline() == b"ready\n"

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        cls.server.wait(timeout=5)
        cls.server.stdout.close()

    def connect(self, host="127.0.0.1"):
        return socket.create_connection((host, self.port), timeout=3)

    def test_fragmented_and_pipelined_commands(self):
        with self.connect() as connection:
            stream = connection.makefile("rb")
            for part in (b"25", b"1\r", b"\n253\r\n"):
                connection.sendall(part)
            self.assertEqual(stream.readline(), b"0;;1\r\n")
            self.assertEqual(stream.readline(), b"0;;3\r\n")
            stream.close()

    def test_touch_has_no_reply_before_next_command(self):
        with self.connect() as connection:
            connection.sendall(b"1011030123405678\r\n251\r\n")
            self.assertEqual(connection.recv(1024), b"0;;1\r\n")

    def test_screenshot_preserves_binary_and_next_response(self):
        with self.connect() as connection:
            stream = connection.makefile("rb")
            connection.sendall(b"30\r\n251\r\n")
            self.assertEqual(stream.readline(), b"0;;image/jpeg;;6\r\n")
            self.assertEqual(stream.read(6), b"\xff\xd8\r\n\xff\xd9")
            self.assertEqual(stream.readline(), b"0;;1\r\n")
            stream.close()

    def test_excluded_commands_return_error(self):
        with self.connect() as connection:
            stream = connection.makefile("rb")
            for task in (14, 15):
                connection.sendall(f"{task}\r\n".encode())
                self.assertTrue(stream.readline().startswith(b"-1;;"))
            stream.close()

    def test_pipelined_disconnect_cancels_busy_handler(self):
        connection = self.connect()
        connection.sendall(b"97\r\n")
        time.sleep(.05)  # Let the handler start before queuing another command.
        connection.sendall(b"251\r\n")
        connection.shutdown(socket.SHUT_WR)
        with self.connect() as probe:
            stream = probe.makefile("rb")
            for _ in range(100):
                probe.sendall(b"96\r\n")
                if stream.readline() == b"0;;1\r\n":
                    break
                time.sleep(.01)
            else:
                self.fail("EOF remained hidden behind queued command bytes")
            stream.close()
        connection.close()

    def test_bare_newline_text_is_preserved(self):
        with self.connect() as connection:
            connection.sendall(b"241;;line\nnext\r\n")
            self.assertEqual(connection.recv(1024), b"0;;1;;line\nnext\r\n")

    def test_invalid_touch_closes_without_stray_response(self):
        with self.connect() as connection:
            connection.sendall(b"1011990000100001\r\n")
            self.assertEqual(connection.recv(1024), b"")

    def test_ipv6_and_multiple_clients(self):
        with self.connect("::1") as first, self.connect() as second:
            first.sendall(b"251\r\n")
            second.sendall(b"253\r\n")
            self.assertEqual(first.recv(1024), b"0;;1\r\n")
            self.assertEqual(second.recv(1024), b"0;;3\r\n")

    def test_original_python_client_screenshot(self):
        upstream = Path(__file__).resolve().parents[2] / "zxtouchrootless/layout/usr/share/zxtouch/python"
        if not upstream.exists():
            self.skipTest("Adjacent ZXTouch Python client is not available")
        sys.path.insert(0, str(upstream))
        try:
            from zxtouch.client import zxtouch
            # Keep the real client methods; only bypass its fixed-port constructor.
            client = zxtouch.__new__(zxtouch)
            client.s = self.connect()
            client._recv_buffer = bytearray()
            try:
                self.assertEqual(client.screenshot(), b"\xff\xd8\r\n\xff\xd9")
                self.assertFalse(client.start_touch_recording()[0])
            finally:
                client.disconnect()
        finally:
            sys.path.pop(0)

    def test_z_stop_closes_existing_connections(self):
        with self.connect() as connection, self.connect() as idle:
            connection.sendall(b"98\r\n")
            self.assertEqual(connection.recv(1024), b"0\r\n")
            self.assertEqual(idle.recv(1024), b"")
            self.assertEqual(connection.recv(1024), b"")
        self.server.wait(timeout=3)

    def test_oversized_command_closes(self):
        with self.connect() as connection:
            try:
                connection.sendall(b"25" + b"x" * (1024 * 1024 + 8))
                self.assertEqual(connection.recv(1024), b"")
            except (ConnectionResetError, BrokenPipeError):
                pass


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]])
