#!/usr/bin/env python3
"""Drive MCP with real Alpine guests, including cancellation and host isolation.

Requires zig build, Alpine integration assets, and Hypervisor.framework.
"""
import json
import os
import pathlib
import select
import signal
import shutil
import socket
import subprocess
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[3]
BIN = REPO / "zig-out/bin/bobrvm"
KERNEL = REPO / "tests/integration/alpine/out/Image"
INITRD = REPO / "tests/integration/alpine/out/initramfs-minimal"


class Client:
    def __init__(self, project, environ):
        self.process = subprocess.Popen(
            [BIN, "mcp"], cwd=project, env=environ, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        self.buffer = b""
        self.next_id = 1

    def send(self, method, params=None, request_id=None):
        message = {"jsonrpc": "2.0", "method": method}
        if request_id is not None:
            message["id"] = request_id
        if params is not None:
            message["params"] = params
        data = (json.dumps(message) + "\n").encode()
        while data:
            count = self.process.stdin.write(data)
            data = data[count:]

    def receive(self, timeout=10):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                raise TimeoutError("MCP response deadline exceeded")
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError(f"MCP closed: {self.process.stderr.read().decode()}")
            self.buffer += data
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def rpc(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        self.send(method, params, request_id)
        response = self.receive(35)
        assert response["id"] == request_id, response
        return response

    def tool(self, name, arguments=None):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})["result"]
        return result.get("isError", False), result["content"][0]["text"]

    def execute(self, sandbox, command, timeout_ms=3000):
        return self.tool("sandbox_exec", {
            "id": sandbox, "command": command, "timeout_ms": timeout_ms,
        })

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=10)
        assert self.process.returncode == 0, self.process.stderr.read().decode()
        self.process.stdout.close()
        self.process.stderr.close()


def check(condition, label, detail=""):
    assert condition, f"{label}: {detail}"
    print(f"PASS {label}" + (f" | {detail}" if detail else ""), flush=True)


