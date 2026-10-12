---
id: unhandled-error
category: correctness
severity: high
applies_to: ["**/*"]
status: active
---
A failure must not disappear silently. Report changed code that:

- ignores the error result or return value of a call that can fail (I/O,
  network, parsing, external processes, database writes);
- catches every error and continues as if the operation succeeded, or turns
  the failure into a default value that callers cannot tell apart from
  success;
- logs an error but still reports success to its caller.

Do not report code that handles the error deliberately and visibly: returns
it, retries it, or documents why it is safe to ignore.

## Bad
    try:
        save(order)
    except Exception:
        pass
    return "ok"

## Good
    try:
        save(order)
    except StorageError as error:
        log.error("saving order %s failed: %s", order.id, error)
        raise
