# Prompt for a separate completion/verification chat

Copy and paste the prompt below into a new Codex chat opened at the repository root.

---

Read these files completely before changing anything:

- `/Users/armanruzgar/dev/CopyClipLite/COPYCLIP_LITE_FUNCTIONAL_AUDIT.md`
- `/Users/armanruzgar/dev/CopyClipLite/COPYCLIP_LITE_IMPLEMENTATION_REPORT.md`
- `/Users/armanruzgar/dev/CopyClipLite/ACCESSIBILITY_TEST_MATRIX.md`

The 37-task repository remediation has been implemented. Your goal is to independently verify the implementation report against the current code, fix any regression you can reproduce, and coordinate only the remaining owner/manual release gates. This is a functional correctness, reliability, data-integrity, UX, performance, test, packaging, and release-readiness effort. Do not perform or add a security audit.

Start by inspecting `AGENTS.md`, `git status -sb`, `origin/HEAD`, the current branch/upstream, and the exact current commit. Run `swift test`, the strict-concurrency build, `./script/check_coverage.sh`, `./script/tests/task_031_harness.sh`, and local release packaging. Treat both reports as evidence to verify, not as unquestionable truth. Preserve unrelated user changes.

Audit all 37 task rows, prioritizing the areas changed by the completion pass:

1. staged sidecar/manifest failure boundaries and import/persistence ordering;
2. bounded image scheduling, canonical hashes, image types/orientations, thumbnail repair, and transfer limits;
3. required/optional pasteboard failures, Direct Paste state, keyboard routing, hotkeys, login items, and updater responses;
4. atomic installation, final ZIP verification, drag/drop, accessibility semantics, and honest production-source coverage.

Use subagents for bounded independent verification with explicit goals and non-overlapping file ownership. Require evidence and targeted tests from each agent. Keep the no-security scope in every delegated prompt.

Do not claim the following gates complete without direct evidence:

- an anonymously reachable update feed and downloadable release asset;
- an anonymously downloadable, checksum-verified tagged ad-hoc release with the required Gatekeeper warning;
- the manual VoiceOver matrix.

Those require repository/release decisions or human assistive-technology QA. Apple Developer signing and notarization are outside the selected scope. Ask for the required authorization or evidence rather than changing repository visibility, creating a release, or changing macOS accessibility settings on your own.

If a verified regression exists, add a deterministic regression test, implement the smallest coherent fix, rerun targeted and full verification, and update the implementation report. Do not weaken validation or coverage gates to make checks pass.

Follow the repository’s Git closeout instructions. Commit and publish completed, verified work to the default branch only when repository state is safe and the branch rules allow it. Never force-push.

Begin with a short verification plan, dispatch bounded subagents, and continue through evidence-backed completion rather than stopping at analysis.

---
