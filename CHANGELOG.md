# Changelog

All notable changes to this project are documented in this file.

## 5.3.0

### Upgrading from 5.2.0

Adds columns, so this is not gem-bump-only:

```sh
bin/rails spree_bank_payments:install:migrations
bin/rails db:migrate
```

### Added

**Three-state reconciler health.** `Reconcilers::Base#health` returns `:ok`,
`:transient` or `:consent_revoked`. A boolean could not separate a retryable
provider outage from a dead authorisation, and the two need different responses:
`:transient` keeps offering at checkout, because those transfers still arrive
and reconcile once the provider returns, while `:consent_revoked` withdraws the
payment method, because nothing will ever reconcile against it.

**Backward compatible.** A reconciler written against 5.1.1 or 5.2.0, overriding
only `#healthy?`, works unmodified — `#health` derives from it. A reconciler
overriding only `#health` gets `#healthy?` derived in turn.

**Health transition logging, owned by core.** Logged on transition and at most
hourly thereafter, with a stable `event=` key so alert rules never depend on
prose. `:transient` logs WARN, `:consent_revoked` logs ERROR, recovery logs INFO.
`bank_payments.reconciler.unhealthy` and `.recovered` are also published through
`Spree::Events`.

The `reason` is drawn from a closed enum and unrecognised values collapse to
`unknown`. It is never built from an exception message or a response body.

**`pooled` on bank accounts.** Carried from `AccountData` through `SyncAccounts`.
A pooled account shares its coordinates with other customers of the provider, so
the payment reference is the only thing separating two payers. Auto-apply has
always required an exact reference match; `spec/services/spree/bank_payments/pooled_account_matching_spec.rb`
now locks that invariant explicitly.

## 5.2.0

### Upgrading from 5.1.1

This release adds tables and columns, so the upgrade is not gem-bump-only.
From the host app, after bumping the gem:

```sh
bin/rails spree_bank_payments:install:migrations
bin/rails db:migrate
```

`db:migrate` runs the legacy preference migration described under
"Legacy preference migration" below, which folds your existing `account_*`
preferences into a `BankAccount` so the store keeps quoting exactly what it
quoted before. Then read the BREAKING CHANGE below: any host code calling
`Gateway#bank_details` needs a change.

### BREAKING CHANGE

**`Gateway#bank_details` now returns `Array<Spree::BankPayments::DetailSet>`,
not a `Hash`.** The method was kept — nothing was renamed or removed — but a
host reading it as a `Hash` will get a `TypeError`, not a missing-method
error, the moment it upgrades:

```ruby
# 5.1.1
gateway.bank_details[:iban]      #=> "GB00REVO00000000000000"

# 5.2.0
gateway.bank_details[:iban]      #=> TypeError: no implicit conversion of Symbol into Integer
gateway.bank_details[0].fields   #=> [["IBAN", "GB00REVO00000000000000"], ["BIC", "REVOGB21"]]
```

Two alternatives were considered and rejected:

- **Back-mapping the first detail set onto the old five keys** (`:name`,
  `:iban`, `:bic`, `:sort_code`, `:number`). Rejected: detail-set labels are
  arbitrary per country (a US account has a routing number, not a sort
  code), so there is no general mapping back onto five fixed keys. A
  silently wrong `Hash` — one that quietly drops or mislabels fields — is
  worse than a loud `TypeError` a host discovers in CI.
- **Bumping to 6.0.0 instead of 5.2.0.** Rejected: this gem's major version
  tracks Spree's major version (`spree-bank_payments` 5.x supports Spree
  5.x). A 6.0.0 release would falsely advertise Spree 6 support that
  doesn't exist.

**Fix:** call `bank_details_for(currency)` instead, and iterate the returned
detail sets:

```ruby
gateway.bank_details_for(order.currency).each do |detail_set|
  detail_set.label   #=> "UK payments"
  detail_set.fields   #=> [["Sort code", "04-00-75"], ["Account number", "12345678"]]
end
```

`#bank_details` itself is unchanged in one respect: it still quotes the
*offered* account for the store's default currency (`Spree::Config[:currency]`),
via `bank_details_for`, and still emits a one-time deprecation warning. Only
its return type changed, to keep it truthful about what an account now is:
a store can hold more than one detail set (local + international) per
currency, and a `Hash` had no way to represent that.

