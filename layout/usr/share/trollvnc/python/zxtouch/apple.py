"""Apple task 31 client. No credential storage or verification-code fetching."""
import base64
import json
import time


class AppleServiceError(RuntimeError):
    def __init__(self, error):
        self.error = error
        super().__init__("Apple service request failed: " + str(error.get("code", "unknown")))


class AppleClient:
    def __init__(self, device):
        self._device = device

    def _request(self, request):
        data = json.dumps(request, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(data) > 675000:
            raise ValueError('Apple request is too large')
        ok, fields = self._device._command(31, base64.b64encode(data).decode('ascii'))
        if not ok:
            raise AppleServiceError({'code': 'transport_error'})
        try:
            if len(fields) != 1:
                raise ValueError()
            result = json.loads(base64.b64decode(fields[0], validate=True))
            if not isinstance(result, dict):
                raise ValueError()
        except (ValueError, TypeError) as exc:
            raise RuntimeError('Malformed Apple service response') from exc
        if 'error' in result and 'operation_id' not in result:
            raise AppleServiceError(result['error'])
        return result

    def invoke(self, method, params=None):
        return self._request({'action': 'invoke', 'method': method, 'params': {} if params is None else params})

    def result(self, operation_id):
        return self._request({'action': 'result', 'operation_id': operation_id})

    def submit_code(self, operation_id, challenge_id, code):
        return self._request({'action': 'submit_code', 'operation_id': operation_id, 'challenge_id': challenge_id, 'code': code})

    def cancel_challenge(self, operation_id, challenge_id):
        return self._request({'action': 'cancel_challenge', 'operation_id': operation_id, 'challenge_id': challenge_id})

    def wait(self, operation_id, timeout=600, interval=.5):
        """Return at completion or a code challenge. Timeout never cancels/replays."""
        if timeout <= 0 or interval <= 0:
            raise ValueError('Timeout and interval must be positive')
        deadline = time.monotonic() + timeout
        while True:
            state = self.result(operation_id)
            if state.get('status') in ('completed', 'requires_verification_code'):
                return state
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Apple operation is still running; retain its operation_id')
            time.sleep(min(interval, remaining))
