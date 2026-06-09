#include "include/CrashGuard.h"
#include <setjmp.h>
#include <signal.h>

static struct sigaction _oldSIGSEGV;
static struct sigaction _oldSIGBUS;

// Thread-local so concurrent render threads each have an independent guard.
// SIGSEGV/SIGBUS are synchronous faults delivered to the faulting thread,
// so siglongjmp restores the correct thread's execution context.
static _Thread_local sigjmp_buf  _guardEnv;
static _Thread_local volatile int _guardActive = 0;

static void _handler(int sig) {
    if (_guardActive) {
        _guardActive = 0;
        siglongjmp(_guardEnv, sig);
    }
    // Not inside a guard — chain to the previous handler.
    struct sigaction *old = (sig == SIGSEGV) ? &_oldSIGSEGV : &_oldSIGBUS;
    sigaction(sig, old, NULL);
    raise(sig);
}

void crashGuard_install(void) {
    struct sigaction sa;
    sa.sa_handler = _handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, &_oldSIGSEGV);
    sigaction(SIGBUS,  &sa, &_oldSIGBUS);
}

bool crashGuard_execute(crash_fn_t fn, void *ctx) {
    _guardActive = 1;
    if (sigsetjmp(_guardEnv, 1) != 0) {
        // Fault was caught; re-arm before returning to caller.
        _guardActive = 0;
        crashGuard_install();
        return false;
    }
    fn(ctx);
    _guardActive = 0;
    return true;
}
