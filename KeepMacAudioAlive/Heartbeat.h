#ifndef KMA_HEARTBEAT_H
#define KMA_HEARTBEAT_H
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

// Fail compilation rather than silently use a lock on an unsupported target.
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Heartbeat requires lock-free atomics");
typedef struct { _Atomic unsigned long long count; } KMAHeartbeat;

static inline void *KMAHeartbeatCreate(void) {
    KMAHeartbeat *value = malloc(sizeof(KMAHeartbeat));
    if (value) atomic_init(&value->count, 0);
    return value;
}
static inline void KMAHeartbeatDestroy(void *value) { free(value); }
static inline void KMAHeartbeatTick(void *value) {
    atomic_fetch_add_explicit(&((KMAHeartbeat *)value)->count, 1, memory_order_relaxed);
}
static inline uint64_t KMAHeartbeatRead(const void *value) {
    return atomic_load_explicit(&((const KMAHeartbeat *)value)->count, memory_order_relaxed);
}
#endif
