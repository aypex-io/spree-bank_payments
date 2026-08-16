# aypex_bank_transfer

Bank transfer checkout for Spree 5.6+, with pluggable reconciliation of
incoming payments.

## Requirements

PostgreSQL. The gem uses `jsonb`, partial unique indexes, and `pg_trgm`.

## Installation

```ruby
gem 'aypex_bank_transfer', github: 'aypex-io/aypex_bank_transfer'
```

```bash
bundle install
bin/rails g aypex_bank_transfer:install
```

The generator copies the migrations and then asks whether to run them. Pass
`--auto-run-migrations` to skip the prompt (useful in scripted installs).

## Configuration

Add a Bank Transfer payment method in the Spree admin and set:

| Preference | Purpose |
|---|---|
| `reconciler` | `manual` by default; `revolut` with `aypex_bank_transfer_revolut` installed |
| `reference_prefix` | Prefix on generated references, e.g. `TKF-` |
| `expiry_days` | Days before an unpaid order is cancelled and restocked |
| `discount_percent` | Percentage off `item_total` for paying by transfer |
| `poll_interval_minutes` | How often the reconciler polls; drives the health gate |
| `account_*` | Bank details shown to the customer |

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

- **Applying to a mismatched order** takes two deliberate steps. The first
  click is refused with both amounts spelled out; only then does an explicit
  "Yes — apply … anyway" control appear for that specific pairing, behind a
  confirmation dialog. A mismatch is credited for the amount that actually
  arrived, so the order lands in `balance_due`/`credit_owed` rather than a
  false `paid`.

### The order panel partial

`aypex_bank_transfer/admin/_order_panel` renders the bank-transfer state for
a single order — reference, amount, status, expiry, and the matched transfer
if there is one. The gem does **not** inject it anywhere; render it from your
admin order view where it makes sense for your store:

```erb
<%= render 'aypex_bank_transfer/admin/order_panel', order: @order %>
```

## Scheduling

These scheduled jobs are mandatory, not optional — without them nothing
expires and no reminders send:

| Job | Frequency | Purpose |
|---|---|---|
| `AypexBankTransfer::ExpireSessionsJob` | Hourly | Cancels and restocks orders whose payment window has lapsed |
| `AypexBankTransfer::SendRemindersJob` | Daily | Sends payment reminders as the expiry deadline approaches |
| `AypexBankTransfer::PollJob` | Every `poll_interval_minutes` (default 15) | Polls the configured reconciler for new transfers; a successful run is what arms the health gate below |

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
AypexBankTransfer::Config.disable_default_mailer = true
```

Stores that deliver mail another way — for example a storefront webhook
handler that calls out to Postmark/Resend/etc. rather than using
ActionMailer — should disable the default mailer and subscribe to the events
directly instead of fighting the bundled one.

## Known limitations

**The discount does not affect tax on a tax-inclusive (VAT) store.**

`discount_percent` is applied as a single order-level `Spree::Adjustment`
against `order.item_total`. Spree computes `taxable_adjustment_total` by
summing tax-relevant adjustments on *line items and shipments only* — an
order-level adjustment is never included in that sum. The practical effect:
on a VAT store, the customer pays less, but the order still records tax as
if calculated on the undiscounted price. The discount and the tax figure
disagree.

This is not a bug we plan to quietly patch later — fixing it properly means
moving the discount onto line-item adjustments, the way Spree's own
promotions do, which is a bigger change than this gem currently makes. If
your store is VAT/tax-inclusive, know this before you set a
`discount_percent`, and evaluate whether the mismatch is acceptable for your
accounting.

## The instructions partial ships no CSS

`aypex_bank_transfer/_order_instructions` renders the payment reference and
bank details with no styling of its own. Making the reference visually
prominent — the single most impactful thing you can do for match rates — is
the host store's responsibility. Customers who don't notice or don't copy
the reference correctly produce transfers reconciliation can't match
automatically, which means manual admin work. Style it like the most
important line on the page, because for a bank-transfer checkout, it is.

## Writing a reconciler

Subclass `AypexBankTransfer::Reconcilers::Base` and implement the four
contract methods:

- `#poll(since:)` — returns an `Array<AypexBankTransfer::TransferData>`
- `#parse_webhook(raw_body, headers)` — returns `TransferData` or `nil`
- `#healthy?` — boolean; feeds the health gate above
- `#configured?` — boolean; whether credentials/settings are complete

Register it:

```ruby
AypexBankTransfer::Reconcilers::Base.register('my_bank', MyBank::Reconciler)
```

and run **both** shared example groups against it — not just the first one:

```ruby
require 'aypex_bank_transfer/testing_support/reconciler_shared_examples'

RSpec.describe MyBank::Reconciler do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it_behaves_like 'a bank transfer reconciler'
  it_behaves_like 'a bank transfer reconciler that returns transfers'
end
```

The second group exists because the first can't check element types: a
reconciler with nothing to poll legitimately returns `[]`, and any
`all(be_a(...))` assertion passes vacuously against an empty array. The
second group requires `#poll` to return at least one real `TransferData` and
checks its shape — that's the only way to actually exercise the type
contract.
