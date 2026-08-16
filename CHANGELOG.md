# Changelog

All notable changes to this project are documented in this file.

## 5.0.0

First public release on RubyGems, as `spree-bank_transfer`.

This gem was developed under the working names `aypex_bank_transfer`,
`spree_bank_transfer` and `spree_bank_payments`, but was never published under any
of them. Both underscore spellings are held on RubyGems by unrelated owners —
`spree_bank_transfer` by `vinsol` (2013) and `spree-bank-transfer` by Mohit Bansal
(2014) — so neither was obtainable.

`spree-bank_transfer` is both free and correct: per the RubyGems convention a dash
denotes a gem under another gem's namespace while an underscore joins words within
one level, so the gem name, the require path (`spree/bank_transfer`) and the Ruby
namespace (`Spree::BankTransfer`) all agree.

**Versioning:** the major version tracks Spree's major version — `spree-bank_transfer`
5.x supports Spree 5.x. The gemspec requires `spree >= 5.6.0`.

If you tracked this repository from git before 5.0.0, note:

- **Gem name** is `spree-bank_transfer`. `gem 'spree-bank_transfer'` is all a host
  app needs — `Bundler.require` resolves through a shim at `lib/spree-bank_transfer.rb`.
- **Require path** is now `spree/bank_transfer`.
- **Ruby namespace** is now `Spree::BankTransfer` (was `SpreeBankPayments`).
- **Install generator** is now `rails g spree:bank_transfer:install`.
- **Database tables** are now `spree_bank_transfer_incoming_transfers` and
  `spree_bank_transfer_reconciler_states`. The migrations were edited in place
  rather than shipped as renames, which is safe only because no host application
  had ever run them. There is no upgrade path from an earlier checkout that had
  already migrated — drop the old tables and re-run.
- **Unchanged:** the `Spree::PaymentSessions::BankTransfer` payment session model,
  the admin routes and controller, and all i18n keys (`spree.bank_transfer.*`).

`engine_name` remains `spree_bank_transfer`: it generates route helper prefixes and
the `spree_bank_transfer:install:migrations` rake task, so it must be a valid Ruby
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
