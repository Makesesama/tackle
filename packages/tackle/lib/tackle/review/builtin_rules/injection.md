---
id: injection
category: security
severity: blocker
applies_to: ["**/*"]
status: active
---
Untrusted input (request data, user files, environment, model output,
anything from another trust boundary) reaches an interpreter without being
passed as data: shell commands, SQL or other query languages, file paths
(path traversal), HTML or other templates, regular expressions, `eval`, or
deserialisation of executable formats.

Name the source of the input and the sink it reaches. Do not report input
that is validated against an allowlist, passed as separate arguments or
query parameters, or escaped by the sink's own API.

## Bad
    run("git log " + request.branch, shell=True)
    db.query("SELECT * FROM users WHERE name = '" + name + "'")

## Good
    run(["git", "log", "--end-of-options", request.branch])
    db.query("SELECT * FROM users WHERE name = ?", [name])
