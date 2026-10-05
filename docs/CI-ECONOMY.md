# Solo-developer CI policy

Owner decision, October 4, 2026: keep included GitHub-hosted Linux runners.
GitHub Mac and unregistered self-hosted runner routes are prohibited. An
exception requires Jared's explicit approval of the exact workflow/commit,
purpose, maximum runtime and expiry before allocation. A manual-dispatch
button or a positive credit balance is not that approval.

Run `./script/ci/repo_hygiene.sh` before pushing workflow changes. Keep the
existing single Linux job; it validates literal Ubuntu routing and its five-minute bound. The workflow check is defense in depth, not a platform-level runner
ban; another workflow can allocate before it finishes. Standard hosted runners
remain enabled to preserve the included Linux allowance.

Apple work: qualify the exact clean candidate locally first (build, analysis,
affected unit/integration/UI tests, iPad/watch/macOS destinations where relevant,
and documented skips); record the commit, toolchain, commands and results.
Only then manually admit that candidate to Xcode Cloud. Do not trigger Apple
CI to discover compile failures. Keep archives/distribution separate from
validation; preserve independent release approvals and installed-device proof.

Use one hosted review request per final candidate head, with local review during
iteration. Review failures and provider quota errors must stay merge-blocking
where required; missing review is never a pass. Do not retry the same refusal
in a polling loop. Avoid combining automatic every-push reviews with duplicate
manual requests. Deep/exhaustive review is reserved for release or risk-specific
work. Retain current production, security and exact-head gates.

Cancel superseded PR compute, but never interrupt production migrations or
custom-check finalization. Use explicit job timeouts; do not reduce tests or
coverage floors to fit a timeout. Preserve the current 90-day global evidence
retention; shorten only disposable artifacts. GitHub paid overage remains $0;
Xcode Cloud remains on its current tier. No auto-reload or credit spending is
implied by this policy.

## Xcode Cloud enrollment

`Barline Manual Validation` is enrolled for the Mabry Ventures LLC team.
Its only admission is manual branch or pull-request start, after local full
qualification of the same candidate. It has one macOS build action, pinned to
Xcode 27 (27A266a) and macOS 27 (26A428), with no archive or distribution action.
The shared Xcode Cloud manifest records product enrollment; the workflow itself
is managed in Xcode's Integrate > Manage Workflows UI. Do not add automatic push,
PR, tag, or scheduled starts. Local full CI remains responsible for unit,
integration, UI, Accessibility, and hardware journeys.
