# spree-bank_payments

Bank transfer checkout for Spree 6, with pluggable reconciliation of
incoming payments.

The major version tracks Spree's: 6.x supports Spree 6. Spree 5.6 stays on
5.3.x, on the `5-3-stable` branch. Upgrading from 5.3: see
[docs/upgrading-5-to-6.md](docs/upgrading-5-to-6.md).

## Requirements

- Spree `~> 6.0` and Ruby 3.3 or newer.
- PostgreSQL. The gem uses `jsonb`, partial unique indexes, and `pg_trgm`.

## Installation

```ruby
gem 'spree-bank_payments'
```

```bash
bundle install
bin/rails g spree:bank_payments:install
```

The generator copies the migrations and then asks whether to run them. Pass
`--auto-run-migrations` to skip the prompt (useful in scripted installs).

It then schedules the gem's jobs (see [Scheduling](#scheduling)) in the
app's scheduler: `config/recurring.yml` when Active Job runs on Solid Queue,
as a stock Spree 6 store does, or `config/schedule.yml` when it runs on
Sidekiq with `sidekiq-cron`. Pass `--scheduler=solid_queue`,
`--scheduler=sidekiq_cron` or `--scheduler=none` to choose. With any other
scheduler it lists the jobs for you to add.

## Configuration

Add a **Bank transfer** payment method in the Spree dashboard (its API type
is `bank_transfer`) and set:

| Preference | Purpose |
|---|---|
| `reconciler` | `manual` by default; `revolut` with `spree-bank_payments_revolut` installed |
| `reference_prefix` | Prefix on generated references, e.g. `ACME-` |
| `expiry_days` | Days before an unpaid order is cancelled and restocked |
| `discount_percent` | Percentage off `item_total` for paying by transfer |
| `poll_interval_minutes` | How often the reconciler polls; drives the health gate |

The pre-5.2 flat `account_*` preferences are hidden from the dashboard. A
store upgrading from 5.1 has them folded into one offered `BankAccount` for
the store's default currency by the 5.2 migration.

## Checkout through the Store API

Spree 6 has no Rails storefront; the gem's checkout runs through the Store
API, as a payment session:

1. **The buyer picks bank transfer.** The storefront creates a payment
   session: `POST /api/v3/store/carts/:cart_id/payment_sessions` with the
   payment method's id. The response's `external_data.bank_transfer` is the
   quote: `reference`, `amount` (with the discount applied), `currency`,
   `expires_at`, `discount_percent` and `bank_details`. The cart's totals now
   include the discount. Creating another bank transfer session replaces the
   previous one.
2. **The buyer places the order.** The storefront completes the session
   (`PATCH .../payment_sessions/:id/complete`), which re-quotes the cart and
   leaves a pending payment carrying the reference, then completes the cart
   (`POST /api/v3/store/carts/:cart_id/complete`). Completing the cart
   re-quotes once more, under Spree's lock, so the quote, the payment and the
   order total are equal however the cart changed. Spree places the order
   unpaid: its `payment_status` is `authorized`. A session that was released
   or has expired cannot be completed: the Store API answers 422 and the buyer
   chooses bank transfer again.
3. **The confirmation page shows how to pay.** Every bank transfer payment,
   on the cart and on the order (`GET /api/v3/store/orders/:id`), carries a
   `bank_transfer` field with the same quote. The payment method itself
   carries `bank_transfer.discount_percent` and `expiry_days`, for the
   checkout to advertise before the buyer chooses.

If the buyer switches to another payment method, bank transfer is released
before Spree sizes the other method's session or payment, or updates or
completes one created earlier: its session is cancelled and the discount
comes off, so the other method charges the full total. A bank transfer
session the buyer never completed is also released when the cart completes,
so the discount only reaches an order bank transfer is paying.

