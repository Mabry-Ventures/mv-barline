# Support bundle

Barline now has a bounded JSON diagnostics encoder and atomic exporter. It
returns an in-memory preview for explicit review before a caller writes to a
user-selected destination. Advanced Settings exposes this as an explicit
create, review, choose-destination, and save flow. The fail-closed
`script/test-support-bundle-privacy.sh` checks the exporter, tracked credentials,
and obvious sensitive logging sources.

## Required privacy contract

Every bundle must be created only after an explicit user action and shown
for review before sharing. It may contain the Barline version/build, macOS
version/build, hardware family and architecture, permission states, compatibility
backend/capability status, bounded recent redacted logs, and validation/error
codes useful for diagnosis. Discovery diagnostics are payload-free counters,
the last bounded attempt count and managed-item count, and one closed outcome
or failure code. They distinguish lifecycle churn, unavailable snapshots,
incomplete inventories, and missing Barline controls without naming any item.

It must exclude screen images, menu item titles, private profile names or
contents, raw process inventories/PIDs, usernames, full paths, home-directory
locations, environment variables, credentials, signing identities, Sparkle
private material, browser/app content, and unrelated unified logs. Stable item
identifiers must be omitted or irreversibly scoped to the generated bundle when
they are essential to correlate events.

Generation must be bounded, cancellable, off the main actor, and fail safely.
The privacy test must inspect both filenames and content using synthetic secrets
and private values before this feature can be called ready.
