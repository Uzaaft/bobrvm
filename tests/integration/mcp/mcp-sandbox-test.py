#!/usr/bin/env python3
"""E2E: drive `bobrvm mcp` the way an agent would.

Creates a scratch project, boots it once to build warm state, then runs
a full MCP session: two concurrent sandboxes, exec with exit codes,
and fork isolation (a file written in one sandbox must not exist in
the other). Requires the alpine assets and Hypervisor.framework.

    python3 tests/integration/mcp/mcp-sandbox-test.py
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[3]
BIN = REPO / "zig-out/bin/bobrvm"
KERNEL = REPO / "tests/integration/alpine/out/Image"
INITRD = REPO / "tests/integration/alpine/out/initramfs-minimal"

if not BIN.exists():
    print("SKIP: build bobrvm first (zig build)")
    sys.exit(1)
if not KERNEL.exists():
    print("SKIP: alpine assets missing (create-minimal-initramfs.sh)")
    sys.exit(1)

work = pathlib.Path(tempfile.mkdtemp(prefix="bobrvm-mcp."))
proj = work / "proj"
proj.mkdir()
(proj / "bobrvm.toml").write_text(
    f'name = "mcp-test"\nmemory = 512\ncpus = 1\n'
    f'kernel = "{KERNEL}"\ninitrd = "{INITRD}"\nshare = false\n'
)

# Warm state: boot once, suspend at an idle shell prompt (a foreground
# process would swallow the console-exec input).
for stale in pathlib.Path.home().glob(".config/bobrvm/projects/proj-*"):
    shutil.rmtree(stale, ignore_errors=True)
env = dict(os.environ, BOBRVM_TEST_SUSPEND=f"14:{proj}/suspend.img")
boot = subprocess.Popen([BIN, "up"], cwd=proj, env=env,
                        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL)
time.sleep(20)
boot.stdin.close()
boot.wait(timeout=30)
state_dirs = list(pathlib.Path.home().glob(".config/bobrvm/projects/proj-*"))
assert len(state_dirs) == 1 and (proj / "suspend.img").exists(), "warm boot failed"
(proj / "suspend.img").rename(state_dirs[0] / "warm.img")

p = subprocess.Popen([BIN, "mcp"], cwd=proj,
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL)

def rpc(id, method, params=None):
    msg = {"jsonrpc": "2.0", "id": id, "method": method}
    if params is not None:
        msg["params"] = params
    p.stdin.write((json.dumps(msg) + "\n").encode())
    p.stdin.flush()
    return json.loads(p.stdout.readline())

def tool(id, name, args=None):
    r = rpc(id, "tools/call", {"name": name, "arguments": args or {}})
    return r["result"].get("isError", False), r["result"]["content"][0]["text"]

failures = []
def check(cond, label, detail=""):
    print(("PASS " if cond else "FAIL ") + label + (f" | {detail}" if detail else ""))
    if not cond:
        failures.append(label)

init = rpc(1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}})
check(init["result"]["protocolVersion"] == "2024-11-05", "initialize")

names = [t["name"] for t in rpc(2, "tools/list")["result"]["tools"]]
check("sandbox_exec" in names and "sandbox_start" in names, "tools/list")

err, text = tool(3, "sandbox_start")
check(not err and "sandbox 1 started" in text, "sandbox_start", text)
time.sleep(2)

t0 = time.time()
err, text = tool(4, "sandbox_exec", {"id": 1, "command": "echo hello-from-sandbox && uname -m"})
check(not err and "hello-from-sandbox" in text and "aarch64" in text,
      "sandbox_exec", f"{time.time()-t0:.2f}s")

err, text = tool(5, "sandbox_exec", {"id": 1, "command": "false"})
check(err and "exit code 1" in text, "nonzero exit code")

err, text = tool(6, "sandbox_exec", {"id": 1, "command": "echo tainted > /mark && cat /mark"})
check(not err and "tainted" in text, "sandbox 1 writes a file")

err, text = tool(7, "sandbox_start")
check(not err and "sandbox 2 started" in text, "second concurrent sandbox")
time.sleep(2)
err, text = tool(8, "sandbox_exec", {"id": 2, "command": "cat /mark 2>&1"})
check("No such file" in text or "can't open" in text, "fork isolation")

check(not tool(9, "sandbox_stop", {"id": 1})[0], "sandbox_stop 1")
check(not tool(10, "sandbox_stop", {"id": 2})[0], "sandbox_stop 2")

p.stdin.close()
p.wait(timeout=30)
check(p.returncode == 0, "clean shutdown")

if failures:
    print("MCP-SANDBOX: FAIL —", ", ".join(failures))
    sys.exit(1)
shutil.rmtree(work, ignore_errors=True)
for d in state_dirs:
    shutil.rmtree(d, ignore_errors=True)
print("MCP-SANDBOX: PASS")
