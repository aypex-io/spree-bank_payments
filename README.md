# spree-bank_payments

Bank transfer checkout for Spree 5.6+, with pluggable reconciliation of
incoming payments.

## Requirements

PostgreSQL. The gem uses `jsonb`, partial unique indexes, and `pg_trgm`.

## Installation

```ruby
gem 'spree-bank_payments'
```

```bash
bundle install
bin/rails g spree:bank_transfer:install
```

The generator copies the migrations and then asks whether to run them. Pass
`--auto-run-migrations` to skip the prompt (useful in scripted installs).

## Configuration

Add a Bank Transfer payment method in the Spree admin and set:

| Preference | Purpose |
|---|---|
| `reconciler` | `manual` by default; `revolut` with `spree-bank_payments_revolut` installed |
| `reference_prefix` | Prefix on generated references, e.g. `TKF-` |
| `expiry_days` | Days before an unpaid order is cancelled and restocked |
| `discount_percent` | Percentage off `item_total` for paying by transfer |
| `poll_interval_minutes` | How often the reconciler polls; drives the health gate |
| `account_*` | **Deprecated.** Pre-5.2 flat bank details. On upgrade these are folded automatically into one offered `BankAccount` for the store's default currency (see below) — do not set them on a fresh 5.2+ install; use the bank accounts screen instead. |

## Bank accounts and currencies

As of 5.2.0, bank details live on `Spree::BankPayments::BankAccount` rows —
one per currency you accept, not one flat set of preferences shared by
every order regardless of currency.

- **One account per currency.** Each account records a `currency` and one
  or more *detail sets* (a local scheme and an international/SWIFT set are
  both common). Multiple accounts can exist for the same currency, but at
  most one can be **offered** at a time — the customer-facing one.
- **Customers always see every detail set on the offered account** — local
  and international both, side by side. The gem deliberately does **not**
  infer which one a customer needs from their billing country: that would
  require a maintained SEPA-membership list (and it changes), and guessing
  wrong hides the details the customer actually needed, costing them a
  bounced transfer or a correspondent fee with no explanation. Let them
  choose; they know where they bank.
- **Admin checklist:** the bank accounts screen under the payment method
  lets an admin toggle at most one *offered* account per currency. This is
  enforced by a partial unique database index
  (`index_bp_bank_accounts_on_pm_and_currency_offered`), not just a form
  validation — a second offered row for the same currency cannot exist,
  even written directly against the database.
- **Every synced account stays watched (polled or webhooked) regardless of
  whether it is offered.** This is what makes switching the offered account
  safe: quote a customer against GBP account A, later switch the offered
  GBP account to B — new sessions quote B, but A is still polled, so a
  transfer that arrives late into A still reconciles automatically against
  the session it was actually quoted on. No cutover window, no "don't
  switch until the last order clears."
- **A currency with no offered account means bank transfer is not
  available for that currency.** `available_for_order?` returns `false`
  and the method drops out of checkout for that currency — unless the
  order already holds an open session against this gateway in the same
  currency, in which case availability is kept so that order can still be
  paid. This is easy to reach by accident: **the first sync leaves every
  account unchecked**, so bank transfer is unavailable in every currency
  until an admin offers at least one account. The admin screen states this
  plainly.
- **Two sync triggers:**
  1. A **"Sync from &lt;provider&gt;"** button in the payment method admin,
     which always shows a diff for confirmation before applying it.
  2. **Consent re-approval**, for providers whose credentials need periodic
     re-authorisation (e.g. an OAuth consent that expires every ~90 days).
     A provider gem can call `SyncAccounts.new(payment_method:).apply!(additive_only: true)`
     from its callback handler; `additive_only` applies new accounts and
     refreshed details immediately but always skips deactivations, since a
     currency should never be withdrawn from the storefront mid-redirect
     with nobody looking at a diff.

  In both cases, **sync never sets `offered`** (that decision stays with a
  human, including on the very first sync) and **never touches
  `bank_account_id` on an existing session** — a historical quote is
  immutable, because changing what a customer was told after the fact
  makes a dispute unwinnable.
- **Soft-deleted accounts are not resurrected by sync.** `BankAccount` is
  `acts_as_paranoid`; deleting one from the admin is a soft delete, so a
  session that already quoted it keeps rendering the coordinates. If a
  later sync reports the same provider account again, it is **not**
  silently recreated — it's surfaced as `skipped` in the sync diff, visible
  rather than silently reappearing behind an admin's back.