### Added

**Multi-currency bank accounts.** A store can now configure one bank
account per currency (`Spree::BankPayments::BankAccount`), instead of a
single flat set of `account_*` preferences shared by every currency. See
the README's "Bank accounts and currencies" section for the full model —
briefly:

- Customers are always shown every detail set on the offered account for
  their order's currency (local and international both) — never inferred
  from billing country.
- The admin checklist allows at most one *offered* account per currency,
  enforced by a partial unique database index — not just a form validation.
- Every synced account is watched (polled/webhooked) regardless of whether
  it is offered, so switching which account is offered for a currency never
  strands a transfer already in flight against the old one.
- A currency with no offered account is not presented at checkout for that
  currency (`available_for_order?` returns `false`), unless the order
  already holds an open same-currency session against this gateway.
- Accounts can be synced from a provider (`Reconciler#sync_accounts`) or
  entered by hand in the admin. Sync never sets `offered` and never rewrites
  `bank_account_id` on an existing session — both are left to a human and to
  history respectively.
- A soft-deleted account is not silently resurrected by a later sync; it is
  reported as skipped in the sync diff instead.

**Legacy preference migration.** A data migration
(`db/migrate/20260817000004_migrate_legacy_account_preferences.rb`) folds
any existing `account_*` preferences into one `BankAccount`, marked
`offered`, for the store's default currency. An upgrading install keeps
quoting exactly what it quoted before — no manual step required.

### Reconciler contract additions

All additions are backward compatible with the contract published in 5.1.1.
**A reconciler gem built against 5.1.1 keeps working unmodified against
5.2.0** — nothing already implemented changed shape, and everything new is
either optional to override or defaults to `[]`/`nil`.

- **`sync_accounts` → `Array<Spree::BankPayments::AccountData>`.** New,
  optional override point on `Reconcilers::Base`; the default and `Manual`
  both return `[]`. `AccountData` carries `provider_account_id`, `currency`,
  and `details` in the normalised detail-set shape (the same shape
  `BankAccount#details` stores).
- **`TransferData` gains `provider_account_id`**, defaulting to `nil`. The
  initializer is keyword-only, so this is additive: existing construction
  calls are unaffected.
- **`poll(since:)` is unchanged.** Per-account fetching stays the
  provider's business.
- The exported shared example groups gain a third group,
  `'a bank transfer reconciler that returns accounts'` — provider authors
  must run it alongside the existing two (`'a bank transfer reconciler'` and
  `'a bank transfer reconciler that returns transfers'`) if their reconciler
  implements `sync_accounts`. It exists because the base group cannot check
  element types against an empty result.

## 5.1.1

### Fixed

- The admin order panel badged a **superseded** bank-transfer session as
  "Expired". A session is superseded (canceled) when the order was settled by
  another payment method, and its `expires_at` is usually already in the past —
  so testing the time-based `expired?` predicate first labelled a card-paid
  order as expired. The badge now branches on session **status**, and shows
  "Superseded" for that case.

  The same change fixes a second misreport: a *pending* session past its expiry
  that the sweeper has not reached yet is still matched by `.open`, so a
  transfer can still be auto-applied to it. It now correctly reads "Awaiting
  transfer" rather than "Expired".

### Documentation

- The manual "record a received transfer" form derives a transfer's identity
  from the values entered, which makes resubmission safe but also means two
  genuinely separate transfers matching on every recorded field are treated as
  one. The README said only the first half; it now says both, with guidance for
  recording a real duplicate payment.

## 5.1.0

**The bank-transfer discount is now tax-aware.**

`discount_percent` was applied as a single order-level `Spree::Adjustment`.
Order-level adjustments never reach Spree's `taxable_adjustment_total`, so on a
tax-inclusive (VAT) store the customer paid less while the order still recorded
tax on the undiscounted price. This was documented as a known limitation; it is
now fixed.

