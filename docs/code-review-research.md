# LLM code review: what the research says

Research notes for a refined Claude Code review addon. Status: **research, not a plan.**
Collected from primary sources (papers, engineering reports); vendor marketing
(CodeRabbit, Qodo, Greptile) is deliberately excluded from the evidence base.

Caveats that apply to almost everything below:

- Most industrial results are single-company, observational, non-randomized.
- Several papers have internal numeric inconsistencies (flagged where relevant).
- Many are arXiv preprints; venue noted only when stated by the source.
- Absolute numbers do not transfer between studies (different metrics, languages,
  models). Use them for direction and relative effect, not targets.

## Sources

| # | Source | Type | Scale |
|---|--------|------|-------|
| S1 | BitsAI-CR, ByteDance, arXiv:2501.15134 | Deployment + offline eval | 12k WAU, 5 langs, 219 rules |
| S2 | Lu et al., *Towards Practical Defect-Focused ACR*, Kuaishou, ICML 2025, arXiv:2505.17928 | Deployment + offline eval | C++, 45 real fault MRs |
| S3 | Cihan et al., *Automated Code Review In Practice*, Beko, ICSE-SEIP 2025, arXiv:2412.18531 | Field study (PR-Agent) | 4,335 PRs |
| S4 | uReview, Uber engineering blog | Deployment report | ~65k diffs/week |
| S5 | Vijayvergiya et al., AutoCommenter, Google, AIware 2024, arXiv:2405.13565 | Deployment + A/B | tens of thousands of devs |
| S6 | SWR-Bench, PKU, FSE 2026, arXiv:2509.01494 | Benchmark | 1,000 PRs, 17 LLMs, 7 tools |
| S7 | RovoDev Code Reviewer, Atlassian, ICSE-SEIP 2026, arXiv:2601.01129 | Deployment + online eval | >1,900 repos, 54k comments |
| S8 | *What types of review comments do developers resolve?*, Atlassian, arXiv:2510.05450 | Empirical | 4,000 LLM comments |
| S9 | c-CRAB *Code Review Agent Benchmark*, NUS, arXiv:2603.23448 | Benchmark (executable tests) | 184 PRs, 4 tools |
| S10 | Agentic multifaceted review at Ericsson, arXiv:2609.15877 | Design-science case study | 7 commits, 206 issues |
| S11 | RADAR, Meta, arXiv:2605.30208 | Deployment (risk-gated auto-approve) | 535k diffs |
| S12 | *Does AI Code Review Lead to Code Changes?*, arXiv:2508.18771 | Mining study of 16 GitHub Actions | 22k comments |
| S13 | RevMate, Mozilla + Ubisoft, arXiv:2411.07091 | Live user study | 59 reviewers, 1,644 comments |
| S14 | LLM false-positive reduction for static analysis, Tencent, arXiv:2601.18844 | Industrial empirical | 433 alarms |
| S15 | Jin & Chen, *Systematic Overcorrection*, arXiv:2603.00539 | Benchmark | 1,400 instances, 5 LLMs |
| S16 | *Bigger Isn't Always Better*, arXiv:2606.15689 | Benchmark (vendor-affiliated) | 150 samples, 5 LLMs |

Industry write-ups used for context only (not evidence): Cursor *Building a
better Bugbot* (8 passes with shuffled diff order, majority vote, validator),
Anthropic `code-review` plugin (parallel reviewers + per-issue validators),
OpenAI Codex `review_prompt.md` (strict JSON findings schema).

## Findings, by strength of evidence

### Strong (multiple independent deployments agree)

**1. Precision matters more than recall; noise kills adoption.**
- S1: precision stuck at ~25% before redesign; authors make "precision over
  recall" an explicit lesson because early false positives destroyed trust.
- S5: "a few negatives erode trust"; acceptance raised by suppression, not by
  finding more.
- S4: "precision > volume"; usefulness held above 75% as a floor.
- S13: only 7–8% of generated comments accepted; rejections were "incorrect"
  (15–33%) and "trivial" (15–35%).
- S12: open-source Actions got 0.9–19% of comments addressed vs 60% for humans;
  6–40% of AI comments were invalid or vague.

**2. A separate post-generation filter is the most reliable quality lever.**
- S1: dedicated ReviewFilter pass raised precision substantially (paper reports
  several conflicting deltas, roughly +10–15 pp); the authors say fine-tuning
  alone could not remove hallucinated findings.
- S7: a learned *actionability* filter gave +15–20 pp human-alignment; an
  LLM *factual-correctness* judge had **minimal impact**. The kind of filter
  matters.
- S4: second grading prompt with confidence thresholds tuned per
  assistant/language/category, plus semantic dedup and category suppression.
- S2: validator lowered false alarms but also lost real bugs; it is a
  precision/recall trade, not free.
- S13: LLM-as-judge pass with curated "undesired comment" examples.
- S1: for the filter, **conclusion-first** output beat reasoning-first
  (77% vs 66% precision, 1.7 s vs 31 s).

**3. Explicit, curated rules are a large lever; generic context is not.**
- S1: taxonomy-guided rules took offline precision from 16.8% to 57%.
- S7: review guidelines were the highest-value prompt component; persona, CoT,
  PR description and Jira context each added only 1–3%.
- S5: every comment links to one best-practice document; that link is the unit
  of tuning.
- S9: authors attribute missed maintainability/design issues to missing
  repository-specific context and recommend repo rule files (e.g. AGENTS.md).
- Rules need a lifecycle: S1 retires rules on a metric threshold, S5 suppressed
  17 low-value best practices (useful rate 54% → 66%, later >80%), S4 suppresses
  historically low-value categories.

