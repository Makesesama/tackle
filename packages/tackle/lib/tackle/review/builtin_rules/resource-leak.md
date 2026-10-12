---
id: resource-leak
category: correctness
severity: medium
applies_to: ["**/*"]
status: active
---
A resource acquired in the changed code is not released on every path,
including early returns and errors. Resources include files, sockets and
connections, database transactions, locks, temporary files, timers,
subscriptions, and spawned processes or threads.

Name the path on which the release is skipped. Do not report resources that
are owned and released by a framework, a scoped construct (`with`, `using`,
`defer`, `try`/`finally`), or a supervisor.

## Bad
    file = open(path)
    header = parse_header(file.read(64))   # raises on bad input
    file.close()

## Good
    with open(path) as file:
        header = parse_header(file.read(64))