The discount is applied as one adjustment **per line item**, allocated
proportionally to each line's amount with largest-remainder rounding so the
parts sum to exactly `-(item_total * pct / 100)` — naive per-line rounding
drifts by a cent, and `order.total` must match the amount quoted on the payment
session or auto-apply's exact-equality check sends every payment to the manual
queue. A new `Spree::BankPayments::Adjuster::Discount`, registered in
`config.spree.adjusters`, folds these into `taxable_adjustment_total` before tax
is computed, so recorded tax now falls with the discount. (It is inserted ahead
of `Spree::Adjustable::Adjuster::Tax` so the array reads in execution order, but
Spree runs the tax adjuster last by construction — the position is cosmetic.)

The type filters match subclassed gateways, consistently with `is_a?`-based
detection: a store subclassing `Spree::BankPayments::Gateway` gets the same tax
treatment and the same cleanup on a payment-method switch.

The discount **stacks with promotions** — it is not a competing promo
adjustment, so neither side is marked ineligible. A 20% promotion plus a 3%
transfer discount is 23% off. Set `discount_percent` accordingly.

`remove_existing` now searches every adjustment carrying the order's id rather
than only order-adjustable ones, so a payment-method switch cannot orphan the
line-item adjustments (and still cleans up adjustments written by 5.0.x).

Minor, not patch: this changes recorded tax on existing tax-inclusive stores.

## 5.0.0

First public release on RubyGems, as `spree-bank_payments`.

This gem was developed under the working names `aypex_bank_transfer`,
`spree_bank_transfer` and `spree_bank_payments`, but was never published under any
of them.

Every spelling of `bank_transfer` turned out to be unavailable. Two different
owners hold the underscore and hyphen forms — `spree_bank_transfer` (vinsol, 2013)
and `spree-bank-transfer` (Mohit Bansal, 2014) — and `spree-bank_transfer` is
rejected too, because RubyGems refuses a new name that is too similar to an
existing one and treats `-` and `_` as equivalent. An API 404 on a gem name means
"no exact match", not "publishable".

`spree-bank_payments` is free, and the spelling is correct on its own terms: a dash
denotes a gem under another gem's namespace while an underscore joins words within
one level, so the gem name, the require path (`spree/bank_payments`) and the Ruby
namespace (`Spree::BankPayments`) all agree.

The *domain* vocabulary is still "bank transfer" — that is what the payment
instrument is. Only the gem namespace is `BankPayments`.

**Versioning:** the major version tracks Spree's major version — `spree-bank_payments`
5.x supports Spree 5.x. The gemspec requires `spree >= 5.6.0`.

If you tracked this repository from git before 5.0.0, note:

- **Gem name** is `spree-bank_payments`. `gem 'spree-bank_payments'` is all a host
  app needs — `Bundler.require` resolves through a shim at `lib/spree-bank_payments.rb`.
- **Require path** is now `spree/bank_payments`.
- **Ruby namespace** is now `Spree::BankPayments` (was the top-level `SpreeBankPayments`).
  Note the nesting change: these constants now live under `Spree`.
- **Install generator** is now `rails g spree:bank_payments:install`.
- **Database tables** are `spree_bank_payments_incoming_transfers` and
  `spree_bank_payments_reconciler_states`. The migrations were edited in place
  rather than shipped as renames, which is safe only because no host application
  had ever run them. There is no upgrade path from an earlier checkout that had
  already migrated — drop the old tables and re-run.
- **Unchanged:** `Spree::PaymentSessions::BankTransfer`,
  `Spree::Admin::BankTransfersController`, `IncomingTransfer`, `TransferData`, and
  the admin routes.

`engine_name` is `spree_bank_payments`: it generates route helper prefixes and the
`spree_bank_payments:install:migrations` rake task, so it must be a valid Ruby
identifier and cannot take a dash.

### Features

- Bank transfer payment method with a configurable checkout discount, expiry
  window, and unique per-order payment references.
- Pluggable reconciliation of incoming transfers, with a manual reconciler that
  works out of the box and a documented interface for bank-specific backends.
- Admin queue for transfers that cannot be matched automatically, with match
  suggestions backed by `pg_trgm` similarity.
- Instruction and reminder mailers, session expiry, and polling jobs.
- PostgreSQL only: `jsonb`, partial unique indexes and `pg_trgm` are load-bearing.
