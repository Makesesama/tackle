---
id: secret-exposure
category: security
severity: blocker
applies_to: ["**/*"]
status: active
---
Credentials and other secrets (passwords, API keys, tokens, private keys,
session cookies, connection strings with passwords) are hardcoded in the
change, written to logs or error messages, returned in responses, or stored
somewhere less protected than their source.

Do not report obvious placeholders, test fixtures with fake values, or
values read from a secret store or the environment and kept out of output.

## Bad
    API_KEY = "sk-live-4f9a..."
    log.info("authenticating with token " + token)

## Good
    API_KEY = env.require("PAYMENTS_API_KEY")
    log.info("authenticating client " + client_id)
