# Review benchmark cases

The cases in `cases/` are changes with known, seeded defects that a review
should find. They are kept as input for a future benchmark.

The benchmark runner that used them (`bench/review_eval.exs`,
`bench/review_eval/lib`, and `bench/review_repro.exs`) was removed when code
review started moving into its own package; see
[`docs/REVIEW_PACKAGE_PLAN.md`](../../../../docs/REVIEW_PACKAGE_PLAN.md). Its
last version is in Git history at `a32552d`, and the results and the review
defaults chosen from them are in
[`docs/code-review-benchmark.md`](../../../../docs/code-review-benchmark.md).
It is meant to be rewritten as standalone scripts.
