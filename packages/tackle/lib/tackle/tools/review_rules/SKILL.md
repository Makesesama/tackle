---
name: tackle-review-rules
description: Write, edit, or turn off code review rules for review_changes and `tackle review`. Load this when the user asks for a review rule, wants the review to check a project convention, or wants a built-in rule changed or silenced.
---

# Writing review rules

A review rule is one Markdown file with front matter. Its body is an
instruction the review's detector model reads for every changed file the rule
applies to, next to its own search for defects. A finding that comes from a
rule cites the rule's id. Write rules for project conventions and recurring
mistakes a careful reviewer would not catch without being told.

## Where rules go

- Project rules: `.tackle/review/rules/*.md` in the repository, usually at
  its root. They are shared through version control.
- User rules: `$TACKLE_HOME/review/rules/*.md` (default
  `~/.tackle/review/rules`), for the user's own rules in every project.

Only `.md` files directly in these directories are read; subdirectories are
ignored. Rules load in this order: built-in rules, then user rules, then
project rules. A later rule with the same `id` replaces an earlier one, so a
project can rewrite or turn off a built-in rule. The file name does not
matter; naming it `<id>.md` keeps things findable.

`check_review_rules` shows the directories it reads, including where to
create the project directory when there is none.

## Format

```markdown
---
id: result-tuples
category: correctness
severity: medium
applies_to: ["lib/**/*.ex"]
---
Functions that can fail in expected ways return `{:ok, value}` or
`{:error, reason}`. Report changed code that raises for an expected failure,
such as a missing record or invalid input, or that returns `nil` for one.

Do not report raising for programmer errors (a broken invariant, an
impossible case), or bang functions (`fetch!`) that document that they raise.

## Bad
    def fetch_user(id), do: Repo.get(User, id) || raise "user not found"

## Good
    def fetch_user(id) do
      case Repo.get(User, id) do
        nil -> {:error, :not_found}
        user -> {:ok, user}
      end
    end
```

Front matter fields; no others are accepted:

| Field | Values | Default |
| --- | --- | --- |
| `id` | lowercase letters, digits, and single hyphens, such as `no-raw-sql` | required |
| `category` | `correctness`, `security`, `performance`, `maintainability`, `readability`, `testing` | required when active |
| `severity` | `blocker`, `high`, `medium`, `low` | required when active |
| `applies_to` | list of globs | `["**/*"]` |
| `status` | `active`, `suppressed`, `retired` | `active` |

- An active rule needs a body.
- `applies_to` can be written as a flow list (`["lib/**/*.ex", "test/**"]`), a
  block list (one `- glob` line each), or comma-separated globs. Quote a glob
  that starts with `[` or `{`, such as `"{lib,test}/**/*.ex"`, and close every
  list. A value that can't be read makes the file fail to load; it is never
  treated as "every file".
- `#` starts a comment after whitespace.
- The severity is a default; the reviewer may raise or lower it per finding.
  Whether a finding blocks is judged per finding (a functional problem or an
  optional improvement), not by the rule's severity. Keep `blocker` and
  `high` for real bugs and security problems.

Globs match paths relative to the repository root. They work like
`.gitignore` patterns:

- `*` matches within one directory, and `**/` matches any number of
  directories.
- A pattern without `/` matches a file name at any depth (`*.sql`).
- A trailing `/` matches everything below a directory (`migrations/`).
- A leading `/` anchors the pattern at the root.

## Turning off or replacing a built-in rule

Use a file with the built-in rule's id. To turn it off, two front matter
lines are enough:

```markdown
---
id: missing-nil-check
status: suppressed
---
```

To change the rule, give a full active rule with the same id instead. The
built-in ids are: `boundary-condition`, `broken-contract`,
`concurrency-hazard`, `injection`, `missing-nil-check`,
`missing-test-for-behaviour-change`, `resource-leak`, `secret-exposure`,
`unhandled-error`. `check_review_rules` lists the rules in effect, including
built-in rules the `review.default_rules` setting leaves out.

`suppressed` turns a rule off for now, and `retired` marks a rule that is no
longer used. Either way the rule is not checked, and findings that cite it
are dropped.

## Writing a good rule

- **One concern per rule.** Two conventions belong in two files, so each
  can be turned off on its own.
- **Say what to report, concretely.** Name the code shapes that violate the
  rule ("calls `Repo.query/2` with an interpolated string"), not a value
  ("write safe SQL").
- **Say what not to report.** False positives cost more than the finding
  is worth. Exclude the legitimate exceptions you know of.
- **Add `## Bad` and `## Good` examples.** Keep them short and in the
  project's language.
- **Narrow `applies_to`.** A rule for migrations should not be read for
  every file. Narrow globs also keep each review's prompt small.
- **Keep the body short.** A rule file over 5,120 bytes, or a body over
  4,096 bytes, fails to load. Each review unit (the changed code of one file
  or part of a large one) gets at most 16 KiB of rule bodies, most severe
  rules first; a rule that no longer fits is left out of that unit.
- **Check before you rely on the rule.** Don't write rules a linter or the
  compiler already enforces, and don't restate the built-in rules.

## Checking rules

After creating or editing rule files, call `check_review_rules`. Any problem
it lists means that file is skipped by every review, so fix it and check
again until the problems are gone and the rule appears with the expected
source, severity, and globs. A person can run the same check with
`tackle review rules`.
