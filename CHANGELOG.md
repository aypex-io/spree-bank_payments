# Changelog

All notable changes to this project are documented in this file.

## Unreleased

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
