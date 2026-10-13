 "Make the app cleaner" can't be finished in the way "fix this bug" can. You can't prove it's done, only that each
   step made things better and nothing broke. So I'd stop asking the workflow to achieve the goal and have it climb
   toward it: each round has to show a measured improvement, and it stops when its budget runs out or the improvements
   stop coming.

   1. Turn the vague goal into a contract

   Before any edits, a planning step should turn "cleaner" into four things:

   ┌─────────────────────┬──────────────────────────────────────────────────────────────────────┬────────────────────┐
   │ Part                │ For "clean code"                                                     │ How it's checked   │
   ├─────────────────────┼──────────────────────────────────────────────────────────────────────┼────────────────────┤
   │ Invariants (must    │ Tests pass, compile --warnings-as-errors, formatting, public API     │ Commands with a    │
   │ never get worse)    │ unchanged, test files not weakened                                   │ pass/fail result   │
   │ Proxies (should go  │ mix credo --strict issues (the harness already has credo), xref      │ Numbers compared   │
   │ down)               │ cycles / compile-time dependencies, duplication, function length and │ with a baseline    │
   │                     │ nesting                                                              │                    │
   │ Rubric (judged)     │ Naming, one job per module, explicit error tuples, follows AGENTS.md │ Separate LLM       │
   │                     │ conventions, dead code removed, docs and specs                       │ judges             │
   │ Stop rule           │ N rounds in a row with no accepted improvement, or the budget is     │ The workflow loop  │
   │                     │ spent                                                                │                    │
   └─────────────────────┴──────────────────────────────────────────────────────────────────────┴────────────────────┘

   The rubric must be fixed before the work starts, and the workers must not be able to change it. Otherwise "clean"
   quietly becomes whatever the worker produced.

   2. Verify with three layers, cheapest first

   1. Hard gates. Any failure means the change is rejected, with no discussion.
   2. Proxy numbers. They must not go up, and at least one should go down. Proxies are easy to game (for example,
   splitting one function into five tiny ones lowers complexity), so they're never enough on their own to accept a
   change.
   3. Pairwise blind judging. Show a reviewer version A and version B of the same code in random order and ask "which
   is easier to maintain, and why?" Comparing two versions is much more reliable than asking for a 1–10 score. Use 2–3
   judges on different models (tackle.spawn(..., {model = ...})) and take the majority. Tell one judge specifically to
   look for metric-gaming.

   A fourth, optional layer measures maintainability directly. Give a fresh agent the same small change ("add a field
   X to Y", or "what happens when Z fails?") on the old and the new code. Then compare whether it succeeded, and how
   many turns and tokens it needed. That is close to what "easier to maintain" actually means, and it's hard to game.
   It costs more, so run it on samples rather than every round.

   3. What you can build today

   It can all be written with the current primitives:
                                                                                                                   lua
   local MAX_ROUNDS, PATIENCE = 8, 2
   local contract = tackle.await(tackle.spawn("scout",
     "Read AGENTS.md and lib/. Propose a clean-code rubric (max 6 criteria) and list " ..
     "the 5 modules that most violate it, one per line as 'TARGET: path'. Run " ..
     "`mix credo --strict` and report 'CREDO: <count>'."))
   if not contract.ok then return "contract failed: " .. contract.text end

   local stale = 0
   for round = 1, MAX_ROUNDS do
     local target = contract.text:match("TARGET: (%S+)")  -- simplified target picking
     local impl = tackle.await(tackle.spawn("worker",
       "Refactor " .. target .. " for this rubric, without changing behaviour or public API:\n" ..
       contract.text .. "\nCommit on success. Do not touch test/."))

     local gate = tackle.await(tackle.spawn("verifier",
       "Run mix test, mix compile --warnings-as-errors, mix format --check-formatted, " ..
       "mix credo --strict. First line: 'GATE: PASS' or 'GATE: FAIL', then 'CREDO: <count>'."))

     local verdicts = tackle.parallel({"a", "b", "c"}, function()
       return "reviewer", "Compare HEAD~1 and HEAD for " .. target ..
         " against this rubric:\n" .. contract.text ..
         "\nFlag metric-gaming. First line: 'VERDICT: BETTER|SAME|WORSE'."
     end)
     local better = 0
     for _, v in ipairs(verdicts) do
       if v.ok and v.text:match("^VERDICT: BETTER") then better = better + 1 end
     end

     if gate.text:match("^GATE: PASS") and better >= 2 then
       stale = 0; tackle.log("round " .. round .. ": accepted " .. target)
     else
       stale = stale + 1
       tackle.await(tackle.spawn("worker", "Revert the last commit (git revert --no-edit HEAD)."))
       if stale >= PATIENCE then break end
     end
   end
   The SKILL.md rules already cover the important parts: one writer at a time, read-only work in parallel, bounded
   loops, and decisions made by matching the first line of a reply.

   4. Where the current system falls short

   These are the honest weak spots. Each is a possible small contract, not a commitment:

   1. The gates are checked by an LLM. The Lua sandbox can't run mix test, so a "verifier" agent reports GATE: PASS as
   text, and it could be wrong or make it up. The biggest single improvement would be a host-configured
   tackle.check("test") that runs only allowlisted named commands and returns the exit code and output. Model-visible
   data still couldn't widen it, and the gates would become deterministic.
   2. There's no structured output. Lua string matching is the only parser. A JSON decode in the API, or runs that can
   return structured results, would make verdicts and metrics much more reliable.
   3. There's no way to snapshot and undo changes. Accepting or rejecting a round depends on a worker running git
   correctly. Snapshots provided by the host (a git worktree or commit per round) would make each round
   all-or-nothing.
   4. Budgets are time-only. Scripts only see a deadline, not tokens or cost. Open-ended goals need a cost budget,
   like Codex's budget_limit goal template.
   5. There's no durability or resume. A long cleanup that crashes starts over. A run log of contract, baseline and
   accepted rounds would allow resuming. This is the lesson from the Hermes refactor writeup in
   experiments/workflow-engine-research.md.
   6. There's no human checkpoint. The rubric is the single most important input, and right now nobody approves it
   before the loop spends money on it.

   How this differs from Codex's /goal

   Codex's /goal (repos/codex/codex-rs/ext/goal/templates/goals/continuation.md) uses a single agent that repeatedly
   checks itself until "evidence proves every requirement". That fits goals that can actually be finished. For quality
   goals, the split into a fixed contract, separate verifiers and accept/reject rounds is stronger, because the agent
   that does the work never grades its own work.

   If you want to start somewhere, I'd suggest #1, the tackle.check primitive with named commands configured by the
   host. Every goal-type workflow needs reliable gates, and it's a small addition to Tackle.Workflow.API. I could
   write a short design note for it, or turn the script above into a tested example.
