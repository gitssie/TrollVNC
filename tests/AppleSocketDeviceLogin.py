"""Explicit native phone login test; credentials and codes entered privately on stdin.

Retrieve verification codes separately with curl, then supply them at the prompt.
This script never retrieves or polls for codes. No credential files, environment
or retries of native mutations. Keep operation IDs if execution is interrupted.
"""
import argparse
import getpass
import json
import socket
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'layout/usr/share/trollvnc/python'))
from zxtouch.client import zxtouch


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', type=int, default=6000)
    parser.add_argument('--apple-id', required=True)
    parser.add_argument('--enable-icloud', action='store_true')
    parser.add_argument('--resume-operation', help='Resume an existing signInAppStore operation; never resubmit it')
    args = parser.parse_args()
    password = getpass.getpass('Apple ID password: ')
    passcode = getpass.getpass('Device passcode: ') if args.enable_icloud else None
    socket.setdefaulttimeout(15)
    device = zxtouch(args.host, args.port)

    def operation(method, params):
        op = ({'operation_id': args.resume_operation}
              if args.resume_operation and method == 'signInAppStore' else device.apple.invoke(method, params))
        identifier = op['operation_id']
        print(method, 'operation', identifier, flush=True)
        state = device.apple.wait(identifier, timeout=600, interval=1)
        if state['status'] == 'requires_verification_code':
            print('Native trusted-device code challenge received', flush=True)
            challenge = state['challenge']
            code = getpass.getpass('Externally retrieved six-digit verification code: ')
            if len(code) != 6 or any(character not in '0123456789' for character in code):
                raise RuntimeError('Expected six ASCII digits; native mutation is not replayed')
            device.apple.submit_code(identifier, challenge['challenge_id'], code)
            code = None
            state = device.apple.wait(identifier, timeout=600, interval=1)
        result = state.get('result', {})
        print(json.dumps({'method': method, 'status': state.get('status'), 'error': state.get('error'),
                          'outcome': result.get('outcome'), 'already_enabled': result.get('already_enabled'),
                          'signed_in_domains': result.get('signed_in_domains')}, ensure_ascii=False), flush=True)
        if state.get('error') or result.get('outcome') != 'succeeded':
            raise RuntimeError('Native operation not verified; do not automatically retry')
        return result

    try:
        operation('signInAppStore', {'apple_id': args.apple_id, 'password': password})
        if args.enable_icloud:
            operation('enableICloud', {'apple_id': args.apple_id, 'password': password, 'device_passcode': passcode})
        op = device.apple.invoke('queryState')
        print('final queryState operation', op['operation_id'], flush=True)
        state = device.apple.wait(op['operation_id'], timeout=600, interval=1)
        result = state.get('result', {})
        summary = {key: result.get(key, {}).get('status') for key in ('app_store', 'icloud', 'identity')}
        summary['find_my_enabled'] = result.get('icloud', {}).get('find_my_enabled')
        summary['profile_sections'] = {key: value.get('status') for key, value in result.get('apple_settings', {}).items() if isinstance(value, dict)}
        summary['error'] = state.get('error')
        print(json.dumps(summary), flush=True)
        assert not state.get('error') and summary['app_store'] == 'signed_in'
        assert result['app_store']['account']['apple_id'].lower() == args.apple_id.lower()
        if args.enable_icloud:
            assert summary['icloud'] == summary['identity'] == 'signed_in' and summary['find_my_enabled'] is False
            for domain in ('icloud', 'identity'):
                assert result[domain]['account']['apple_id'].lower() == args.apple_id.lower()
        print('Fresh native account-domain verification PASS', flush=True)
    finally:
        password = passcode = None
        device.disconnect()


if __name__ == '__main__':
    main()
