/* libnosigtrap — Rosetta 2 fork() deadlock workaround
 *
 * On macOS 26.1+ (still present in 27.x), Apple's Rosetta 2 x86_64
 * emulation cannot complete fork()/clone() in a multithreaded process if
 * any thread has SIGTRAP masked while parked in epoll_wait: Rosetta
 * pauses every thread at a safe point using a trap, and a SIGTRAP-masked
 * thread can never be reached, so the parent hangs forever in fork().
 * (apple/container#966, zeromq/zeromq.js#732 — reproduces only with
 * --platform linux/amd64; arm64 containers are unaffected.)
 *
 * libzmq (bundled in pyzmq, used by every Jupyter kernel) starts I/O and
 * reaper threads that mask signals and park in epoll. jupyter_server and
 * ipykernel create ZMQ sockets *before* spawning kernel subprocesses,
 * so "Starting kernel..." hangs forever in linux/amd64 containers under
 * Rosetta — Jupyter Lab can start, plain Python works, but kernels never
 * connect.
 *
 * This LD_PRELOAD interposer refuses to let any thread mask SIGTRAP.
 * Normal code paths (debuggers use hardware breakpoints, not guest
 * SIGTRAP masks) are unaffected.
 */
#define _GNU_SOURCE
#include <signal.h>
#include <dlfcn.h>

typedef int (*sigop_t)(int, const sigset_t *, sigset_t *);

static void untrap(const sigset_t *in, sigset_t *out)
{
    *out = *in;
    sigdelset(out, SIGTRAP);
}

int pthread_sigmask(int how, const sigset_t *set, sigset_t *oset)
{
    static sigop_t real;
    if (!real) real = (sigop_t)dlsym(RTLD_NEXT, "pthread_sigmask");
    if (set) { sigset_t s; untrap(set, &s); return real(how, &s, oset); }
    return real(how, NULL, oset);
}

int sigprocmask(int how, const sigset_t *set, sigset_t *oset)
{
    static sigop_t real;
    if (!real) real = (sigop_t)dlsym(RTLD_NEXT, "sigprocmask");
    if (set) { sigset_t s; untrap(set, &s); return real(how, &s, oset); }
    return real(how, NULL, oset);
}
