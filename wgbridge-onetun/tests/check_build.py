#!/usr/bin/env python3
"""Retained Rust bridge checks: encrypted local integration tests and iOS build.

Uses local UDP WireGuard peers and loopback TCP services, without a system TUN,
VPN, route changes or phone installation.
"""
import argparse
import datetime
import json
from pathlib import Path
import re
import subprocess


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path, default=root / 'tests/reports/build-readiness.json')
    args = parser.parse_args()
    rustc = subprocess.run(['rtk', 'proxy', 'rustc', '-vV'], capture_output=True, text=True, check=True).stdout
    host = next(line.removeprefix('host: ') for line in rustc.splitlines() if line.startswith('host: '))
    checks = [
        ('iOS compile', ['cargo', 'check', '--locked', '--target', 'aarch64-apple-ios']),
        ('host encrypted forwarding and C ABI tests', ['cargo', 'test', '--locked', '--target', host]),
        ('device build script without arguments', ['sh', './build-ios.sh']),
    ]
    results = []
    for name, command in checks:
        try:
            run = subprocess.run(['rtk', 'proxy', *command], cwd=root, capture_output=True, text=True, timeout=300)
            output = run.stdout + run.stderr
            result = {'name': name, 'command': command, 'exit_code': run.returncode,
                      'status': 'PASS' if run.returncode == 0 else 'FAIL',
                      'compiler_errors': len(re.findall(r'^error\[E\d+\]', output, re.MULTILINE)),
                      'output': output}
        except subprocess.TimeoutExpired:
            result = {'name': name, 'command': command, 'status': 'FAIL', 'error': 'timeout after 300 seconds'}
        results.append(result)
        print(f"{result['status']} {name}: exit={result.get('exit_code', 'timeout')}; errors={result.get('compiler_errors', 0)}", flush=True)
    report = {'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'Local encrypted WireGuard forwarding and iOS compilation; no phone acceptance test',
              'toolchain': rustc, 'results': results, 'functional_tests_executed': results[1]['status'] == 'PASS'}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print('Report:', args.report)
    return int(any(result['status'] == 'FAIL' for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
