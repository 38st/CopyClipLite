# Prompt for a separate fixing chat

Copy and paste the prompt below into a new Codex chat opened at the repository root.

---

Read `/Users/armanruzgar/dev/CopyClipLite/COPYCLIP_LITE_FUNCTIONAL_AUDIT.md` completely before changing any files.

Your goal is to implement the audit’s remediation backlog for CopyClip Lite. This is a functional correctness, reliability, data-integrity, UX, performance, test, packaging, and release-readiness effort. Do not perform or add a security audit.

Start by inspecting `AGENTS.md`, `git status -sb`, `origin/HEAD`, the current branch/upstream, and the audited source. Run the existing baseline tests. Treat the audit as a prioritized plan, not as unquestionable truth: verify each finding against current code before implementing it, preserve unrelated user changes, and record any finding that is already fixed or needs a product decision.

Work in the audit’s phase order. Begin with TASK-001 through TASK-004 and the test seams needed for them. Do not start polish or optional scope work while P0 data-integrity tasks remain. Keep tasks small and reviewable, but account for dependencies: TASK-001 through TASK-003 should converge on one transactional storage/persistence design rather than a set of competing patches.

For every task:

1. Restate the failure and verify its current reproduction/control flow.
2. Add a regression test that fails for the old behavior when deterministic testing is possible.
3. Implement the smallest coherent fix.
4. Run targeted tests, then `swift test`.
5. Run `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`.
6. For image, transfer, or packaging changes, run the relevant boundary/performance/artifact checks described in the audit.
7. Check every acceptance criterion before marking the task complete.
8. Update a concise task checklist in your working notes with evidence, tests, and remaining risks.

Use subagents only for bounded independent investigations or test design, with explicit goals and non-overlapping file ownership. The primary agent must integrate and verify all results. Keep the no-security scope in every delegated prompt.

Important implementation constraints:

- Preserve existing history on every failed storage operation.
- Make JSON manifest and image-sidecar commits transactional.
- Prevent stale persistence/capture tasks from mutating a newer generation.
- Keep UI work on the main actor and expensive I/O/decoding off it.
- Introduce narrow injected adapters for failure-prone platform services rather than relying on timing or live system state in tests.
- Do not weaken validation or delete existing regression coverage to make tests pass.
- Do not change documented product semantics silently; flag genuine scope decisions.

After each cohesive phase, report:

- tasks completed;
- files changed;
- tests/checks run and results;
- acceptance criteria satisfied;
- remaining tasks and any blockers.

Follow the repository’s Git closeout instructions. Commit and publish completed, verified work to the default branch only when repository state is safe and the branch rules allow it. Never force-push.

Begin now with a short implementation plan for Phase 1, then implement it rather than stopping at analysis.

---