Spree holds dispatch of an unpaid bank transfer order (its "not paid for
yet" rule) unless staff force it. The payment is captured when a transfer is
applied to it, and never otherwise: not on dispatch, and not from the
dashboard's Capture action, which Spree's capture workflow refuses for a
bank transfer payment.

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
- **Staff choose the offered account:** at most one account per currency
  can be *offered*, and only a person sets it (the **Offer to customers**
  switch on the dashboard's bank accounts screen). This is
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
  until someone offers at least one account.
- **Two sync triggers:**
  1. **A person asks for it.** `SyncAccounts.new(payment_method:).plan`
     returns the diff to confirm, and `#apply!` applies it (the dashboard's
     **Sync from provider** button, shown for any reconciler but `manual`).
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
  `acts_as_paranoid`; deleting one is a soft delete, so a
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
  it is recorded on the account as `pooled`. It changes
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

## The dashboard

A transfer that matches exactly (reference, amount and currency, against a
single open session on a placed, unpaid order) is applied automatically and
the order reads `paid`. Anything else is kept as an unmatched
`Spree::BankPayments::IncomingTransfer` for a person to decide. They decide
in Spree's dashboard, through a plugin released with the gem at the same
version, [`@aypex-io/spree-bank-payments-dashboard`](dashboard/README.md):

```bash
# in the dashboard app (the one built with Spree's dashboard-starter)
pnpm add @aypex-io/spree-bank-payments-dashboard
```

The dashboard discovers the plugin on its next build. It adds:

- **Bank transfers**, under Orders: the queue, which opens on unmatched
  transfers ("any status" lists every one). A transfer's page ranks the
  open sessions it could belong to, with **Apply** and **Ignore** (with a
  reason). Applying a transfer for a different amount asks first, and the
  order is credited for what arrived, so it reads `partially_paid` or
  `overcharged`, never a false `paid`.
- **Record a transfer**: enter one seen on the bank statement. With the
  default `manual` reconciler this is how transfers are recorded. An exact
  match is applied at once; anything else joins the queue.
- **Bank accounts**, linked from the bank transfer payment method: offer one
  account per currency, deactivate one, add one by hand, or, with a
  provider's reconciler, sync from the provider after previewing the
  changes.
- A **Bank transfer** card on the order page (the reference, the amount, the
  deadline and the transfer applied) and a **setup guide** on the payment
  method (reconciler health, the webhook URL to give the provider, and a
  warning when no account is offered).

Give staff roles the **Bank transfers** permission: read to see the queue,
write to apply, ignore, record and manage accounts. The plugin talks to the
gem's Admin API under `/api/v3/admin/bank_payments`, which any other admin
client can use too.

Recording the same transfer twice is safe: a transfer's identity is its
provider and provider transaction id, so a second record is the same row and
nothing is credited twice.

### Without the dashboard

The same decisions from a console:

```ruby
# Record a transfer received outside any provider integration.
data = Spree::BankPayments::TransferData.new(
  provider: 'manual', provider_transaction_id: 'bank-statement-2026-11-02-1',
  amount: BigDecimal('97.00'), currency: 'GBP', reference: 'ACME-7Q4X2',
  payer_name: 'Jane Doe', occurred_at: Time.current, raw: {}
)
Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

# Rank the open sessions an unmatched transfer could belong to.
Spree::BankPayments::SuggestMatches.new(transfer: transfer).call

# Apply it.
Spree::BankPayments::ApplyTransfer.call(transfer: transfer, payment_session: session, applied_by: admin)

# Offer an account.
account.update!(offered: true)
```

## Scheduling

These scheduled jobs are mandatory, not optional — without them nothing
expires and no reminders send:

| Job | Frequency | Purpose |
|---|---|---|
| `Spree::BankPayments::ExpireSessionsJob` | Hourly | Cancels and restocks orders whose payment window has lapsed |
| `Spree::BankPayments::SendRemindersJob` | Daily | Sends payment reminders as the expiry deadline approaches |
| `Spree::BankPayments::PollJob` | Every `poll_interval_minutes` (default 15) | Polls the configured reconciler for new transfers; a successful run is what arms the health gate below |

`bin/rails g spree:bank_payments:install` writes them into Solid Queue's
`config/recurring.yml` or sidekiq-cron's `config/schedule.yml`; running it
again adds nothing twice. On Solid Queue:

```yaml
production:
  bank_payments_expire_sessions:
    class: Spree::BankPayments::ExpireSessionsJob
    schedule: every hour at minute 23
  bank_payments_send_reminders:
    class: Spree::BankPayments::SendRemindersJob
    schedule: every day at 9am
  bank_payments_poll:
    class: Spree::BankPayments::PollJob
    schedule: every 15 minutes
```

With another scheduler (`whenever`, a Kubernetes CronJob), add the same three
by hand. `PollJob`'s line assumes the default 15-minute poll interval: match
it to the gateway's `poll_interval_minutes`.

## The health gate

There are two health mechanisms in this gem and they decide different things.
This one — `reconciler_healthy?` — gates **expiry**: whether
`ExpireSessionsJob` is allowed to cancel anything. The other, described under
[`#health`](#health), gates **checkout**: whether bank transfer is offered at
all. Checkout availability is decided by `#health` and only by `#health`; a
stale poll never removes the payment method from the storefront, and a
reconciler can be perfectly healthy here while `#health` reports
`:consent_revoked`, or the reverse.

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

The gem never sends notifications directly. It publishes Spree events, and
subscribers decide what to do. Every event is declared, as Spree 6 requires.

| Event | Fired when | Webhooks |
|---|---|---|
| `bank_transfer.instructions_ready` | The order is placed, and the buyer needs the reference and bank details | yes |
| `bank_transfer.reminder_due` | An open session on a placed order is approaching its deadline | yes |
| `bank_transfer.expired` | `ExpireSessionsJob` cancels an unpaid order | yes |
| `bank_transfer.session_superseded` | An open session is closed because its order was already paid another way; the order is left alone | yes |
| `bank_transfer.reconciler_unhealthy` | The [health gate](#the-health-gate) trips: `ExpireSessionsJob` declined to cancel anything because the reconciler is stale | never |
| `bank_transfer.reconciler_health.unhealthy` | `PollJob` reports a *transition* into `:transient` or `:consent_revoked`, and at most hourly while it persists. Carries `status`, `reason` and `consecutive_failures` (see [`#health`](#health)) | never |
| `bank_transfer.reconciler_health.recovered` | The same reporter sees health return to `:ok` | never |
| `bank_transfer.expiry_failed` | `ExpireSessionsJob` hits an error for a payment method or a session, or Spree refuses to cancel a specific order | never |

The four operational events carry reconciler error text, so they are
declared `webhook: false`: no webhook endpoint receives them, not even one
subscribed to `*`. Subscribe to them in the application and route them
somewhere a person will see them.

The two `reconciler` events are not the same signal:
`reconciler_unhealthy` says the expiry job stood down, while the
`reconciler_health.*` pair reports the reconciler's own state and is what
decides whether checkout offers bank transfer at all.

The customer-facing payload (`Spree::PaymentSessions::BankTransfer#notification_payload`)
has string keys and prefixed ids, like Spree's own: `payment_session_id`,
`order_id`, `order_number`, `order_email`, `reference`, `amount`, `currency`,
`expires_at`, `discount_percent` and `bank_details`. A store that emails from
webhooks has everything it needs without another API call.

Subscribe with a `Spree::Subscriber` added to `Spree.subscribers` in an
`after_initialize` block. Do not call `Spree::Events.subscribe` from
`to_prepare`: Spree activates `Spree.subscribers` only while its registry is
empty, so a block subscribed first leaves every one of Spree's own
subscribers unregistered.

A bundled mailer, `Spree::BankPayments::InstructionsMailerSubscriber`, emails
the buyer, through Spree's email layout:

| Event | Email |
|---|---|
| `instructions_ready` | "Bank transfer details for order #R123": the reference, the amount, the deadline, and the bank details |
| `reminder_due` | "Reminder: pay for order #R123 by 11 November 2026", with the same details |
| `expired` | "Order #R123 cancelled: bank transfer not received". No bank details, and a line telling a buyer who already paid to reply |

Each gives the deadline as a date and a time in the store's time zone, and
has a plain-text part. Expiry cancels the order with `notify_customer:
false`, so the expired email is the only one the buyer gets about it.
Disable the mailer with:

```ruby
Spree::BankPayments::Config.disable_default_mailer = true
```

Stores that deliver mail another way, for example a storefront webhook
handler that sends through an email API, should disable the default mailer
and handle the events instead.

## Tax, and stacking with promotions

The discount is written as one `manual` `Spree::Discount` per **line item**,
tagged `metadata.source = "spree_bank_payments"`, while bank transfer is the
cart's selected payment. Shares are allocated in proportion to each line's
amount with Spree's largest-remainder apportionment, in the currency's minor
units, so they sum to exactly `-(item_total * discount_percent / 100)` and a
yen discount stays in whole yen.

Spree counts every discount row into a line's taxable basis, so **recorded
tax falls with the discount**: on a tax-inclusive market a 3% discount on a
£100 line reduces recorded VAT from £16.67 to £16.17.

**The discount stacks with promotions.** It is deliberately not a promotion:
Spree keeps one winning promotion per group, but this is a separate
concession for paying by transfer. A 20% promotion plus a 3% transfer
discount is 23% off. Set `discount_percent` with that in mind.

The base is always `item_total`, never the order total: the discount never
applies to delivery or tax. Once the order is placed its money is frozen, and
the rows are copied onto it.

## Showing the instructions

The storefront renders the payment reference and bank details from
`payments[].bank_transfer`. Making the reference visually prominent is the
single most effective thing a store can do for match rates: a buyer who does
not notice or copy it produces a transfer reconciliation cannot match
automatically, which means work for a person.

## Writing a reconciler

Subclass `Spree::BankPayments::Reconcilers::Base` and implement the four
contract methods:

- `#poll(since:)` — returns an `Array<Spree::BankPayments::TransferData>`
- `#parse_webhook(raw_body, headers)` — returns `TransferData` or `nil`
- `#health` or `#healthy?` — see below; `#health` decides checkout
  availability, `#healthy?` feeds the [health gate](#the-health-gate) that
  decides expiry
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

**This is the gate that decides whether checkout offers bank transfer**, and
the only one. The [health gate](#the-health-gate) above is a separate
mechanism reading a separate signal (`reconciler_healthy?`, driven by poll
staleness) and it only ever decides whether `ExpireSessionsJob` may cancel —
it never changes what a customer is shown.

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
