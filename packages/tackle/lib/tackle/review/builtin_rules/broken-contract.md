---
id: broken-contract
category: correctness
severity: high
applies_to: ["**/*"]
status: active
---
The change alters a function's signature, return shape, error values,
units, or meaning, but callers or implementations that rely on the old
contract are not updated in the same change. This includes renamed or
removed fields, a function that now returns an error where it used to
raise (or the reverse), and changed argument order or defaults.

Point at the changed definition and name a caller that still uses the old
contract; read the code to find it. Do not report contracts that only
changed for callers that the change also updates.

## Bad
    - def load(path) -> Config
    + def load(path) -> Result[Config, Error]
      # elsewhere, unchanged:
      config = load(path)
      config.timeout

## Good
    + def load(path) -> Result[Config, Error]
      # the caller is updated in the same change:
      config = load(path).unwrap_or(DEFAULT_CONFIG)
      config.timeout
