# Changelog

All notable changes to this project are documented in this file.

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
