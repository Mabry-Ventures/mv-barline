# Support and contribution delivery

## Public support

Email support is `support@mabryventures.com`. Outbound Barline mail uses
`Barline <hello@usebarline.com>` through Resend with Reply-To
`support@mabryventures.com`. The static site has no automated sending or
subscriber database. DNS verification does not create an inbound hello mailbox:
`usebarline.com` publishes no MX record, so mail addressed to `hello@` is
rejected rather than delivered. Public copy therefore names `hello@` only as
the sending address and points people at the support address instead.

Sender authentication is DKIM (`resend._domainkey.usebarline.com`) with SPF on
the Resend bounce subdomain. `usebarline.com` publishes no DMARC record, unlike
`mabryventures.com`; adding one, even `p=none` with a reporting address, is the
outstanding step before any volume sending.

[GitHub Issues](https://github.com/Mabry-Ventures/mv-barline/issues) is the public
entry point for bug reports and feature suggestions. Read
[troubleshooting](../FREQUENT_ISSUES.md) first. Share only reviewed, relevant
diagnostics; private security reports follow [SECURITY.md](../SECURITY.md).

Contributions are optional one-time support for free software. They do not
create an account, subscription, entitlement, or support priority. The app has
no payment SDK, card form, webhook, or feature-unlock logic. Stripe hosts the
external checkout and processes payment information; see the website privacy
page before contributing. Do not describe support payments as tax-deductible
charitable donations.

## Maintainer routing

The configured support workflow sends GitHub issue notifications to a dedicated
Slack support channel and imports incoming issues into the Barline Linear team
for triage. Team activity also reaches the product Slack channel. The public
issue remains the visitor's entry point; private workspace membership is not
required to report a bug.

Maintainers must keep internal discussion out of comment threads that synchronize
back to public GitHub issues. Do not assume that a linked Linear issue is wholly
private. Delivery to a Slack channel is distinct from an observed desktop or
mobile notification; notification permissions and quiet hours also matter.

## Verification checklist

Before launch or after changing an integration:

1. Create one clearly labeled, non-sensitive test issue and follow-up comment.
2. Confirm both reach the support channel and Barline triage without duplicates.
3. Confirm the issue's status update propagates as intended, then close the test
   transparently instead of deleting its history.
4. Verify internal team activity reaches the product channel without creating
   an unintended public GitHub issue.
5. Verify the maintainer's intended notification delivery separately.

For checkout changes, verify amount boundaries, success, decline, and abandoned
checkout in Stripe sandbox. Read back the approved live destination separately;
never infer successful payment from browser navigation. Do not make an actual
charge merely to test a live link without explicit authorization.

## Evidence and publication

Detailed delivery receipts and provider identifiers belong in controlled local
qualification artifacts, not visitor documentation. Historical support-routing
and sandbox checks were performed during staging; refresh them when configuration
changes. No real payment was part of the recorded live-link verification.

The staging checkout accepts real payments and must disclose that fact. Staging
is not private: `noindex` is not access control. App release qualification,
production domain/TLS validation, and public-site deployment are separate gates.
