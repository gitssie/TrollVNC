#!/usr/bin/env python3
"""Retained USB device test of the production HTTP/2 engine and Karing proxy.
Uses an isolated loopback probe (not the production VNC authorization facade).
Requires USB SSH on 2222, curl with HTTP2 and the local Karing config from discovery.
No account writes. Tokens/secrets travel only through stdin or private curl configs.
"""
import argparse, json, os, secrets, select, shlex, socket, subprocess, sys, tempfile, time
from pathlib import Path
MODULE = Path(__file__).resolve().parents[1]
SSH = ["ssh", "-p2222", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes"]
TARGET = "mobile@127.0.0.1"

def checked(args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)

def curl(origin, path, config, directory, method="GET", data=None, timeout=10, h2=True):
    output = directory / "response.bin"
    header = directory / "response.headers"
    args = ["curl", "--http2-prior-knowledge" if h2 else "--http1.1", "--noproxy", "*", "--silent", "--show-error",
            "--max-time", str(timeout), "--config", str(config), "--request", method,
            "--output", str(output), "--dump-header", str(header),
            "--write-out", "%{http_code} %{http_version}", origin + path]
    if data is not None: args += ["--data-binary", "@-"]
    result = subprocess.run(args, input=data, capture_output=True)
    if result.returncode not in (0, 28): raise RuntimeError(f"curl failed: {result.returncode}")
    status, version = result.stdout.decode().split()
    return int(status), version, output.read_bytes(), header.read_text(), result.returncode

def private(path, text):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as stream: stream.write(text)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=Path.home()/".config/cazer/karing.json")
    parser.add_argument("--report", type=Path, default=MODULE/"tests/reports/device-http2.json")
    parser.add_argument("--sudo-password-stdin", action="store_true", help="Read mobile sudo password from stdin; never record it")
    args = parser.parse_args()
    sudo_password = sys.stdin.buffer.readline() if args.sudo_password_stdin else None
    config = json.loads(args.config.read_text())
    with tempfile.TemporaryDirectory(prefix="tvnc-http2-") as temp:
        directory = Path(temp); binary = directory/"probe"
        checked(["sh", str(MODULE/"tests/build-probe.sh"), str(binary)])
        remote = f"/usr/bin/tvnc-http2-probe-{os.getpid()}"
        staging = f"/tmp/tvnc-http2-stage-{os.getpid()}"
        checked(["scp", "-P2222", "-oBatchMode=yes", "-oStrictHostKeyChecking=yes", str(binary), TARGET+":"+staging])
        sudo = "sudo -S -p '' " if sudo_password is not None else "sudo -n "
        try:
            checked(SSH+[TARGET, sudo+"cp -f "+shlex.quote(staging)+" "+shlex.quote(remote)], input=sudo_password, stdout=subprocess.DEVNULL)
            native = checked(SSH+[TARGET, "jbroot "+shlex.quote(remote)], capture_output=True, text=True).stdout.strip()
            checked(SSH+[TARGET, sudo+"/basebin/jbctl trustcache add "+shlex.quote(native)], input=sudo_password, stdout=subprocess.DEVNULL)
        except Exception:
            checked(SSH+[TARGET, "rm -f "+staging], stdout=subprocess.DEVNULL)
            checked(SSH+[TARGET, sudo+"rm -f "+remote], input=sudo_password, stdout=subprocess.DEVNULL)
            raise
        token = secrets.token_hex(32)
        private(directory/"proxy.conf", 'header = "Authorization: Bearer '+token+'"\n')
        private(directory/"direct.conf", 'header = "Authorization: Bearer '+config["secret"]+'"\n')
        private(directory/"none.conf", "")
        device = subprocess.Popen(SSH+[TARGET, "exec "+remote], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        tunnel = None
        probe_pid = None
        try:
            probe_port = 40000 + secrets.randbelow(10000)
            device.stdin.write(json.dumps({"token":token,"port":probe_port}).encode()); device.stdin.close()
            if not select.select([device.stdout], [], [], 10)[0]: raise RuntimeError("device probe did not start")
            ready = device.stdout.readline().decode().strip()
            if not ready.startswith(f"READY HTTP/2 {probe_port} "):
                error = device.stderr.read().decode(errors="replace").replace(token, "<token>").replace(config["secret"], "<secret>")
                raise RuntimeError(f"device probe startup failed (ssh exit {device.wait()}): "+error)
            probe_pid = int(ready.split()[-1])
            tunnel = subprocess.Popen(SSH+["-N", "-T", "-oExitOnForwardFailure=yes", "-L", f"127.0.0.1:13057:127.0.0.1:{probe_port}", TARGET], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            deadline = time.monotonic()+5
            while True:
                try:
                    with socket.create_connection(("127.0.0.1",13057), timeout=.2): break
                except OSError:
                    if time.monotonic()>deadline: raise RuntimeError("probe tunnel did not start")
                    time.sleep(.05)
            origin = "http://127.0.0.1:13057"; rows=[]
            for path in ["/version", "/configs", "/proxies", "/rules", "/providers/proxies", "/proxies/GLOBAL", "/future-not-supported"]:
                expected, _, direct, _, _ = curl(config["baseURL"], path, directory/"direct.conf", directory, h2=False)
                status, version, body, _, _ = curl(origin, "/api/karing"+path, directory/"proxy.conf", directory)
                assert version == "2" and status == expected, f"{path}: expected={expected}, proxy={status}, HTTP={version}, body={body[:200]!r}"
                try: equal = json.loads(body) == json.loads(direct)
                except ValueError: equal = body == direct
                assert equal, f"raw response mismatch: {path}"
                rows.append({"method":"GET", "path":path, "status":status, "httpVersion":version, "body":body.decode(errors="replace"), "matchesDirect":True})
            status, version, body, _, _ = curl(origin, "/api/karing/dns/query?name=example.com&type=A", directory/"proxy.conf", directory)
            value=json.loads(body); assert status == 200 and version == "2" and "Answer" in value
            rows.append({"method":"GET", "path":"/dns/query?name=example.com&type=A", "status":status, "httpVersion":version, "body":value})
            status, version, body, _, code = curl(origin, "/api/karing/traffic", directory/"proxy.conf", directory, timeout=2)
            lines=[json.loads(line) for line in body.splitlines() if line]
            assert status == 200 and version == "2" and code == 28 and len(lines)>=1 and "up" in lines[0]
            rows.append({"path":"/traffic", "status":status, "httpVersion":version, "samples":lines, "cancelled":True})
            status, version, _, _, _ = curl(origin, "/api/karing/version", directory/"none.conf", directory)
            assert status == 401 and version == "2"
            rows.append({"path":"/version", "withoutControlToken":True, "status":status})
            raw=b'{"future":{"nested":[null,"a;;b\\r\\n"]}}'
            status, version, body, _, _ = curl(origin, "/api/device/probe-echo", directory/"proxy.conf", directory, "POST", raw)
            assert status == 200 and version == "2" and body == raw
            rows.append({"path":"/api/device/probe-echo", "status":status, "rawBytesPreserved":True})
            report={"transport":"HTTP/2 h2c on iOS -> local Karing HTTP/1.1", "scope":"isolated production-engine probe; production VNC/native facade not deployed", "passed":len(rows), "results":rows}
            rendered=json.dumps(report, ensure_ascii=False, indent=2)
            assert token not in rendered and config["secret"] not in rendered
            args.report.parent.mkdir(parents=True, exist_ok=True); args.report.write_text(rendered+"\n")
            print(f"HTTP/2 device integration: {len(rows)} PASS; report: {args.report}")
        finally:
            if tunnel is not None:
                tunnel.terminate()
                try: tunnel.wait(timeout=5)
                except subprocess.TimeoutExpired: tunnel.kill(); tunnel.wait()
            if probe_pid is not None:
                checked(SSH+[TARGET, f"kill -TERM {probe_pid}"], stdout=subprocess.DEVNULL)
            device.terminate()
            try: device.wait(timeout=5)
            except subprocess.TimeoutExpired: device.kill(); device.wait()
            checked(SSH+[TARGET, "rm -f "+staging], stdout=subprocess.DEVNULL)
            checked(SSH+[TARGET, sudo+"rm -f "+remote], input=sudo_password, stdout=subprocess.DEVNULL)
if __name__ == "__main__": main()
