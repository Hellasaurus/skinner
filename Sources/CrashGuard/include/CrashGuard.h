#pragma once
#include <stdbool.h>

typedef void (*crash_fn_t)(void *);

/// Install process-wide SIGSEGV/SIGBUS handlers that enable crashGuard_execute.
/// Call once before any guarded render calls.
void crashGuard_install(void);

/// Execute fn(ctx) with crash protection.
/// Returns true on success, false if SIGSEGV or SIGBUS was caught.
/// After a false return the handlers are automatically re-armed.
bool crashGuard_execute(crash_fn_t fn, void *ctx);