def main():
    for asset in (BIN, KERNEL, INITRD):
        if not asset.exists():
            raise SystemExit(f"Missing required asset: {asset}")
    work = pathlib.Path(tempfile.mkdtemp(prefix="bobrvm-mcp."))
    project = work / "project"
    project.mkdir()
    client = None
    boot = None
    route = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # UDP connect selects an interface without sending any packets.
    route.connect(("192.0.2.1", 9))
    host_ip = route.getsockname()[0]
    route.close()
    listener = socket.socket()
    listener.bind((host_ip, 0))
    listener.listen()
    host_port = listener.getsockname()[1]
    env = dict(os.environ, XDG_CONFIG_HOME=str(work / "config"))
    provision = [
        "modprobe virtio_net; ip link set eth0 up; ip addr add 10.0.2.15/24 dev eth0; "
        "ip route add default via 10.0.2.2",
        "modprobe 9pnet_virtio; mkdir -p /host; "
        "mount -t 9p -o trans=virtio,version=9p2000.L,cache=none host /host",
    ]
    (project / "host-data").write_text("host original")
    (project / "bobrvm.toml").write_text(
        f'name = "mcp-test"\nmemory = 512\ncpus = 1\n'
        f'kernel = "{KERNEL}"\ninitrd = "{INITRD}"\nnet = true\n'
        f'provision = {json.dumps(provision)}\n'
    )
    try:
        with (work / "boot.log").open("wb") as boot_log:
            boot = subprocess.Popen(
                [BIN, "up"], cwd=project,
                env=dict(env, BOBRVM_TEST_SUSPEND=f"14:{project}/suspend.img"),
                stdin=subprocess.PIPE, stdout=boot_log, stderr=boot_log,
            )
            time.sleep(20)
            boot.stdin.close()
            boot.wait(timeout=30)
        state_dirs = list((work / "config/bobrvm/projects").glob("project-*"))
        check(len(state_dirs) == 1 and (project / "suspend.img").exists(),
              "warm boot", (work / "boot.log").read_text(errors="replace")[-1000:]
              if not (project / "suspend.img").exists() else "")
        (project / "suspend.img").rename(state_dirs[0] / "warm.img")
        forks = state_dirs[0] / "forks"
        # Warm memory may contain old shared data. New host content must never
        # become visible through restored fids or new requests in an MCP fork.
        (project / "host-data").write_text("host updated after snapshot")
        shared_read = subprocess.run(
            [BIN, "exec", "--", "cat", "/host/host-data"], cwd=project, env=env,
            capture_output=True, timeout=10,
        )
        check(shared_read.returncode == 0 and
              b"host updated after snapshot" in shared_read.stdout,
              "ordinary fork can read the mounted host folder",
              shared_read.stderr.decode(errors="replace")[-1000:])
        subprocess.run(
            [BIN, "exec", "--", "sh", "-c", f"nc -w 1 {host_ip} {host_port} </dev/null"],
            cwd=project, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10,
        )
        check(bool(select.select([listener], [], [], 1)[0]),
              "ordinary fork can reach the test host listener")
        connection, _ = listener.accept()
        connection.close()
        client = Client(project, env)
        check("result" in client.rpc("initialize"), "initialize")
        check(len(client.rpc("tools/list")["result"]["tools"]) == 5, "tool list")
        err, text = client.tool("sandbox_start")
        check(not err, "sandbox start", text)
        started = time.monotonic()
        err, text = client.execute(1, "echo hello-from-sandbox && uname -m")
        check(not err and "aarch64" in text, "command execution",
              f"{time.monotonic() - started:.3f}s")
        for command, code, expected in [
            ("exit 7", 7, ""),
            ("echo commented # trailing comment", 0, "commented"),
            ("printf '%s\\n' \\\"quoted\\\"\necho second-line", 0, "second-line"),
            ("cat; echo stdin-closed", 0, "stdin-closed"),
            ("exec echo replaced-shell", 0, "replaced-shell"),
            ("echo " + "x" * 763, 0, "x" * 763),
        ]:
            err, text = client.execute(1, command)
            check(err == (code != 0) and f"exit code {code}\n" in text and expected in text,
                  "shell script contract", text[:100])
        err, text = client.execute(1, "echo 'unterminated")
        check(err and "exit code 2" in text, "syntax error preserves completion", text)
        check(not client.execute(1, "true")[0], "shell survives script failures")
        check(client.execute(1, "x" * 769)[0], "oversized script rejected before execution")
        check(client.execute(1, "\n" * 300)[0], "encoded line limit enforced before execution")
        check(not client.execute(1, "true")[0], "oversized script preserves sandbox")
        err, text = client.execute(1, "cat /proc/mounts; ip link show eth0")
        check(not err and "eth0" in text, "warm network topology preserved")
        check(" /host 9p " in text, "warm 9p mount preserved", text)
        err, text = client.execute(1, "cat /host/host-data")
        check(err and "host updated after snapshot" not in text,
              "host reads denied", text)
        err, text = client.execute(1, "echo bad > /host/host-data")
        check(err, "host writes denied", text)
        check((project / "host-data").read_text() == "host updated after snapshot",
              "host file unchanged")
        err, text = client.execute(1, f"nc -w 1 {host_ip} {host_port} </dev/null")
        check(err and not select.select([listener], [], [], 0)[0],
              "guest cannot open host network connection", text)
        check(not client.execute(1, "echo private > /mark")[0], "private file write")
        check(not client.tool("sandbox_start")[0], "second sandbox")
        check(client.execute(2, "cat /mark")[0], "fork isolation")
        started = time.monotonic()
        err, text = client.execute(1, "sleep 60 & wait", timeout_ms=100)
        check(err and "sandbox stopped and deleted" in text, "timeout destroys sandbox", text)
        check(time.monotonic() - started < 5, "timeout has bounded shutdown")
        check(client.execute(1, "true")[0], "timed-out sandbox cannot run more work")
        check(not client.execute(2, "true")[0], "timeout preserves other sandbox")

        client.send("tools/call", {"name": "sandbox_exec", "arguments": {
            "id": 2, "command": "sleep 60 & wait", "timeout_ms": 60000,
        }}, "2")
        started = time.monotonic()
        check("result" in client.rpc("ping"), "ping stays responsive during execution")
        check(time.monotonic() - started < 1, "ping latency stays bounded")
        # IDs are typed: integer 2 must not cancel string request "2".
        client.send("notifications/cancelled", {"requestId": 2})
        check(client.tool("sandbox_list")[0], "busy tool calls are bounded")
        client.send("notifications/cancelled", {"requestId": "2"})
        check("result" in client.rpc("ping"), "cancel notification produces no response")
        check("no sandboxes" in client.tool("sandbox_list")[1], "cancellation destroys sandbox")
        check(not any(forks.iterdir()), "timeout and cancellation clean fork directories")

        check(not client.tool("sandbox_start")[0], "restart after cancellation")
        client.send("tools/call", {"name": "sandbox_exec", "arguments": {
            "id": 3, "command": "sleep 60", "timeout_ms": 60000,
        }}, "stop-me")
        client.send("tools/call", {"name": "sandbox_stop", "arguments": {"id": 3}}, "stop")
        responses = {r["id"]: r for r in (client.receive(), client.receive())}
        check(responses["stop-me"]["result"]["isError"] and
              not responses["stop"]["result"]["isError"], "stop interrupts active execution")
        check(not any(forks.iterdir()), "stop removes private state")

        check(not client.tool("sandbox_start")[0], "sandbox for forced shutdown")
        rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="]).decode().splitlines()
        children = [int(pid) for pid, parent in (row.split() for row in rows)
                    if int(parent) == client.process.pid]
        check(len(children) == 1, "one owned VM child")
        os.kill(children[0], signal.SIGSTOP)
        started = time.monotonic()
        check(not client.tool("sandbox_stop", {"id": 4})[0], "forced shutdown fallback")
        check(time.monotonic() - started < 5 and not any(forks.iterdir()),
              "forced shutdown reaps VM and removes clone")
        try:
            os.kill(children[0], 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("forced shutdown left a child alive")

        check(not client.tool("sandbox_start")[0], "sandbox for disconnect")
        client.send("tools/call", {"name": "sandbox_exec", "arguments": {
            "id": 5, "command": "sleep 60", "timeout_ms": 60000,
        }}, "disconnect")
        client.close()
        check(not any(forks.iterdir()), "disconnect cancels active execution and cleans state")
        print("MCP-SANDBOX: PASS", flush=True)
    except Exception:
        print(f"Failure artifacts: {work}", flush=True)
        raise
    else:
        shutil.rmtree(work)
    finally:
        listener.close()
        if client is not None and client.process.poll() is None:
            client.process.stdin.close()
            try:
                client.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                client.process.kill()
                client.process.wait()
        if boot is not None and boot.poll() is None:
            boot.kill()
            boot.wait()


if __name__ == "__main__":
    main()
