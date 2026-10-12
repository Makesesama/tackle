---
id: concurrency-hazard
category: correctness
severity: high
applies_to: ["**/*"]
status: active
---
Code that is wrong when it runs concurrently: data races on shared mutable
state, check-then-act sequences that another actor can interleave (exists
then create, read then write), lost updates, locks taken in inconsistent
order, and blocking calls or waits on another process without a timeout.

Describe the interleaving that breaks it. Do not report state that is
confined to one thread or process, or already protected by a lock,
transaction, or atomic operation.

## Bad
    if not cache.has(key):
        cache.put(key, compute(key))
    return cache.get(key)

## Good
    return cache.get_or_insert(key, compute)   # one atomic operation