- **Failed or empty sync leaves every account untouched.** If
  `sync_accounts` raises, times out, or returns an empty array while
  accounts already exist, the whole sync aborts with no writes — an auth
  failure must never be read as "every account disappeared."
- **`pooled` marks an account whose coordinates are shared.** Some providers
  hand every customer the same IBAN and separate the payers by reference
  alone. A provider reports this through `AccountData#pooled` (default
  `false`, so a provider that never sets it behaves exactly as before) and
  it is shown as a **Pooled** badge on the bank accounts screen. It changes
  nothing about auto-apply — that has always required an exact normalized
  reference match, on every account — but it changes how a human must read
  the unmatched queue. Suggestions there are ranked partly on fuzzy
  payer-name similarity, and on a pooled account a plausible name is not
  evidence of who paid: two unrelated customers arrive on identical
  coordinates. The queue therefore warns when a transfer landed on a pooled
  account, and the reference is the thing to verify before applying.

### Writing a provider's `sync_accounts`

`sync_accounts` returns `Array<Spree::BankPayments::AccountData>`, each
carrying `provider_account_id`, `currency`, and `details` in the same
normalised detail-set shape `BankAccount#details` stores — never the
provider's raw response shape.

`details` is an ordered list of detail-set **objects**. Each has an optional
`label`, `schemes`, and `beneficiary_name`, plus `fields`: an ordered list of
`{ 'label' => …, 'value' => … }` **objects** (not `[label, value]` pairs —
each field is a hash with a `label` key and a `value` key). Fields are
label/value rather than named keys because bank coordinates are not
standardised: a sort code in the UK, a routing number in the US, something
else again in Poland. The views render them generically, so a market the gem
has never heard of needs no code change.

```ruby
def sync_accounts
  [
    Spree::BankPayments::AccountData.new(
      provider_account_id: 'acct_9f2c',
      currency: 'GBP',
      details: [
        {
          'label' => 'UK payments',
          'schemes' => ['faster_payments'],
          'beneficiary_name' => 'Example Store Ltd',
          'fields' => [
            { 'label' => 'Sort code',      'value' => '04-00-75' },
            { 'label' => 'Account number', 'value' => '12345678' }
          ]
        },
        {
          'label' => 'International',
          'schemes' => ['swift'],
          'fields' => [
            { 'label' => 'IBAN', 'value' => 'GB00REVO00000000000000' },
            { 'label' => 'BIC',  'value' => 'REVOGB21' }
          ]
        }
      ]
    )
  ]
end
```

`provider_account_id` must be present and stable — it is the key sync
reconciles on. A report with a blank id is skipped rather than applied,
because it cannot be matched to a row without risking overwriting a
hand-created account. An account whose detail sets contain no usable field
is skipped too; both appear under `skipped` in the sync diff.

See "Writing a reconciler" below for the full contract, including the shared
example group that exercises this method's return type.

## The admin queue and the manual workflow

The gem adds a **Bank transfers** entry to the Spree admin sidebar, pointing
at `/admin/bank_transfers`. That screen is the operational heart of the gem:

- **The unmatched queue** (`/admin/bank_transfers`) lists every observed
  transfer that hasn't been matched to an order, with suggested sessions
  ranked by exact amount first and fuzzy payer-name similarity second. Apply
  a suggestion in one click, or ignore the transfer with a reason.
- **Record a received transfer** (`/admin/bank_transfers/new`) is how money
  gets into the system when you're not running a provider integration. This
  is **required reading if you use the default `manual` reconciler**: it has
  nothing to poll and no webhook, so this form is the only way a transfer can
  ever be recorded. You enter the payment method, amount, currency, payer
  name, the reference as the customer quoted it, and the date received; the
  entry then goes through exactly the same matching path as a
  provider-delivered transfer. An exact match (reference, amount, currency,
  against a single open session on an unpaid order) applies immediately and
  marks the order paid. Anything else lands in the queue above.

  Submitting the same form twice is safe: the transfer's identity is derived
  from what you typed, so a resubmission is recognised as the same transfer
  and nothing is credited twice.

  The same derivation has a flip side. Two genuinely separate transfers that
  match on every recorded field — payment method, amount, currency, reference,
  payer name and date received — are treated as one, and only the first is
  credited. If a customer really did send the same amount twice on the same day,
  record the second with something that distinguishes it (the payer name exactly
  as it appears on that transfer, for instance) so it is not collapsed into the
  first.

- **Applying to a mismatched order** takes two deliberate steps. The first
  click is refused with both amounts spelled out; only then does an explicit
  "Yes — apply … anyway" control appear for that specific pairing, behind a
  confirmation dialog. A mismatch is credited for the amount that actually
  arrived, so the order lands in `balance_due`/`credit_owed` rather than a
  false `paid`.

