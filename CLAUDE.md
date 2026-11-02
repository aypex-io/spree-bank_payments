# CLAUDE.md

Guidance for working in this repository.

## Overview

`spree-bank_payments` is a Spree extension: bank transfer checkout with a
unique payment reference, an optional discount, automatic reconciliation of
incoming transfers through pluggable reconcilers, and expiry of unpaid
orders. Namespace `Spree::BankPayments`, `require 'spree/bank_payments'`.

It targets **Spree 6.0** (`spree ~> 6.0`, Ruby >= 3.3, PostgreSQL only). The
major version tracks Spree's. Spree 5.6 lives on `5-3-stable` (5.3.x).

This is a **public repo**: code, docs, specs and commit messages use example
values only (`ACME-7Q4X2`, `shop.example.com`), never a real store or
customer. Reference examples use `ACME-`: it has none of the letters
normalization folds (O, I, L).

`docs/design-spec.md` is the behaviour the gem keeps. `docs/superpowers/`
holds implementation plans.

## Commands

```bash
bundle exec rake                 # builds spec/dummy if missing, rebuilds its schema, runs the suite
bundle exec rake test_app        # (re)generate the dummy app
bundle exec rspec path/to/spec.rb
SPREE_VERSION=6.0.0 bundle update spree && bundle exec rspec   # oldest Spree the gemspec allows
```

The suite must print nothing and raise no deprecations:
`bundle exec rspec > out.txt 2>&1; grep -c "DEPRECATION WARNING" out.txt` is `0`.

## How it works

- **Checkout** is a Store API payment session. `Gateway#create_payment_session`
  quotes the cart (`external_data.bank_transfer`), `#complete_payment_session`
  leaves a pending payment keyed by the reference, and `Carts::Complete`
  places the order unpaid. The session moves onto the order at placement.
- **The discount** is `manual` `Spree::Discount` rows written by
  `Adjusters::Discount` (registered in `Spree.adjusters`) while the
  purchase's newest open bank transfer session is in its currency.
  `ReleaseSelection` takes bank transfer back off a cart; the
  `ReleaseOnOtherMethod` prepend runs it before the Store API sizes another
  method's session or payment.
- **Placement**: `OrderPlacedSubscriber` restarts the payment window and
  publishes `bank_transfer.instructions_ready`.
- **Reconciliation**: `IngestTransfer` and `ApplyTransfer` are the single
  implementation of matching and applying. Auto-apply needs an exact
  normalized reference, amount and currency against one open session of a
  placed, unpaid order. `ApplyTransfer` settles through
  `Spree.payment_capture_workflow`.
- **Expiry**: `ExpireSessionsJob` cancels through `Spree.order_cancel_workflow`,
  only while the reconciler is healthy.

## Spree 6 facts this code rests on

- `Spree::Events.activate!` does nothing once the registry holds a
  subscription. Register subscribers through `Spree.subscribers` (by class
  name, in `after_initialize`), never `Spree::Events.subscribe` from
  `to_prepare`, or none of Spree's own subscribers register.
- Every event must be declared (`publishes_event`); `publish_event` raises in
  test otherwise. Events need `Spree::Current.store`, or the webhook
  subscriber drops them: jobs publish inside `Spree::Current.with_store`.
- Event payloads are stringified: read `payload['key']`.
- `config.spree.adjusters` is assigned in core's `after_initialize`; append
  after it, and re-swap by name in `to_prepare`.
- Payment session transitions are non-bang and return booleans (`process`,
  `complete`, `cancel`, `expire`).
- A pending payment on a method that does not capture at checkout counts as
  ready to ship. The gateway pins `resolved_capture_method` to `checkout` so
  Spree holds an unpaid order's dispatch.
- Spree's test config raises on `Spree.t`; use `I18n.t('spree.…')`.
- Payment method names are unique per store; the gateway factory sequences them.
