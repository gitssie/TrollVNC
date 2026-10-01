# SPDX-License-Identifier: GPL-2.0-only
def format_socket_data(task_type, *datas):
    fields = [str(value) for value in datas]
    if any('\r\n' in value or '\0' in value or (';;' in value and task_type not in (13, 19)) for value in fields):
        raise ValueError('ZXTouch fields cannot contain CRLF, NUL or ;;')
    return ('%02d' % task_type + ';;'.join(fields) + '\r\n').encode('utf-8')


def decode_socket_data(data):
    fields = (data[:-2] if data.endswith(b'\r\n') else data).decode('utf-8').split(';;')
    return (True, fields[1:]) if fields[0] == '0' else (False, fields[1] if len(fields) > 1 else 'ZXTouch command failed')
