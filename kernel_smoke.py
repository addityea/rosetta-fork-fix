"""End-to-end kernel smoke test.

Starts a real ipykernel through jupyter_client (exactly the launch path
JupyterLab uses), then exercises the operations that deadlock under the
Rosetta fork bug: subprocess, os.fork, multiprocessing, and zmq usage
inside the kernel. Run with: pixi run smoke
"""
import sys, time

CODE = """
import os, subprocess, multiprocessing, zmq
print("arch:", os.uname().machine)
print("uname:", subprocess.check_output(["uname", "-p"]).decode().strip())
pid = os.fork()
if pid == 0:
    os._exit(42)
_, status = os.waitpid(pid, 0)
print("fork exit code:", os.waitstatus_to_exitcode(status))
def sq(x): return x * x
with multiprocessing.Pool(2) as pool:
    print("pool:", pool.map(sq, [2, 3, 4]))
ctx = zmq.Context.instance()
s = ctx.socket(zmq.PUSH)
s.bind("tcp://127.0.0.1:5599")
print("zmq ok")
"""

def main():
    from jupyter_client.manager import start_new_kernel
    t0 = time.time()
    km, kc = start_new_kernel(startup_timeout=180)
    procs = getattr(km, "procs", None) or [getattr(km, "provisioner", None) and km.provisioner.pid]
    print(f"kernel started in {time.time()-t0:.1f}s  (pid {procs[0] if procs and procs[0] else '?'})")
    kc.wait_for_ready(timeout=60)
    kc.execute(CODE)
    deadline = time.time() + 180
    idle = False
    while time.time() < deadline and not idle:
        try:
            msg = kc.get_iopub_msg(timeout=5)
        except Exception:
            continue
        if msg["msg_type"] == "stream":
            print("[kernel]", msg["content"]["text"].rstrip())
        elif msg["msg_type"] == "error":
            print("[kernel ERROR]", msg["content"]["ename"], msg["content"]["evalue"])
            sys.exit(1)
        elif msg["msg_type"] == "status" and msg["content"]["execution_state"] == "idle":
            idle = True
    if not idle:
        print("FAIL: kernel never went idle")
        sys.exit(1)
    reply = kc.get_shell_msg(timeout=30)
    assert reply["content"]["status"] == "ok", reply["content"]
    km.shutdown_kernel()
    print("SMOKE TEST PASSED")

if __name__ == "__main__":
    main()
