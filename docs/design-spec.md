# Spree::BankPayments — design spec

**Date:** 2026-08-15
**Status:** Approved, ready for implementation planning
**Owner:** m.kennedy@aypex.io

## Problem

Card acquiring costs roughly 1.5–2.9% per order. Aypex stores that can accept
direct bank transfer could avoid most of that fee, and pass part of the saving
to the customer as an incentive. Manual bank transfer is only viable if incoming
payments can be matched back to orders automatically — otherwise the operational
load exceeds the fee saved.

Four existing Spree bank-transfer extensions were reviewed
([vinsol](https://github.com/vinsol-spree-contrib/spree_bank_payments),
[olympusone](https://github.com/olympusone/spree_bank_payments_payment),
[welaika](https://github.com/welaika/spree_simple_bank_transfer),
[cbilgili](https://github.com/cbilgili/spree-bank-transfer)). All are Spree
2.x/3.x era, dormant, and stop at displaying an IBAN. None reconcile incoming
payments. The reconciliation half is the novel work.

## Scope

Two gems under `aypex-io`:

- **`spree_bank_payments`** — bank-agnostic core. Payment method, payment
  session, reference generation, discount adjustment, expiry job and health
  gate, admin queue, `Reconcilers::Base` contract, and a `Manual` reconciler.
  Fully usable standalone with hand-marked payments.
- **`spree-bank_payments_revolut`** — Revolut Business API reconciler,
  API client, token handling, webhook signature verification.

Two gems rather than one adapter-in-core, chosen deliberately to establish the
foundation for further banking providers. The cost is that `Reconcilers::Base`
is a published cross-gem contract: changing it requires a coordinated release.
The interface is kept deliberately narrow to limit that exposure.

Naming: the gem is `spree-bank_payments`, the require path is
`spree/bank_payments`, and the Ruby module is `Spree::BankPayments`.

**Why not `bank_transfer`.** Every spelling of it is unavailable. Two different
owners hold the underscore and hyphen forms — `spree_bank_transfer` (`vinsol`,
v2.0.4, November 2013, ~4,967 downloads) and `spree-bank-transfer` (Mohit Bansal,
v2.3.0, October 2014, ~25,639 downloads) — and RubyGems' policy is not to
reassign ownership absent proven harm.

Critically, `spree-bank_transfer` is *also* unavailable, even though no gem holds
that exact string and the RubyGems API returns 404 for it. RubyGems rejects a new
name that is too similar to an existing one, treating `-` and `_` as equivalent:

```
There was a problem saving your gem:
Name 'spree-bank_transfer' is too similar to an existing gem named
'spree-bank-transfer'
```

So an API 404 means "no exact match", **not** "publishable". Verifying a candidate
means checking every punctuation permutation of its word sequence, not the literal
string. Avoid near-misses too: the error says *similar*, not *identical*, so a
plural like `spree-bank_transfers` may also be refused.

`spree-bank_payments` is free across all nine permutations, and the spelling is
correct on its own terms: per the RubyGems convention a dash denotes a gem living
under another gem's namespace while an underscore joins words within one level, so
it maps to `spree/bank_payments` → `Spree::BankPayments` — gem name, require path
and constant all agree.

The *domain* vocabulary deliberately stays "bank transfer", because that is what
the payment instrument is: `Spree::PaymentSessions::BankTransfer`,
`Spree::Admin::BankTransfersController`, `IncomingTransfer`, `TransferData`. Only
the gem namespace is `BankPayments`.

Because Bundler auto-requires a gem by its *name*, `lib/spree-bank_payments.rb`
exists as a one-line shim requiring `spree/bank_payments`, so host apps need only
`gem 'spree-bank_payments'` with no `require:` option.

Note `engine_name` stays `spree_bank_payments`: it generates route helper prefixes
and the `spree_bank_payments:install:migrations` rake task, so it must be a valid
Ruby identifier and cannot take a dash.

Target: Spree 5.6, Rails 8.1, Ruby 4.0.

### Out of scope for v1

- Open Banking / pay-by-bank providers (evaluated and deferred; see Alternatives)
- Orders edited after placement (amount mismatch simply queues)
- Partial payment auto-application (admin uses Spree's existing payment tools)
- Automated refunds for overpayment

## Decisions

| Decision | Choice |
|---|---|
| Stock while payment outstanding | Reserved at order completion; auto-cancel and restock on expiry |
| Expiry window | `preference :expiry_days` on the payment method |
| Discount mechanism | Gem-owned `Spree::Adjustment`, not a promotion rule |
| Discount base | `order.item_total` — never `order.total` |
| Matching | Exact reference + amount + currency to auto-apply; fuzzy fallback *suggests* only |
| Packaging | Two gems, published reconciler contract |
| RSA private key | ENV / AWS Secrets Manager (`N27a/<slug>` bundle) |
| Refresh token | Payment method preference — must be writable when rotated |
| Non-secret config | Payment method preferences |

## Architecture

### Data model

**`Spree::PaymentSessions::BankTransfer`** — STI subclass of
`Spree::PaymentSession`. Inherits the `pending → completed/failed/canceled/expired`
state machine, `find_or_create_payment!`, and per-order uniqueness of
`external_id`. `external_id` holds the payment reference. No new table.

**`spree_bank_payments_incoming_transfers`** — one row per transfer observed,
matched or not. Serves as audit log, admin queue, and replay guard.

| Column | Notes |
|---|---|
| `provider` | e.g. `revolut` |
| `provider_transaction_id` | Unique with `provider` — the idempotency guard |
| `amount`, `currency` | As reported by the provider |
| `reference_raw` | Exactly as the payer typed it |
| `reference_normalized` | Indexed; upcased, non-alphanumerics stripped |
| `payer_name` | For fuzzy suggestion |
| `occurred_at` | Provider timestamp |
| `state` | `unmatched` / `applied` / `ignored`. `applied` covers both automatic and manual application; `applied_by_id` present means a human applied it |
| `payment_session_id` | Nullable FK |
| `applied_by_id`, `applied_at` | Audit trail for manual application |
| `raw_payload` | jsonb |

**`spree_bank_payments_reconciler_states`** — one row per payment method:
`last_successful_run_at`, `last_error`, `consecutive_failures`. Held in
Postgres, not Redis: the health gate must survive a cache flush, because a
wrongly-empty cache would silently re-enable auto-cancel.

### Order lifecycle

1. Customer selects Bank Transfer at the payment step. Discount adjustment
   applied while the order is still mutable.
2. Order completes. Spree allocates inventory units as normal — stock
   reservation requires no additional code. Session created with the reference
   and `expires_at = now + expiry_days`. Order sits `payment_state: balance_due`,
   `shipment_state: pending`.
3. Reconciler observes a transfer → `IncomingTransfer` row → match →
   `payment_session.complete` → `payment.complete!` → order `paid`,
   shipment `ready`.
4. Expiry passes unpaid **and** reconciler healthy → cancel, restock, notify.
   Reconciler unhealthy → skip and alert.

### Reconciler contract

```ruby
poll(since:)                      # → Array<TransferData>
parse_webhook(raw_body, headers)  # → TransferData or nil; raises SignatureError
healthy?                          # → bool
configured?                       # → bool
```

`TransferData(provider_transaction_id:, amount:, currency:, reference:,
payer_name:, occurred_at:, raw:)` is a plain value object. **Both ingress paths
return it**, so matching is written once and webhook and poll cannot drift
apart.

### Ingestion

`IngestTransfer` service:

1. `find_or_create_by!(provider:, provider_transaction_id:)` against the unique
   index. Duplicate delivery via both paths is expected, not exceptional.
2. Return early if already `applied`.
3. Normalize reference, attempt match.
4. Auto-apply only on exact normalized reference **and** exact amount **and**
   exact currency, against a session still `pending` or `processing`.
5. Otherwise leave `unmatched` and compute suggestions.

Application runs in a transaction; `IncomingTransfer` moves to `applied` only
after commit, so a mid-transition failure leaves the row re-processable rather
than half-applied.

### Matching and suggestions

Normalization upcases and strips non-alphanumerics on both sides, so
`tkf 7q4x2` → `TKF7Q4X2`.

Suggestions for unmatched rows (never auto-applied): exact amount + currency
against open sessions, plus trigram similarity between `payer_name` and the
order's bill address name. Requires `enable_extension 'pg_trgm'`. If the
extension is unavailable, suggestions degrade to amount-only rather than
raising.

### Reference generation

Six characters of Crockford base32 from a CSPRNG (~1bn space), prefixed by a
store preference (e.g. `TKF-`). `PaymentSession` only enforces `external_id`
uniqueness per order and method, but matching needs **global** uniqueness within
the payment method, permanently — a late payment quoting an old reference must
resolve to exactly one session. Generate-and-retry against that constraint.

### Ingress paths

**Webhook** — reuse Spree's `/api/v3/webhooks/payments/:prefixed_id`
(`spree_api`, `app/controllers/spree/api/v3/webhooks/payments_controller.rb`),
inheriting rate limiting, synchronous signature verification, and async
handoff. That controller assumes every webhook maps to a payment session; ours
sometimes will not. The `IncomingTransfer` is persisted inside
`parse_webhook_event` and `nil` returned for unmatched, which the controller
treats as acknowledge-receipt.

**Poll** — Sidekiq cron at a preference-controlled interval, default 15
minutes, querying `since: last_successful_run_at - 2.hours`. The overlap is
free because ingestion is idempotent, and it closes the gap when Revolut
exhausts its three webhook retries. **Polling is the correctness guarantee;
webhooks are a latency optimisation.**

### Health gate

`healthy?` is true when `last_successful_run_at` falls within three poll
intervals. The expiry job checks it before cancelling and alerts instead when
false.

This exists because Revolut's credential lifecycle is fragile and imperfectly
documented: access tokens are short-lived (~40 minutes on the Business API) and
consent may require periodic manual re-authorisation. Public documentation
conflates the Business API (`manage-accounts`) with the Open Banking API
(`build-banking-apps`), which have different lifecycles.
**Open item: confirm the actual certificate and consent expiry on the Business
API settings page in Revolut Business before implementation.**

The gate makes the answer non-critical: whatever the real expiry, a lapse
produces an alert rather than wrongly-cancelled orders for customers who paid.

### Credentials

- **RSA private key** — ENV / ASM. Static, never rotates in-band.
- **Refresh token** — payment method preference. Must be writable, because
  ENV cannot be updated when the provider rotates it.
- **Account IDs, expiry days, discount percent, poll interval** — preferences.

Secrets resolve from ENV when present, falling back to preferences, so any
Spree store can install the gem without an ASM setup.

Access tokens use lazy refresh — checked before each call against a 5-minute
expiry buffer, behind a Redis mutex to prevent a refresh stampede across Sidekiq
workers. Cron is explicitly *not* used for token refresh: a fixed tick drifts
out of phase with usage and still cannot prevent mid-job expiry.

Consent re-authorisation cannot be automated — it is an OAuth authorization-code
flow requiring a human in the Revolut UI. A cron job tracks consent age and
alerts at T-14 / T-7 / T-1 days.

## Discount

`preference :discount_percent`, default `0`, validated `0..100`, so the gem is
usable with no discount at all.

On selection at the payment step, create a `Spree::Adjustment` on the order with
`source` set to the payment method and `amount = -(order.item_total * pct / 100)`.
Sourcing from the payment method rather than a promotion action prevents Spree's
promo recalculation from clearing it.

**The adjustment must be removed when the customer switches payment method**,
or they keep the discount while paying by card.

Base is `order.item_total`, never `order.total`: `order.total` is gross, rolls in
shipping and tax, and does not account for VAT correctly on tax-inclusive stores.

Selecting the method visibly changes the order total. Mitigate in the label —
"Bank Transfer — save 3%" — so it reads as a reward rather than a glitch, and
re-render the order summary on selection.

Legal framing: surcharging consumer cards is prohibited in the UK/EU. A discount
for bank transfer is the compliant framing and must stay worded that way.

## Customer-facing flow

Payment step shows the discount, the payment window, and that dispatch follows
cleared funds.

Confirmation page and email carry account name, IBAN / sort code + account
number, BIC, the exact amount, the deadline, and the reference in a copyable
field. The reference must be visually prominent — match rate depends on
customers using it.

Notifications at T-2 and T-1 days, then a cancellation notice on expiry.

**Notification delivery must be event-first.** TKF does not send via
ActionMailer; it emits Spree webhooks that the storefront converts to Resend
sends. The gem publishes Spree events — `bank_transfer.instructions_ready`,
`.reminder_due`, `.expired` — as the primary mechanism, and ships a default
mailer that stores can disable. A mailer-only implementation would deliver
nothing on TKF.

## Admin surfaces

1. **Payment method config** — preferences, plus a configuration guide partial
   rendering the webhook URL to paste into Revolut and live reconciler health
   (last successful poll, last error, credential expiry warning). Mirrors the
   `spree_paypal_checkout` config guide.
2. **Unmatched transfers queue** — the surface that decides whether this is
   operable. Lists unmatched rows with amount, payer, reference, date; ranked
   order suggestions; apply-to-order and ignore-with-reason actions. Manual
   applications record `applied_by` and `applied_at`. Required in v1, not a
   follow-up: without it every mistyped reference is a support ticket with no
   tool behind it.
3. **Order detail** — reference, expiry countdown, linked transfer once matched.

## Error handling

Governing rule: **auto-apply demands certainty, everything else queues, and we
never cancel while blind.**

| Condition | Response |
|---|---|
| Bad webhook signature | 401, nothing persisted |
| Provider unreachable / credentials lapsed | `consecutive_failures`++, `last_error` recorded, health gate flips, expiry paused, alert |
| Token refresh stampede | Redis mutex, single-flight |
| Same transfer via webhook and poll | Unique index → no-op |
| Under / over payment, wrong currency | Queue |
| Payment against expired or cancelled session | Queue — never auto-apply to a restocked order |
| Reference matches nothing | Queue with suggestions |
| Two sessions share a normalized reference | Refuse, queue, log |
| Order total changed post-placement | Amount mismatch → queue |
| Sidekiq cron stopped | `last_successful_run_at` goes stale → gate flips → expiry pauses |
| `pg_trgm` unavailable | Suggestions degrade to amount-only |

## Testing

RSpec with `spree_dev_tools`, mirroring the `spree_paypal_checkout` CI setup.

**Core exports a shared example group** — `it_behaves_like 'a bank transfer
reconciler'` — which the Revolut gem runs against its implementation. The
contract test travels with the contract, so an interface change breaks the
dependent gem's build loudly rather than in production. This is most of what
makes the two-gem split safe.

- Table-driven specs over reference normalization: case, spacing, punctuation,
  truncation.
- Revolut client against recorded WebMock fixtures with known-good signature
  vectors. No live API calls in CI.
- One explicit test per money edge case asserting **no auto-apply**.
- Idempotency: ingest the same transfer via both paths, assert one payment.
- **The most important test in the suite: the expiry job does not cancel orders
  when the reconciler is unhealthy.** If that regresses, paying customers lose
  orders silently — invisible and unrecoverable.

## Alternatives considered

**Open Banking pay-by-bank** (TrueLayer, GoCardless Instant Bank Pay, Yapily) —
similar fee economics with a definitive authorization callback, no reference
matching, no unmatched queue, no sweeper. A conventional gateway integration
instead of a reconciliation system. Deferred rather than rejected; worth
revisiting if operational load on the unmatched queue proves higher than
projected.

**Revolut Merchant API** — card acquiring / Revolut Pay. A normal gateway with
normal card fees; saves nothing. Rejected for this purpose.

**Single gem with internal adapters** — less release overhead, but does not
establish the multi-provider foundation. Rejected in favour of the two-gem split.

**Promotion rule for the discount** — reuses Spree's promo engine, but requires
per-store setup and interacts unpredictably with other active promotions.
Rejected in favour of the gem-owned adjustment.

## Commercial note

Revolut inbound GBP/EUR transfers are effectively free against ~1.5–2.9% on
cards — roughly £1.20 saved on a £60 order. Bank transfer converts materially
worse than card, settles 0–2 days later, and generates payment-status support
load. The economics are strong for B2B/wholesale and high-AOV, weaker for D2C
checkout. Set `discount_percent` below the fee delta or the incentive costs more
than it saves.

## Implementation sequencing

This spec is too large for a single implementation plan and splits cleanly along
the gem boundary. Each phase gets its own plan.

**Phase 1 — `spree_bank_payments`.** Payment method and preferences, payment
session subclass, reference generation, discount adjustment, `IncomingTransfer`
and `ReconcilerState` models, `Reconcilers::Base` plus `Manual`, the shared
example group, expiry job and health gate, notification events, all three admin
surfaces, **and both ingress paths** — the gateway's `parse_webhook_event` and
the poll job. Both are bank-agnostic orchestration: they call the reconciler and
feed `IngestTransfer`, and the `Manual` reconciler renders them harmless no-ops.
Ships a complete, useful product on its own: a store can accept bank transfer
and mark payments received by hand.

**Phase 2 — `spree-bank_payments_revolut`.** Revolut client with lazy token
refresh, webhook signature verification, the reconciler implementation run
against Phase 1's shared example group, and the consent-expiry alert job. Phase
2 supplies an adapter; it adds no orchestration.

Phase 1 must be complete and its contract stable before Phase 2 begins, since
Phase 2 consumes a published interface.

## Open items

1. Confirm actual certificate / consent expiry on the Revolut Business API
   settings page. Does not block design — the health gate makes it
   non-critical — but should be settled before implementing token handling.
2. Confirm the Revolut webhook payload carries the payment reference, or whether
   a follow-up `GET /transactions/{id}` is required to read the legs.
   `developer.revolut.com` blocks automated fetching, so this needs a manual
   read of the docs.
3. ~~Confirm the gem name is available on RubyGems.~~ **Settled 2026-08-16** —
   no spelling of `bank_transfer` is obtainable: `spree_bank_transfer` and
   `spree-bank-transfer` are held by unrelated owners, and `spree-bank_transfer`
   is refused as too similar to the latter (see Naming, above). Released as
   `spree-bank_payments`, verified free across all punctuation permutations, with
   the module renamed to `Spree::BankPayments`.

## References

- [Revolut Business API](https://developer.revolut.com/docs/business/business-api)
- [About webhooks](https://developer.revolut.com/docs/guides/manage-accounts/webhooks/about-webhooks)
- [Verify the payload signature](https://developer.revolut.com/docs/guides/manage-accounts/webhooks/verify-the-payload-signature)
- [Retrieve transactions](https://developer.revolut.com/docs/business/get-transactions)
