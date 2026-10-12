---
id: missing-nil-check
category: correctness
severity: high
applies_to: ["**/*"]
status: active
---
A value that can be absent (`null`, `nil`, `None`, `undefined`, an empty
optional, a missing map key) is used as if it were present on a path that
can actually be reached. Typical sources are lookups, optional fields,
parsed input, and functions documented to return nothing on failure.

Name the reachable condition that makes the value absent. Do not report
values that are checked earlier, guaranteed by the type system, or
guaranteed by an invariant visible in the code.

## Bad
    user = users.find(id)
    return user.email

## Good
    user = users.find(id)
    if user is None:
        return Error("user not found")
    return user.email
