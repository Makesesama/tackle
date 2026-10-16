---
id: boundary-condition
category: correctness
severity: medium
applies_to: ["**/*"]
status: active
---
Code that is wrong at the edges of its input range: off-by-one indexes and
loop bounds, inclusive versus exclusive ranges, empty collections or
strings, a single element, zero, negative numbers, the first or last page,
and integer overflow or truncation.

State the exact boundary value that fails and what happens. Do not report
boundaries that the caller provably never passes.

## Bad
    // Returns the last `n` items.
    for (i = items.length - n; i <= items.length; i++) result.push(items[i])

## Good
    // Returns the last `n` items, or all of them when there are fewer.
    for (i = max(items.length - n, 0); i < items.length; i++) result.push(items[i])
