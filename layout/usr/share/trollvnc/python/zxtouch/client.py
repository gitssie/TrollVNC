# SPDX-License-Identifier: GPL-2.0-only
"""Independent ZXTouch-compatible client for TrollVNC, including binary captures."""
import os
import socket
import threading
from .datahandler import format_socket_data, decode_socket_data


class zxtouch:
    def __init__(self, ip, port=None):
        self.s = socket.create_connection((str(ip), int(port or os.environ.get('ZXTOUCH_PORT', 6000))))
        self._recv_buffer = bytearray()
        self._lock = threading.RLock()

    def _recv_line(self):
        while True:
            end = self._recv_buffer.find(b'\r\n')
            if end >= 0:
                result = bytes(self._recv_buffer[:end + 2])
                del self._recv_buffer[:end + 2]
                return result
            if len(self._recv_buffer) > 1024 * 1024:
                raise RuntimeError('ZXTouch response header exceeds 1 MiB')
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError('ZXTouch connection closed')
            self._recv_buffer.extend(chunk)

    def _recv_exact(self, size):
        if size < 0:
            raise ValueError('Negative response length')
        while len(self._recv_buffer) < size:
            chunk = self.s.recv(min(65536, size - len(self._recv_buffer)))
            if not chunk:
                raise ConnectionError('ZXTouch binary response was truncated')
            self._recv_buffer.extend(chunk)
        result = bytes(self._recv_buffer[:size])
        del self._recv_buffer[:size]
        return result

    def _recv_response(self):
        return decode_socket_data(self._recv_line())

    def _command(self, task, *args):
        with self._lock:
            self.s.sendall(format_socket_data(task, *args))
            return self._recv_response()

    def _mapped(self, keys, task, *args):
        ok, value = self._command(task, *args)
        if not ok:
            return False, value
        if len(value) != len(keys):
            raise RuntimeError('Malformed ZXTouch response')
        return True, dict(zip(keys, value))

    def _scalar(self, task, *args):
        ok, value = self._command(task, *args)
        return (True, value[0] if value else '') if ok else (False, value)

    def screenshot(self):
        with self._lock:
            self.s.sendall(format_socket_data(30))
            ok, fields = self._recv_response()
            if not ok:
                raise RuntimeError(fields)
            if len(fields) != 2 or fields[0] != 'image/jpeg':
                raise RuntimeError('Malformed screenshot header')
            size = int(fields[1])
            if not 0 < size <= 128 * 1024 * 1024:
                raise RuntimeError('Invalid screenshot length')
            return self._recv_exact(size)

    def touch(self, type, finger_index, x, y):
        self.touch_with_list([dict(type=type, finger_index=finger_index, x=x, y=y)])

    def touch_with_list(self, touch_list):
        if not 1 <= len(touch_list) <= 9:
            raise ValueError('Send between 1 and 9 touches per command')
        records = []
        for touch in touch_list:
            phase, finger = int(touch['type']), int(touch['finger_index'])
            x, y = int(touch['x'] * 10), int(touch['y'] * 10)
            if phase not in (0, 1, 2) or not 0 <= finger <= 19 or not 0 <= x <= 99999 or not 0 <= y <= 99999:
                raise ValueError('Invalid touch record')
            records.append('%d%02d%05d%05d' % (phase, finger, x, y))
        with self._lock:
            self.s.sendall(format_socket_data(10, str(len(records)) + ''.join(records)))

    def switch_to_app(self, bundle_identifier):
        return self._command(11, bundle_identifier)

    def show_alert_box(self, title, content, duration):
        return self._command(12, title, content, duration)

    def run_shell_command(self, command):
        """Run as the TrollVNC service user (mobile), with output in its log."""
        return self._command(13, command)

    def prompt_input(self, title='ZXTouch', message='', placeholder='', default_value=''):
        return self._scalar(29, title, message, placeholder, default_value)

    def start_touch_recording(self):
        return self._command(14)

    def stop_touch_recording(self):
        return self._command(15)

    def accurate_usleep(self, microseconds):
        return self._command(18, microseconds)

    def play_script(self, script_absolute_path):
        return self._command(19, script_absolute_path)

    def force_stop_script_play(self):
        return self._command(20)

    def image_match(self, template_path, acceptable_value=.8, max_try_times=2, scaleRation=.8):
        return self._mapped(('x', 'y', 'width', 'height'), 21, template_path, max_try_times, acceptable_value, scaleRation)

    def show_toast(self, toast_type, content, duration, position=0, fontSize=0):
        return self._command(22, toast_type, content, duration, position, fontSize)

    def pick_color(self, x, y):
        return self._mapped(('red', 'green', 'blue'), 23, x, y)

    def search_color(self, region, red_min, red_max, green_min, green_max, blue_min, blue_max, pixel_to_skip=0):
        if len(region) != 4:
            raise ValueError('Region must contain x, y, width, height')
        return self._mapped(('x', 'y', 'red', 'green', 'blue'), 28, 1, *region, red_min, red_max, green_min, green_max, blue_min, blue_max, pixel_to_skip)

    def show_keyboard(self):
        return self._command(24, 2, 2)

    def hide_keyboard(self):
        return self._command(24, 2, 1)

    def paste_from_clipboard(self):
        return self._command(24, 5)

    def get_text_from_clipboard(self):
        return self._scalar(24, 6)

    def set_clipboard_text(self, text):
        return self._command(24, 7, text)

    def insert_text(self, text):
        with self._lock:
            for character in text:
                result = self._command(24, 4, 1) if character == '\b' else self._command(24, 1, character)
                if not result[0]:
                    return result
        return True, ''

    def move_cursor(self, offset):
        return self._command(24, 3, offset)

    def get_screen_size(self):
        return self._mapped(('width', 'height'), 25, 1)

    def get_screen_orientation(self):
        return self._scalar(25, 2)

    def get_screen_scale(self):
        return self._scalar(25, 3)

    def get_device_info(self):
        return self._mapped(('name', 'system_name', 'system_version', 'model', 'identifier_for_vendor'), 25, 30)

    def get_battery_info(self):
        ok, value = self._mapped(('battery_state', 'battery_level'), 25, 31)
        if ok:
            value['battery_level'] = str(int(float(value['battery_level'])))
            value['battery_state_string'] = ('Unknown', 'Unplugged', 'Charging', 'Full')[int(value['battery_state'])]
        return ok, value

    def ocr(self, region, custom_words=(), minimum_height='', recognition_level=0, languages=(), auto_correct=0, debug_image_path=''):
        if len(region) != 4:
            raise ValueError('Region must contain x, y, width, height')
        ok, rows = self._command(27, 1, ',,'.join(map(str, region)), ',,'.join(map(str, custom_words)), minimum_height,
                                 recognition_level, ',,'.join(map(str, languages)), auto_correct, debug_image_path)
        if not ok:
            return False, rows
        return True, [dict(zip(('text', 'x', 'y', 'width', 'height'), row.split(',,'))) for row in rows if row]

    def get_supported_ocr_languages(self, recognition_level):
        return self._command(27, 2, recognition_level)

    def disconnect(self):
        self.s.close()
