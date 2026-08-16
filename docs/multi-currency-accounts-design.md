# Multi-currency bank accounts — design spec

**Date:** 2026-08-16
**Status:** Approved, ready for implementation planning
**Target:** `spree-bank_payments` 5.2.0 (minor — new feature, backward-compatible
contract additions)

## Problem

`Gateway#bank_details` returns a single flat set of preferences — `account_name`,
`account_iban`, `account_bic`, `account_sort_code`, `account_number` — with no
currency awareness. The instructions partial and email render exactly that.

So a store holding separate GBP, EUR and USD accounts quotes **the same account to
every customer regardless of order currency**.

This is inconsistent on the gem's own terms: the payment session records `currency`,
and auto-apply requires an exact currency match, yet nothing ever quotes a
currency-appropriate account to pay into. A EUR customer is told the GBP account,
pays into it, and the money either arrives converted at an amount that cannot
exact-match, or lands in an account nothing is watching.

It affects the `Manual` reconciler too, so it is not a provider concern.

## Scope

This spec covers the **core gem only**. A separate provider gem
(`spree-bank_payments-revolut`) implements the contract additions defined here; it
is out of scope beyond the interface it must satisfy.

### Out of scope

- The Revolut adapter itself (poll, webhook verification, token handling)
- Per-account discount, expiry or reconciler settings — those stay on the payment
  method, so a three-currency store does not maintain three discount percentages
- Automatic selection of local vs international details (see Decisions)
- Currency conversion of any kind

## Decisions

| Decision | Choice |
|---|---|
| Modelling | First-class `BankAccount` records, not preference hashes or one payment method per currency |
| Detail coordinates | `jsonb`, not fixed columns — they are not standardised across countries or the EEA |
| Which details the buyer sees | **All of them**, labelled by scheme. No billing-country inference |
| Multiple accounts per currency | Allowed. Admin checklist picks at most one **offered** per currency |
| Watching vs offering | Independent. Every synced account is watched; only the offered one is quoted |
| Account disappears from provider | Deactivate, never delete |
| Failed or empty sync | Abort entirely — never mass-deactivate |
| Session/transfer linkage | Both record `bank_account_id`, nullable and advisory |

## Data model

### `spree_bank_payments_bank_accounts`

| Column | Notes |
|---|---|
| `payment_method_id` | FK, indexed |
| `provider_account_id` | Provider's identifier. Nullable — hand-created accounts have none |
| `currency` | 3-letter ISO, upcased on write |
| `details` | `jsonb`, normalised detail sets (see below) |
| `offered` | Boolean. Quoted to customers |
| `active` | Boolean. Soft disable; deactivated on provider disappearance |
| `synced_at` | Nullable. Null for hand-created accounts |
| timestamps | |

**Indexes:**

- Unique `(payment_method_id, provider_account_id)` — sync idempotency. Partial,
  `WHERE provider_account_id IS NOT NULL`, so multiple hand-created accounts are
  possible.
- **Partial unique `(payment_method_id, currency) WHERE offered`** — at most one
  offered account per currency, guaranteed by the database rather than a form
  validation.
- `(payment_method_id, active)` for the polling scope.

**Validations:** `currency` present and ISO-shaped; at least one active detail set;
each detail set has at least one non-blank field. An account with no payable
coordinates is worse than no account — the customer is quoted an empty instruction
block.

### The `details` payload

**Normalised by the reconciler, never raw provider output.** If the provider's
schema reached the database, the instructions view would have to know Revolut's
shape, and the next provider's, and the hand-entered shape.

```json
[
  {
    "label": "UK payments",
    "schemes": ["faster", "bacs", "chaps"],
    "beneficiary_name": "Example Store Ltd",
    "beneficiary_address": { "…": "…" },
    "fields": [
      { "label": "Sort code", "value": "04-00-75" },
      { "label": "Account number", "value": "12345678" }
    ]
  },
  {
    "label": "International",
    "schemes": ["swift"],
    "beneficiary_name": "Example Store Ltd",
    "fields": [
      { "label": "IBAN", "value": "GB00REVO00000000000000" },
      { "label": "BIC", "value": "REVOGB21" }
    ]
  }
]
```

