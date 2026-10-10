---
name: tackle-workflows
description: Write Lua scripts for the run_workflow tool. Load this before your first run_workflow call, or when delegation needs several dependent steps, a fan-out over a list, review/fix loops, or retries.
---

# Writing run_workflow scripts

`run_workflow` runs a Lua 5.3 script that coordinates delegated agent runs.
Every run started by the script is a normal subagent run. It uses an allowlisted
profile, follows this session's limits, and is cancelled when the tool call
ends. Use a workflow instead of separate `subagent` calls when the flow is
known up front: chained steps, a fan-out over a list, or loops that depend on
results.

Don't use a workflow for one delegated task (call `subagent`) or for work you
can do yourself.

## API

All functions live on the global `tackle` table.

| Call | Behaviour |
| --- | --- |
| `tackle.spawn(profile, prompt, opts?)` | Starts one run and returns a handle right away, so several spawns can overlap. `opts` may only be `{model = "provider/model"}`. Raises if the profile is not allowed or the runtime refuses the spawn. |
| `tackle.await(run)` | Blocks until the run settles and returns `{ok, status, text}`. A failed run is returned, not raised, so check `ok`. Only an invalid handle raises. |
| `tackle.parallel(items, fn, opts?)` | Runs one agent per item, keeping at most `opts.limit` in flight. `fn(item, index)` returns `profile, prompt[, opts]`. Returns one table per item in input order: `{index, ok, status, text}`. |
| `tackle.cancel(run, reason?)` | Asks one run to stop. |
| `tackle.log(message)` | Shows a progress line to the user. |

- `text` holds the agent's answer when `ok` is true, and the failure reason when it is false.
- `status` is one of `"ok"`, `"error"`, `"cancelled"`, `"runtime_error"`, `"timeout"` or `"rejected"`. `tackle.parallel` can also report `"callback_error"`, `"spawn_error"`, `"capacity"` (no free slot; trying the item again later may work) or `"unavailable"`.
- `items` must be a plain list numbered 1..n. A `limit` above the session's concurrency ceiling is lowered to that ceiling.

## What the script returns

The script's return values become the tool result, so return exactly what you
need to read next:

- `return a, b` or `return {a, b}` gives one line per value;
- any other table, such as `{ok = true, text = "..."}`, is returned as JSON;
- if nothing is returned, the result says the workflow returned no values.

## Rules that matter

- **Profiles.** Use the profile names listed for delegation in your
  instructions (for example `scout`, `reviewer`, `worker`). The host may allow
  workflows only some of them. A profile that is not allowed makes
  `tackle.spawn` raise and gives the item `"spawn_error"` in `tackle.parallel`.
- **Self-contained prompts.** Each run starts with a fresh context. It cannot
  see your conversation or other runs, so put everything it needs into its
  prompt: goal, file paths, constraints and the expected output. Pass results
  forward by concatenating them: `"Plan:\n" .. plan.text`.
- **One writer.** Runs share the workspace. Never let two runs that edit files
  overlap, and do not edit files yourself while the workflow runs. Parallel
  runs should be read-only (scout or reviewer) or touch disjoint files.
- **Bounded loops.** Every run is a paid model call. Give every retry or fix
  loop a maximum number of attempts.
- **Sandbox.** The script cannot touch files, the network, processes or the
  environment (`io`, `require`, `load` and the file, process and environment
  functions in `os` are blocked), so delegate that work to an agent. `string`, `table`, `math`, `utf8` and `pcall` are available. A script that loops without awaiting runs out of its
  instruction budget.
- **Deadline.** The whole workflow runs under the session's workflow timeout.
  `timeout_ms` can only make it shorter. Each run has its own timeout too.
- **Failure policy.** Check `ok` after every `await`. Wrap `tackle.spawn` in
  `pcall` only when you have a real fallback.

## Patterns

Chained steps:

```lua
local scout = tackle.await(tackle.spawn("scout",
  "Find where session titles are generated in this repo. Report file paths and key functions."))
if not scout.ok then return "scout failed: " .. scout.text end

local impl = tackle.await(tackle.spawn("worker",
  "Make session titles at most 60 characters long. Context from a scout:\n" .. scout.text ..
  "\nRun the relevant tests and report the changed files."))
return impl.text
```

Read-only fan-out:

```lua
local files = {"lib/a.ex", "lib/b.ex", "lib/c.ex"}
local results = tackle.parallel(files, function(file)
  return "reviewer", "Review " .. file .. " for error-handling bugs. List findings with line numbers."
end, {limit = 2})

local report = {}
for _, r in ipairs(results) do
  report[#report + 1] = files[r.index] .. ": " .. (r.ok and r.text or ("FAILED (" .. r.status .. ") " .. r.text))
end
return report
```

Review and fix loop with a maximum number of attempts:

```lua
local task = "Add input validation to Foo.parse/1 in lib/foo.ex, with tests."
local impl = tackle.await(tackle.spawn("worker", task))
for attempt = 1, 3 do
  if not impl.ok then
    return "implementation failed (" .. impl.status .. "): " .. impl.text
  end

  local review = tackle.await(tackle.spawn("reviewer",
    "Review the uncommitted change for: " .. task ..
    "\nReply with exactly APPROVED on the first line if there are no blocking issues."))
  if not review.ok then
    return "review failed (" .. review.status .. "): " .. review.text
  end
  if review.text:match("^APPROVED") then
    return "approved after " .. attempt .. " review(s)\n" .. impl.text
  end

  tackle.log("review " .. attempt .. " requested changes")
  impl = tackle.await(tackle.spawn("worker", task .. "\nFix these review findings:\n" .. review.text))
end
return "not approved after 3 reviews; last implementation report:\n" .. impl.text
```

Ask runs for answers in a fixed format (a first-line verdict, a list) when the
script has to branch on them. Lua's string matching is the only parser you
have.
