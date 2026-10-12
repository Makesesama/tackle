---
id: missing-test-for-behaviour-change
category: testing
severity: low
applies_to: ["**/*"]
status: active
---
The change adds or alters observable behaviour (a new branch, error case,
input format, or public function) but no test in the change exercises it.
This is an optional, non-blocking suggestion: name the behaviour and the
case a test should cover.

Do not report refactorings that keep behaviour, documentation, configuration
or generated files, or behaviour that existing tests in the change already
cover.

## Bad
    + if amount <= 0:
    +     return Error("amount must be positive")
      # no test touched

## Good
    + if amount <= 0:
    +     return Error("amount must be positive")
    # tests/payment_test:
    + test "rejects a zero amount":
    +     assert charge(0) == Error("amount must be positive")