**4. Review quality collapses on large changes; units must be small.**
- S6: recall 38% for single-issue PRs → 9% for PRs with ≥5 issues; precision
  stays flat.
- S16: F1 ~0.66–0.80 for diffs ≤10 lines vs 0.04–0.07 above 50 lines; authors
  call splitting large diffs the most actionable finding.
- S5: whole-file input truncated at context limit; S12: tools split hunks by
  token limit, and hunk-level tools beat file-level ones on addressing rate.

**5. Online success is measured by "addressed/resolved", not text similarity.**
- S4 (addressed in same changeset), S5 (resolution), S7/S8 (code resolution
  rate), S1 ("outdated rate"), Bugbot (resolution rate) all converge on it.
- S6, S7, S9 show BLEU/ROUGE-style similarity is unreliable or misleading.
- Per-comment feedback built into delivery is used for tuning in S4, S5, S13.

### Moderate (fewer sources or mixed results)

**6. Context: targeted code context helps, more context is not better.**
- S6: "missing context" causes 48% of false positives.
- S2: data-flow slicing beat raw diff and enclosing function; *backward-only*
  flow beat full flow (more context distracted the model).
- S1: diff hunks expanded to function boundaries, capped at 3–4× diff size.
- S13: letting the model request functions/lines it needs raised appreciation.
- S7: PR/Jira metadata gave minimal gain (see 3).

**7. Repeated sampling with aggregation helps; naive union hurts.**
- S6: running the same reviewer n times and synthesizing raised F1 by 20–44%,
  diminishing past n=5; 5× a cheap model beat 1× an expensive one.
- S2: more reviewers raise recall and false alarms; a meta-reviewer dropping
  findings raised by only one reviewer keeps it in check.
- S16: taking the *union* of two models' findings lowered F1.
- Single-run output is unstable: S6 found very little overlap across 5 runs of
  one model.

**8. Asking for reasoning/explanations/fixes inflates false "bug" claims.**
- S15: moving from a direct verdict to verdict+explanation+fix raised GPT-4o's
  false-rejection rate from 26% to 73% (HumanEval). Execution-checking the
  proposed fix cut mean false rejection by roughly 50–70% (e.g. HumanEval
  54.8% → 16.3%), with a small rise in false acceptance.
- S14: CoT was the weakest prompting strategy; few-shot examples were best;
  3-run majority vote used for stability.
- S1: reasoning-first filter was 18× slower for lower precision.
- Implication: ground each finding in evidence (rule cited, concrete failing
  input, verified by execution or tool where possible) rather than prose.

**9. Comment shape: short, line-anchored, concrete, categorised.**
- S13: comments were too wordy; reviewers shortened many before publishing.
- S12: code-rich, concise comments were addressed more; long text less.
- S10: strict four-field format (antipattern, location, problem, fix) with
  positive and negative examples made assessment feasible.
- S2: inline absolute line numbers in the prompt improved localisation.

**10. Which categories land differs by org; make it data-driven.**
- S4: developers dislike style/logging/low-impact performance comments; value
  correctness and error handling.
- S8: resolution — readability 43%, bugs 42%, maintainability 36%, design 29%.
- S13: refactoring suggestions accepted far more than functional ones (18% vs 5%).
- S6: functional findings score better; recommends reporting mandatory
  (functional) separately from optional (evolutionary).

### Weak or contested

**11. Multi-agent specialist lenses.** S10 reports specialists each finding
unique issues and 96% correctness, but on 7 commits with no ablation, and calls
orchestration a single point of failure. S6 found a multi-agent tool (CR-Agent)
*worse* than a single well-engineered prompt (PR-Review), citing error
propagation. Bugbot's blog reports its largest gain from moving to one agentic
reviewer. Treat specialist fan-out as unproven.

**12. Bigger models.** S16 found a small model beat its larger sibling on F1 at
⅓ cost; S12 found model choice a low-importance factor; S4 found a specific
generator+grader pairing best. Model choice is secondary to pipeline design.

**13. Incremental re-review.** S3: re-reviewing after each fix produced
redundant, unhelpful comments. S12: 3/16 tools track the last reviewed commit.
Bugbot dedupes against previous runs. Little quantitative data, but consistent.

**14. Net productivity impact is modest and context dependent.** S3: PR closure
time went *up* (5h52m → 8h20m). S7: PR cycle time down 31%. S5: A/B showed no
significant change in review duration. S12: manual triggers were addressed more
than automatic ones. AI review complements human review in every study.

## What this implies for an Claude Code review addon

Design choices with direct evidence behind them:

1. **Deterministic preprocessing** before any model call: drop generated,
   config and binary files; split the change into small units (hunk or
   function); attach bounded code context (enclosing function, capped). (4, 6)
2. **Rules as first-class input**: project rule files with stable IDs and
   categories; each finding cites the rule it applies. Rules can be retired
   or suppressed by category. (3)
3. **Structured, short findings**: file, line range inside the diff, category,
   severity, rule ID, one-paragraph body, optional concrete suggestion. (9)
4. **A separate filter stage**, conclusion-first, with per-category
   thresholds and dedup; prefer actionability judging over generic
   "is this true" judging. (2, 8)
5. **Optional repeated sampling** (n ≤ 5) with aggregation/voting, never plain
   union. (7)
6. **Incremental review**: fingerprint findings, skip what was already posted
   or dismissed. (13)
7. **Per-finding feedback and telemetry** (accepted / dismissed / addressed)
   so filters and rules can be tuned on real data. (5)
8. **Offline evaluation** against a fact-matching benchmark (SWR-Bench,
   c-CRAB) rather than text similarity. (5)

Not justified by the evidence yet: specialist multi-agent fan-out by default,
code graphs/semantic indexes, generated verification scripts, and long
chain-of-thought in the findings themselves.
