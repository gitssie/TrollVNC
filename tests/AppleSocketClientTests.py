import pathlib
import socket
import subprocess
import sys
import time
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'layout/usr/share/trollvnc/python'))
from zxtouch.client import zxtouch
from zxtouch.apple import AppleServiceError


class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            cls.port = sock.getsockname()[1]
        cls.host = subprocess.Popen([sys.argv[1], str(cls.port)], stdout=subprocess.PIPE, text=True)
        if cls.host.stdout.readline().strip() != 'READY':
            raise RuntimeError('Host did not start')

    @classmethod
    def tearDownClass(cls):
        cls.host.terminate()
        cls.host.wait(timeout=5)
        cls.host.stdout.close()

    def test_real_socket(self):
        device = zxtouch('127.0.0.1', self.port)
        try:
            op = device.apple.invoke('queryState')['operation_id']
            with self.assertRaises(AppleServiceError) as error:
                device.apple.invoke('queryState')
            self.assertEqual(error.exception.error['code'], 'busy')
            device.disconnect()
            device = zxtouch('127.0.0.1', self.port)
            state = device.apple.wait(op)
            self.assertEqual(state['result']['message'], '雪;;line\r\nnext')
            op = device.apple.invoke('signInAppStore', {'apple_id': 'example@example.com', 'password': 'secret;;\r\n雪'})['operation_id']
            state = device.apple.wait(op)
            self.assertEqual(state['status'], 'requires_verification_code')
            challenge = state['challenge']['challenge_id']
            with self.assertRaises(AppleServiceError):
                device.apple.submit_code(op, 'wrong', '012345')
            device.apple.submit_code(op, challenge, '012345')
            self.assertEqual(device.apple.wait(op)['result']['outcome'], 'succeeded')
            with self.assertRaises(AppleServiceError):
                device.apple.submit_code(op, challenge, '012345')
            op = device.apple.invoke('signInAppStore', {'apple_id': 'example@example.com', 'password': 'secret'})['operation_id']
            state = device.apple.wait(op)
            device.apple.cancel_challenge(op, state['challenge']['challenge_id'])
            self.assertIn('error', device.apple.wait(op))
            op = device.apple.invoke('queryState')['operation_id']
            with self.assertRaises(TimeoutError):
                device.apple.wait(op, timeout=.01, interval=.01)
            self.assertEqual(device.apple.wait(op)['status'], 'completed')
        finally:
            device.disconnect()

    def test_invalid_request(self):
        device = zxtouch('127.0.0.1', self.port)
        try:
            with self.assertRaises(AppleServiceError):
                device.apple.invoke('signOutAppleID', {'apple_id': 'example@example.com'})
            with self.assertRaises(AppleServiceError):
                device.apple.result('unknown')
            with self.assertRaises(ValueError):
                device.apple.invoke('queryState', {'x': float('nan')})
        finally:
            device.disconnect()


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0]])