### The order panel partial

`spree/bank_payments/admin/_order_panel` renders the bank-transfer state for
a single order — reference, amount, status, expiry, and the matched transfer
if there is one. The gem does **not** inject it anywhere; render it from your
admin order view where it makes sense for your store:

```erb
<%= render 'spree/bank_payments/admin/order_panel', order: @order %>
```

## Scheduling

These scheduled jobs are mandatory, not optional — without them nothing
expires and no reminders send:

| Job | Frequency | Purpose |
|---|---|---|
| `Spree::BankPayments::ExpireSessionsJob` | Hourly | Cancels and restocks orders whose payment window has lapsed |
| `Spree::BankPayments::SendRemindersJob` | Daily | Sends payment reminders as the expiry deadline approaches |
| `Spree::BankPayments::PollJob` | Every `poll_interval_minutes` (default 15) | Polls the configured reconciler for new transfers; a successful run is what arms the health gate below |

Wire all three into your scheduler (`sidekiq-cron`, `whenever`, etc.) as part
of installing this gem, not as an afterthought.

## The health gate

`ExpireSessionsJob` refuses to cancel orders when the reconciler has not
polled successfully within three poll intervals (`poll_interval_minutes`).
This matters because expiry and reconciliation are decoupled: if a bank
credential lapses or a webhook silently stops arriving, the reconciler stops
confirming payments, but orders keep aging past their expiry window. Without
the gate, `ExpireSessionsJob` would start cancelling and restocking orders
for customers who have already paid — just because the gem couldn't see the
payment. Instead, a stale reconciler raises an alert and the job cancels
nothing.

Subscribe to `bank_transfer.reconciler_unhealthy` and route it somewhere a
human will see it. A lapsed credential is an operational incident, not
background noise.

`ExpireSessionsJob` also leaves alone any order that has already been paid by
other means — a customer who abandons the transfer and pays by card keeps a
stale open session, and cancelling it would cancel and restock a paid order.
Those sessions are closed as `canceled` and
`bank_transfer.session_superseded` is published instead. For the same reason
a transfer that arrives against an already-paid order is never auto-applied:
it queues for a human, because a second payment on a settled order is a
decision, not a reconciliation.

## Events

The gem never sends notifications directly — it publishes to
`Spree::Events`, and subscribers decide what to do:

| Event | Fired when |
|---|---|
| `bank_transfer.instructions_ready` | A payment session is created and the customer needs the reference/bank details |
| `bank_transfer.reminder_due` | An unpaid session is approaching its expiry deadline |
| `bank_transfer.expired` | `ExpireSessionsJob` cancels an unpaid order |
| `bank_transfer.session_superseded` | An open session is closed because its order was already paid another way — the order is left alone |
| `bank_transfer.reconciler_unhealthy` | The health gate trips (see above) |
| `bank_transfer.expiry_failed` | `ExpireSessionsJob` hits an error cancelling a specific session |

Payloads contain serializable primitives only — never AR objects — because
subscribers may run async via ActiveJob. See
`Spree::PaymentSessions::BankTransfer#notification_payload` for the exact
shape. Subscribe with `Spree::Events.subscribe('bank_transfer.*', MyHandler)`
or to individual event names.

A bundled mailer subscribes to `instructions_ready` and `reminder_due` as one
optional subscriber among possibly several. Disable it with:

```ruby
Spree::BankPayments::Config.disable_default_mailer = true
```

Stores that deliver mail another way — for example a storefront webhook
handler that calls out to Postmark/Resend/etc. rather than using
ActionMailer — should disable the default mailer and subscribe to the events
directly instead of fighting the bundled one.

## Tax, and stacking with promotions

The discount is applied as one `Spree::Adjustment` per **line item** (sourced
from the payment method, not a promotion action), allocated proportionally to
each line's amount and reconciled with largest-remainder rounding so the parts
sum to exactly `-(item_total * discount_percent / 100)` — to the cent.

Because they are line-item adjustments, they reach Spree's
`taxable_adjustment_total`, so **recorded tax falls with the discount**. On a
tax-inclusive (VAT) store a 3% discount on a £100 line reduces recorded VAT
from £16.67 to £16.17. The pre-5.1 order-level adjustment did not do this — the
customer paid less while the order still recorded tax on the undiscounted
price. That is fixed.

**The discount stacks with promotions.** It is deliberately not a competing
promotion: Spree picks a single winner among competing promo adjustments, but
this is a separate concession for paying by transfer, so it is never marked
ineligible and never makes a promotion ineligible. A 20% promotion plus a 3%
transfer discount is 23% off. Set `discount_percent` with that in mind.

