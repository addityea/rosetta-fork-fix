# rosetta-fork-fix

## fix the Rosetta 2 fork() deadlock in linux/amd64 containers on Apple Silicon

An `LD_PRELOAD` fix (plus ready-made base images and a pixi-driven Jupyter
example) for the **Rosetta 2 fork()/`posix_spawn()` deadlock** on
macOS 26.1+: `fork()` hangs forever inside any emulated x86_64 container,
breaking Jupyter kernels, subprocess spawning, multiprocessing/pools,
`git` calls, ZeroMQ apps, and more — while arm64 containers and real x86
machines work fine.

## The bug this fixes

Since macOS 26.1 (still present in macOS 27.x), Rosetta 2's `fork()`
implementation deadlocks in any process where a thread parks in
`epoll_wait` with **SIGTRAP masked**: Rosetta pauses every thread at a
safe point before copying the address space, and a SIGTRAP-masked thread
can never be reached, so `fork()`/`posix_spawn()` hangs forever
([apple/container#966](https://github.com/apple/container/issues/966),
[zeromq/zeromq.js#732](https://github.com/zeromq/zeromq.js/issues/732)).

libzmq (bundled in pyzmq, used by **every** Jupyter kernel) starts exactly
such threads the moment a ZMQ socket is created. `jupyter_server` and
`ipykernel` create ZMQ sockets *before* spawning the kernel subprocess —
so Lab loads, plain `python` works, but "Starting kernel..." hangs and
the browser shows the kernel never connecting. arm64 containers are
unaffected; only amd64-under-Rosetta hits it. Disabling Rosetta (QEMU)
"fixes" it at ~10x the speed cost.

**Fix:** `nosigtrap.c` compiles to `libnosigtrap.so`, an `LD_PRELOAD`
interposer that strips SIGTRAP from every `pthread_sigmask`/`sigprocmask`
call. The image cross-compiles it for x86_64 at native speed and bakes
`LD_PRELOAD=/opt/rossetafix/libnosigtrap.so` into the container. Verified
on macOS 27.0.1 / Docker Desktop 4.96.3: fork-after-zmq,
posix-spawn-after-zmq, and the minimal SIGTRAP repro all hang without it
and pass with it; a real `jupyter_client` kernel launch with
subprocess/fork/multiprocessing cells passes end-to-end.

## Beyond Jupyter

The bug is not Jupyter-specific — it hits **any** program in a
linux/amd64 container on Apple Silicon that forks after a thread masks
SIGTRAP (ZMQ I/O threads being the most common trigger). Typical
symptoms, all fixed by the same shim:

- **Python/Jupyter**: kernel stuck at "Starting kernel...", never connects
  (pyzmq → libzmq threads).
- **Python generally**: `subprocess.Popen`, `os.system`, `multiprocessing`
  Pool, joblib, Dask, Spark python launchers hang after any zmq/socket use.
- **Node.js**: `child_process.spawn()` deadlocks after any ZeroMQ socket
  ([zeromq/zeromq.js#732](https://github.com/zeromq/zeromq.js/issues/732));
  also npm scripts/pipelines that fork after threaded I/O.
- **R**: `system()`, `parallel`, reticulate-driven forks after zmq.
- **Any language**: process stuck in uninterruptible `fork`/`clone`
  (visible via `strace`: parent blocked, no child created) inside emulated
  containers on macOS 26.1+.

If your symptom is "X works, but anything that spawns a process hangs" in
a `--platform linux/amd64` container on a Mac — this is almost certainly
it. Apply the shim (see "Publishing as base images" below for the
two-line `COPY` for any glibc image) or use
`saditya88/ubuntu-fix:24.04-fix1` as your `FROM`.

## Files

| file | purpose |
|---|---|
| `Dockerfile` | pixi-driven amd64 image + the fix; works with any `pixi.toml` / `pyproject.toml` (`[tool.pixi]`), uses `pixi.lock` with `--frozen` when present |
| `nosigtrap.c` | the LD_PRELOAD shim (cross-compiled in-build) |
| `pixi.toml` | example environment (jupyterlab + ipykernel + numpy/pandas, `platforms = ["linux-64"]`) — replace with your own |
| `start.sh` | entrypoint: runs the pixi `start` task if defined, else plain `jupyter lab` |
| `kernel_smoke.py` | end-to-end kernel test (`pixi run smoke`) |
| `run.sh` | build + run helper |

## Publishing as base images (optional)

Two artifacts, both built and smoke-tested from this folder:

1. **`saditya88/rosetta-fork-fix`** (`Dockerfile.fix`) — a 3 KB scratch
   image containing only `libnosigtrap.so`. Anyone can fix ANY glibc base
   in two lines:

   ```dockerfile
   COPY --from=saditya88/rosetta-fork-fix:latest /libnosigtrap.so /opt/rossetafix/libnosigtrap.so
   ENV LD_PRELOAD=/opt/rossetafix/libnosigtrap.so
   ```

2. **`saditya88/ubuntu-fix:24.04-fix1`** (`Dockerfile.ubuntu`) — upstream
   `ubuntu:24.04` (amd64) with the shim pre-applied. `FROM` it and kernels
   just work. Tag with BOTH the ubuntu release and a fix revision — do
   **not** use a bare `latest` that shadows upstream ubuntu, or you will
   silently serve stale CVEs. `.github/workflows/rebuild.yml` rebuilds
   both on a schedule + smoke-tests the fork-after-zmq case; add a
   `DOCKERHUB_TOKEN` secret and it runs unattended.

```bash
docker build --provenance=false -f Dockerfile.fix   -t saditya88/rosetta-fork-fix:latest .
docker build --provenance=false -f Dockerfile.ubuntu -t saditya88/ubuntu-fix:24.04-fix1 .
docker push saditya88/rosetta-fork-fix:latest
docker push saditya88/ubuntu-fix:24.04-fix1
```

Note: the fix image is amd64-only on purpose (the bug is x86_64-under-
Rosetta); on real x86 hardware and native arm64 the shim is simply inert
alongside. musl-based bases (alpine) need a musl rebuild of nosigtrap.c.

## Use it

```bash
# 1. drop YOUR pixi.toml (or pyproject.toml with [tool.pixi]) in this folder,
#    with platforms = ["linux-64"] and jupyterlab + ipykernel in dependencies.
# 2. build & run
./run.sh                      # http://localhost:8888 (tokenless dev default)
JUPYTER_TOKEN=secret ./run.sh # protect it
```

Verify the fix inside the image:

```bash
docker run --rm jupyter-amd64:latest pixi run smoke
```

Notes:

- `PIXI_ENVIRONMENT=<name>` (build arg or runtime env) selects a non-default
  pixi environment.
- Emulated startup is slow (conda envs under Rosetta); kernel start ~10-30s,
  then per-cell work is fine. Keep the container warm instead of restarting.
- The shim only un-masks SIGTRAP for threads; debuggers use hardware
  breakpoints, not guest SIGTRAP masks, so `pdb`/`gdb` are unaffected.
- Alternative workaround (worse): Docker Desktop → uncheck "Use Rosetta"
  (QEMU works but is ~5-15x slower), or build arm64 images when possible.

## Credits

I don't code in `C` or `C++`, this repo was created in collaboration with `Hermes Agent` running local `Qwen3.8FlashNext` model that helped me in researching the topic and implementing the necessary fixes.

## Testing

I'll be running a few more tests before I make this repo public.