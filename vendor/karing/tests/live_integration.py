#!/usr/bin/env python3
"""Compile and exercise the real native Karing client/task34 over USB/SSH.

Secret stays in the local config/stdin. Reports retain normalized return values.
Default is read-only; --allow-writes allows reversible mode/selector tests and
connection deletion (which may interrupt phone traffic).
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=Path.home() / '.config/cazer/karing.json')
    parser.add_argument('--report', type=Path, default=Path('/tmp/karing-native-live-results.json'))
    parser.add_argument('--probe', type=Path)
    parser.add_argument('--allow-writes', action='store_true')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    results = []
    native = []

    def record(name, status, detail):
        results.append({'test': name, 'status': status, 'detail': detail})
        print(f'{status:5} {name}: {detail}', flush=True)

    def decoded(row):
        wire = row.get('wire', '')
        if wire.startswith('0;;'):
            try:
                return json.loads(wire[3:].strip())
            except ValueError:
                return None
        return None

    with tempfile.TemporaryDirectory(prefix='karing-live-') as folder:
        probe = args.probe or Path(folder) / 'probe'
        if not args.probe:
            subprocess.run(['bash', str(Path(__file__).with_name('build_probe.sh')), str(probe)], check=True)
        def call(task, expected=0, name=None):
            request = dict(config, tasks=[task])
            run = subprocess.run([str(probe)], input=json.dumps(request), text=True, capture_output=True,
                                 timeout=config.get('timeoutMs', 10000) / 1000 + 5, check=True)
            row = json.loads(run.stdout)[0]
            native.append(row)
            success = row['ok'] if expected == 0 else not row['ok'] and f'(code {expected})' in row.get('wire', '')
            if task.startswith('60') and not row['ok'] and '(code -6)' in row.get('wire', ''):
                record(name or task, 'SKIP', 'no live log record during bounded sample; no historical logs API')
            else:
                record(name or task, 'PASS' if success else 'FAIL', f'elapsed={round(row["elapsedMs"])}ms; expected code={expected}')
            return row, decoded(row)

        _, version = call('1', name='version')
        record('version return', 'PASS' if isinstance(version, dict) and isinstance(version.get('meta'), bool) else 'FAIL', 'version + boolean meta/premium')
        _, traffic = call('2', name='traffic first sample')
        record('traffic return', 'PASS' if isinstance(traffic, dict) and all(isinstance(traffic.get(k), int) for k in ['up', 'down']) else 'FAIL', 'up/down integers')
        _, configs = call('3', name='configs')
        _, proxies = call('10', name='proxies')
        if not isinstance(configs, dict) or not isinstance(proxies, dict):
            raise RuntimeError('Cannot discover current configuration')
        entries = proxies['proxies']
        groups = {k: v for k, v in entries.items() if v.get('all')}
        for name in groups:
            _, detail = call('11;;' + name, name='group ' + name)
            record('group return ' + name, 'PASS' if isinstance(detail, dict) and detail.get(name) == groups[name] else 'FAIL', 'normalized detail matches proxy list')
        current = next((v['now'] for v in groups.values() if v.get('now')), None)
        if current:
            _, delay = call('13;;' + current, name='delay with URL/timeout')
            record('delay return', 'PASS' if isinstance(delay, dict) and isinstance(delay.get('delay'), int) and delay['delay'] > 0 else 'FAIL', str(delay))
        _, connections = call('20', name='connections')
        record('connection return', 'PASS' if isinstance(connections, list) and all(all(k in x for k in ['id', 'network', 'source', 'destination', 'startTime', 'chains']) for x in connections) else 'FAIL', 'normalized connection array')
        _, rules = call('30', name='rules')
        record('rule return', 'PASS' if isinstance(rules, list) and bool(rules) and all(all(k in x for k in ['type', 'payload', 'proxy', 'hits']) for x in rules) else 'FAIL', 'normalized rule array')
        call('40', name='providers')
        call('41;;cazer-integration-missing', expected=-3, name='missing provider HTTP error')
        call('42;;missing;;node', expected=-8, name='unsupported provider node selection')
        call('43;;missing', expected=-8, name='unsupported provider healthcheck')
        _, dns = call('50;;example.com;;A', name='DNS A')
        record('DNS return', 'PASS' if isinstance(dns, dict) and dns.get('answers') and dns.get('ttl', 0) > 0 else 'FAIL', str(dns))
        call('60;;2', name='bounded log sample')
        call('4;;{}', expected=-8, name='unsupported config reload')
        modes = {str(x).lower() for x in configs.get('mode-list', [])}
        for mode in ['rule', 'global', 'direct']:
            if mode not in modes:
                call('80;;' + mode, expected=-8, name='unsupported mode ' + mode)
        for name, group in groups.items():
            if group['type'] != 'Selector':
                call('12;;' + name + ';;' + group['now'], expected=-8, name='read-only group switch ' + name)
                call('70;;' + name, expected=-8, name='read-only group failover ' + name)
        if args.allow_writes:
            original = configs['mode'].lower()
            try:
                for mode in sorted(modes & {'rule', 'global', 'direct'}):
                    call('80;;' + mode, name='set supported mode ' + mode)
            finally:
                call('80;;' + original, name='restore mode')
            selectors = {k: v for k, v in groups.items() if v['type'] == 'Selector'}
            if not selectors:
                record('selector switch/failover success', 'SKIP', 'device has no real Selector; mock-server regressions cover success')
            for name, group in selectors.items():
                alternative = next((x for x in group['all'] if x != group['now']), group['now'])
                try:
                    call('12;;' + name + ';;' + alternative, name='switch selector ' + name)
                finally:
                    call('12;;' + name + ';;' + group['now'], name='restore selector ' + name)
            _, active = call('20', name='connections before delete')
            if active:
                target = active[0]['id']
                call('22;;' + target, name='delete one connection')
                _, after = call('20', name='verify single deletion')
                record('single delete effect', 'PASS' if isinstance(after, list) and all(x['id'] != target for x in after) else 'FAIL', 'target ID absent')
            else:
                record('delete one active connection', 'SKIP', 'no active connection')
            call('21', name='delete all connections')
            call('20', name='query after close all')
            record('close-all effect', 'SKIP', 'background connections may immediately reopen; HTTP result is recorded')
        else:
            record('write success paths', 'SKIP', 'requires --allow-writes')
        _, final_config = call('3', name='final config')
        record('mode preserved', 'PASS' if final_config and final_config.get('mode') == configs.get('mode') else 'FAIL', 'initial and final modes match')
        _, final_proxies = call('10', name='final proxies')
        final_entries = final_proxies.get('proxies', {}) if final_proxies else {}
        record('selectors preserved', 'PASS' if all(final_entries.get(k, {}).get('now') == v.get('now') for k, v in groups.items() if v['type'] == 'Selector' or k == 'GLOBAL') else 'FAIL', 'manual/synthetic selections preserved; URLTest may auto-update')
    report = {'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'scope': 'Actual native Foundation HTTP + C++ client + Objective-C wrapper + task34 service over USB tunnel',
              'results': results, 'native_returns': native}
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if config['secret'] and config['secret'] in text:
        raise RuntimeError('Secret appeared in report; refusing to save')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(text + '\n')
    print('Report:', args.report)
    return 1 if any(x['status'] == 'FAIL' for x in results) else 0


if __name__ == '__main__':
    raise SystemExit(main())
