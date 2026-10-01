# SPDX-License-Identifier: GPL-2.0-only
"""Real socket tests for the drop-in client; native device behavior is separate."""
import ast
from pathlib import Path
import socketserver
import sys
import threading
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'layout/usr/share/trollvnc/python'))
from zxtouch.client import zxtouch
from zxtouch import kbdtasktypes, toasttypes


class Peer(socketserver.BaseRequestHandler):
    def handle(self):
        pending = bytearray()
        while True:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            pending.extend(chunk)
            while b'\r\n' in pending:
                line, rest = pending.split(b'\r\n', 1)
                pending[:] = rest
                task, payload = int(line[:2]), line[2:].decode()
                self.server.requests.append((task, payload))
                if task == 10:
                    continue
                if task == 30:
                    # Deliberately fragment both the header and binary delimiter.
                    for part in (b'0;;image/jpeg;;6\r', b'\n\xff\xd8\r', b'\n\xff\xd9'):
                        self.request.sendall(part)
                    continue
                fields = []
                if task == 14 or task == 15:
                    response = b'-1;;Touch recording is excluded\r\n'
                else:
                    if task == 21:
                        fields = ['10', '20', '30', '40']
                    elif task == 23:
                        fields = ['11', '22', '33']
                    elif task == 28:
                        fields = ['10', '20', '11', '22', '33']
                    elif task == 29:
                        fields = ['input text']
                    elif task == 24:
                        sub, *values = payload.split(';;')
                        if sub == '7':
                            self.server.clipboard = values[0]
                        elif sub == '6':
                            fields = [self.server.clipboard]
                    elif task == 25:
                        fields = {'1': ['1170', '2532'], '2': ['1'], '3': ['3'],
                                  '30': ['phone', 'iOS', '16.5', 'iPhone', 'UUID'], '31': ['2', '52.5']}[payload]
                    elif task == 27:
                        fields = ['en-US', 'zh-Hans'] if payload.startswith('2;;') else ['hello,,1,,2,,3,,4']
                    response = ('0' + ((';;' + ';;'.join(fields)) if fields else '') + '\r\n').encode()
                self.request.sendall(response)


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.server = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Peer)
        self.server.requests = []
        self.server.clipboard = ''
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.client = zxtouch('127.0.0.1', port=self.server.server_address[1])

    def tearDown(self):
        self.client.disconnect()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_all_public_commands_and_shapes(self):
        c = self.client
        for result in (c.switch_to_app('com.example.app'), c.show_alert_box('t', 'm', 1),
                       c.run_shell_command('case x in x) printf hello;; esac'), c.accurate_usleep(1),
                       c.play_script('/tmp/example.py'), c.force_stop_script_play(),
                       c.show_toast(3, 'message', 1), c.show_keyboard(), c.hide_keyboard(),
                       c.paste_from_clipboard(), c.move_cursor(-1)):
            self.assertTrue(result[0])
        self.assertEqual(c.prompt_input(), (True, 'input text'))
        self.assertEqual(c.image_match('/tmp/template.png'), (True, dict(x='10', y='20', width='30', height='40')))
        self.assertEqual(c.pick_color(1, 2), (True, dict(red='11', green='22', blue='33')))
        self.assertEqual(c.search_color((0, 0, 0, 0), 0, 255, 0, 255, 0, 255)[1]['x'], '10')
        self.assertEqual(c.get_screen_size(), (True, dict(width='1170', height='2532')))
        self.assertEqual(c.get_screen_orientation(), (True, '1'))
        self.assertEqual(c.get_screen_scale(), (True, '3'))
        self.assertEqual(c.get_device_info()[1]['system_version'], '16.5')
        self.assertEqual(c.get_battery_info()[1]['battery_level'], '52')
        self.assertEqual(c.ocr((0, 0, 0, 0)), (True, [dict(text='hello', x='1', y='2', width='3', height='4')]))
        self.assertEqual(c.get_supported_ocr_languages(0), (True, ['en-US', 'zh-Hans']))
        self.assertFalse(c.start_touch_recording()[0])
        self.assertFalse(c.stop_touch_recording()[0])

    def test_touch_text_and_binary_framing(self):
        c = self.client
        c.touch_with_list([dict(type=1, finger_index=0, x=12.3, y=45.6)])
        self.assertEqual(c.screenshot(), b'\xff\xd8\r\n\xff\xd9')
        self.assertEqual(c.get_screen_scale(), (True, '3'))
        self.assertIn((10, '11000012300456'), self.server.requests)
        self.assertTrue(c.set_clipboard_text('中文\nline\n')[0])
        self.assertEqual(c.get_text_from_clipboard(), (True, '中文\nline\n'))
        self.assertTrue(c.insert_text('中\nb\b')[0])
        self.assertIn((24, '1;;\n'), self.server.requests)
        self.assertIn((24, '4;;1'), self.server.requests)
        self.assertEqual(kbdtasktypes.KEYBOARD_GET_TEXT_FROM_CLIPBOARD, 6)
        self.assertEqual(toasttypes.TOAST_BUTTOM, 1)

    def test_reserved_delimiters_rejected_before_sending(self):
        for value in ('a\r\n251', 'a;;b', 'a\0b'):
            with self.assertRaises(ValueError):
                self.client.set_clipboard_text(value)
        self.assertEqual(self.client.get_screen_scale(), (True, '3'))

    def test_upstream_public_method_names_preserved(self):
        source = ROOT.parent / 'zxtouchrootless/layout/usr/share/zxtouch/python/zxtouch/client.py'
        if not source.exists():
            self.skipTest('Adjacent upstream client is absent')
        tree = ast.parse(source.read_text())
        methods = {node.name for node in ast.walk(tree) if isinstance(node, ast.FunctionDef) and not node.name.startswith('_')}
        self.assertTrue(methods <= set(dir(zxtouch)), methods - set(dir(zxtouch)))


if __name__ == '__main__':
    unittest.main()