`fields` is an **ordered list of label/value pairs**, not named keys. Coordinates
are not standardised — the UK uses sort code and account number, the US a routing
number, Poland's Elixir something else again. Named columns or fixed keys would mean
a migration per market. The view renders pairs generically and never needs to know
what a routing number is.

### Session and transfer linkage

`Spree::PaymentSessions::BankTransfer` gains **`bank_account_id`** — the account the
customer was actually quoted. `IncomingTransfer` gains the same, resolved from the
`provider_account_id` the transaction arrived in.

The gem already adds `external_id_normalized` to `spree_payment_sessions` behind a
partial index scoped to its STI type; this follows that precedent rather than setting
a new one.

Both are **nullable and advisory**:

- A transfer whose account disagrees with its session's still **queues** rather than
  auto-applying, and the queue names both accounts.
- A session with no recorded account — legacy rows, or the `Manual` reconciler —
  matches exactly as it does today.

Making it mandatory would break the `Manual` path, which has no accounts at all.

## Quoting and availability

`Gateway#bank_details_for(currency)` returns the **offered** account for that
currency.

`#bank_details` is **kept as a deprecated shim** returning the offered account for
the store's default currency, with a one-time warning. Removing a public method
would be a breaking change, and this is a minor release — anything already calling
it (a host's custom view, another extension) must keep working. It goes in the same
major that drops the flat preferences.

`Gateway#available_for_order?(order)` returns **false** when no offered, active
account exists for the order's currency. Bank transfer simply is not presented,
rather than being presented and failing at session creation or quoting nothing.
Unchecking every GBP account withdraws the method for GBP orders — the safe
direction, and visible in the admin checklist rather than surprising.

**The buyer always sees every active detail set**, labelled by scheme, in both the
instructions email and the order screen. Local versus international is the buyer's
choice, not ours: they know where they bank. Inferring it from billing country would
require a maintained SEPA membership list (~36 countries, and it changes), and
guessing wrong hides the details the customer actually needed — costing them a
correspondent fee or a bounced transfer, with nothing explaining why.

## Reconciler contract additions

All backward compatible with the contract published in 5.1.1.

**`sync_accounts` → `Array<AccountData>`.** New value object crossing the gem
boundary: `provider_account_id`, `currency`, `details` (in the normalised shape
above). `Reconcilers::Base` returns `[]`; `Manual` returns `[]`. Existing providers
keep working untouched.

**`TransferData` gains `provider_account_id`**, defaulting to `nil`. The custom
initializer is keyword-only, so adding an optional member breaks no existing
construction — a provider written against 5.1.1 still compiles.

**`poll(since:)` keeps its signature.** Per-account fetching stays the provider's
business: it knows its own accounts and can batch however its API prefers. Each
returned `TransferData` is tagged with the account it came from. Core stays out of
provider pagination.

The exported shared example groups gain coverage for `sync_accounts` returning an
Array of `AccountData`, so provider authors get the same loud build failure on drift
that the existing contract methods already give them.

## Sync flow

**Two triggers:**

1. **"Sync from Revolut" button** in the payment method admin — always shows a diff
   for confirmation.
2. **Consent re-approval.** Revolut Business production consent needs
   re-authorisation roughly every 90 days, and the gem must handle that OAuth
   callback anyway to capture the refresh token. Syncing there means bank details
   refresh at exactly the moment credentials are known-good, turning a quarterly
   chore into an upkeep mechanism. This trigger **auto-applies additive changes**
   (new accounts, refreshed details) but still requires confirmation for
   deactivations — additive changes cannot lose anything; deactivations can withdraw
   a currency, and that must not happen mid-redirect.

**The diff.** `SyncAccounts` calls `reconciler.sync_accounts`, then classifies:
new accounts create (not offered by default), changed details update, accounts absent
from the response deactivate, unchanged no-op. Applied in one transaction, stamping
`synced_at`.

**Sync never touches `bank_account_id` on existing sessions.** Historical quotes are
immutable; changing what a customer was told after the fact makes a dispute
unwinnable.

**Sync never sets `offered`.** That is the admin's checklist, always — including the
very first sync, where every account arrives unchecked and bank transfer is
therefore unavailable until someone chooses. That is deliberate: which account a
business receives money into is not a decision the gem should make on its behalf,
and an unchecked list is visibly incomplete in a way that a silently auto-selected
account is not. The admin screen states plainly that no currency is offered yet.

### The guard that matters most

If `sync_accounts` raises, times out, or returns empty **while accounts already
exist**, abort the entire sync. Auth expiry is the likely cause, and treating an
empty response as "everything disappeared" would deactivate every account in one
pass — silently withdrawing bank transfer from the storefront for every currency.
Three lines of guard against the highest-consequence failure in this flow.

### Switching accounts is a non-event

Offered and watched are independent: **every synced, active account is polled
regardless of `offered`.**

Switch GBP from account A to B and new sessions quote B, existing sessions still
carry `bank_account_id` pointing at A, and A is still polled — so those customers'
transfers still reconcile automatically. No cutover window, no orphaned orders, no
"don't change this until the last order clears".

An account that genuinely disappears from the provider stops being pollable, but its
historical sessions remain hand-applicable through the admin queue.

## Admin

Accounts are managed under the payment method, alongside the existing configuration
guide.

- **Checklist** of synced accounts with an "offered" toggle, constrained to one per
  currency.
- **Manual CRUD** for accounts and detail sets. This is **required, not optional**:
  the `Manual` reconciler returns no accounts and is both the default and the only
  thing core ships, so without hand entry a core-only store has no way to tell
  customers where to pay.
- Synced accounts are read-only apart from `offered` and `active`; hand-created ones
  are fully editable.
- Deactivating rather than deleting matters: a session quoted against a retired
  account must still render what the customer was told.

## Migration from the flat preferences

The five `account_*` preferences are superseded. A data migration folds them into a
single `BankAccount` for the store's default currency, marked `offered`, when any are
present. `bank_details_for` falls back to reading them if no rows exist at all, with
a one-time deprecation warning.

An existing install keeps quoting exactly what it quoted before. The preferences are
removed in a later major.

## Error handling

| Condition | Response |
|---|---|
| `sync_accounts` raises, times out, or returns empty with rows present | Abort sync; no writes; surface the error |
| Provider returns an account with no usable details | Skip it, report in the diff — never create an unpayable account |
| Transfer arrives in an account the session was not quoted against | Queue, naming both accounts |
| No offered account for an order's currency | Method not offered; `available_for_order?` false |
| Two accounts offered for one currency | Impossible — partial unique index |
| Account disappears from provider | Deactivate; historical sessions still hand-applicable |

## Testing

Beyond CRUD and the quoting path:

- **The switch scenario, end to end.** Quote against GBP-A, un-offer A and offer B,
  confirm a transfer into A still auto-applies and a new session quotes B. This is
  the design's central claim and must be proven, not assumed.
- **Failed and empty sync leave every account untouched** — mutation-tested, because
  the guard is three lines and its absence is catastrophic.
- Two GBP accounts, one offered: the database rejects a second offered row.
- No offered account for a currency → method absent from checkout.
- `Manual` reconciler with hand-created accounts quotes correctly and syncs nothing.
- Legacy flat preferences migrate to one offered default-currency account and quote
  identically to before.
- A transfer into a non-offered but still-watched account reconciles.
- Detail sets render generically — a fabricated country with unfamiliar field labels
  renders without the view knowing them.

## Open items

1. Whether an incoming Revolut transfer carries the payer's typed reference in
   `data.reference` or in `legs[].description`. The documented example is an outgoing
   payment, so it does not settle the incoming case. One real sandbox webhook
   answers it. Affects the Revolut adapter, not this spec.
2. Whether any store needs more than one *offered* account per currency. Assumed no;
   the partial unique index makes it a deliberate future decision rather than an
   accident.