Base is always `item_total`, never `order.total` — the discount never applies
to shipping or tax.

## The instructions partial ships no CSS

`spree/bank_payments/_order_instructions` renders the payment reference and
bank details with no styling of its own. Making the reference visually
prominent — the single most impactful thing you can do for match rates — is
the host store's responsibility. Customers who don't notice or don't copy
the reference correctly produce transfers reconciliation can't match
automatically, which means manual admin work. Style it like the most
important line on the page, because for a bank-transfer checkout, it is.

## Writing a reconciler

Subclass `Spree::BankPayments::Reconcilers::Base` and implement the four
contract methods:

- `#poll(since:)` — returns an `Array<Spree::BankPayments::TransferData>`
- `#parse_webhook(raw_body, headers)` — returns `TransferData` or `nil`
- `#health` or `#healthy?` — see below; feeds the health gate above
- `#configured?` — boolean; whether credentials/settings are complete

`Base` also provides `#sync_accounts`, returning `[]` by default — override
it if your provider can enumerate accounts, returning an
`Array<Spree::BankPayments::AccountData>`.

### `#health`

Override either `#health` or `#healthy?` — never both, and never neither.
Each derives from the other, so a reconciler written before 5.3.0 that only
implements `#healthy?` keeps working unmodified, and a reconciler that only
implements `#health` gets `#healthy?` derived from it. Overriding neither
raises `NotImplementedError` rather than recursing.

`#health` returns one of three symbols. A boolean cannot separate a retryable
provider outage from a dead authorisation, and checkout has to treat them
differently:

| State | Meaning | Withdraws from checkout? |
|---|---|---|
| `:ok` | Reconciling normally | No |
| `:transient` | A provider outage or similar — expected to recover on its own | No — those transfers still arrive and reconcile once the provider returns |
| `:consent_revoked` | The authorisation is dead; nothing will ever reconcile against it | Yes |

`Gateway#health` is the persisted view `available_for_order?` reads on every
checkout render — it never calls the reconciler directly, so a provider's live
check never lands on the storefront's critical path. `PollJob` is what
refreshes it, reporting health after every poll through `HealthReporter`,
which logs the transition and then at most hourly while the condition
persists (WARN for `:transient`, ERROR for `:consent_revoked`, INFO on
recovery) and publishes `bank_transfer.reconciler_health.unhealthy` /
`.recovered` through `Spree::Events`.

Query the unhealthy log line with LogQL:

```logql
{namespace=~"your-ns-.*"} |= "bank_transfer.reconciler_health.unhealthy" | logfmt
```

`reason=` is drawn from a closed enum, never from an exception message or a
response body — that is how a bearer token reaches a log aggregator. The whole
vocabulary is four values:

| `reason` | Emitted when |
|---|---|
| `ok` | The poll succeeded — carried on the recovery line |
| `consent_revoked` | The reconciler reported `:consent_revoked` after a failed poll |
| `provider_error` | Any other poll failure |
| `unknown` | A reason outside this enum was passed in and was discarded |

`reason="consent_revoked"` warrants an immediate page — nothing will
reconcile until a human re-authorises it, and unpaid orders will not expire
while the gem is blind (see [The health gate](#the-health-gate)). Any other
reason should only alert after roughly thirty minutes sustained, since a brief
provider blip recovers on its own and paging on every transient hiccup trains
people to ignore the alert.

Register it:

```ruby
Spree::BankPayments::Reconcilers::Base.register('my_bank', MyBank::Reconciler)
```

and run the shared example groups against it — the base group plus
whichever "returns ..." group(s) apply to your reconciler:

```ruby
require 'spree/bank_payments/testing_support/reconciler_shared_examples'

RSpec.describe MyBank::Reconciler do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it_behaves_like 'a bank transfer reconciler'
  it_behaves_like 'a bank transfer reconciler that returns transfers'
  it_behaves_like 'a bank transfer reconciler that returns accounts'
end
```

The "returns ..." groups exist because the base group can't check element
types: a reconciler with nothing to poll or sync legitimately returns `[]`,
and any `all(be_a(...))` assertion passes vacuously against an empty array.
Each "returns ..." group requires the corresponding method to return at
least one real value and checks its shape — that's the only way to actually
exercise the type contract. Omit the accounts group if your reconciler
genuinely can't enumerate accounts (e.g. a manual/no-op reconciler) — forcing
it there would mean stubbing the class under test, which tests nothing.
