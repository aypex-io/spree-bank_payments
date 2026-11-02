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

`dashboard/` is the Spree dashboard plugin,
`@aypex/spree-bank-payments-dashboard` on npm. It is released with the gem on
the same `v*` tag and carries the same version.

`docs/design-spec.md` is the behaviour the gem keeps. `docs/superpowers/`
holds implementation plans.

## Commands

```bash
bundle exec rake                 # builds spec/dummy if missing, rebuilds its schema, runs the suite
bundle exec rake test_app        # (re)generate the dummy app
bundle exec rspec path/to/spec.rb
SPREE_VERSION=6.0.0 bundle update spree && bundle exec rspec   # oldest Spree the gemspec allows

cd dashboard && corepack pnpm install && corepack pnpm typecheck && corepack pnpm lint
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
- **Completion**: `SettleAtCompletion` (Spree's `carts.complete.validate`
  hook, under the cart lock) re-quotes the completed bank session and resizes
  its payment, and releases any bank session the buyer never completed.
  `Gateway#ensure_open!` refuses to complete or update a closed session.
- **Placement**: `OrderPlacedSubscriber` restarts the payment window and
  publishes `bank_transfer.instructions_ready`.
- **Reconciliation**: `IngestTransfer` and `ApplyTransfer` are the single
  implementation of matching and applying. Auto-apply needs an exact
  normalized reference, amount and currency against one open session of a
  placed, unpaid order. `ApplyTransfer` re-checks under the order lock and
  settles through `Spree.payment_capture_workflow`, flagging
  `Spree::BankPayments::Current.applying_transfer`; `GuardCapture`
  (`payments.capture.validate`) refuses every other capture of a bank
  transfer payment, and `Gateway#can_capture?` is false.
- **Expiry**: `ExpireSessionsJob` cancels through `Spree.order_cancel_workflow`,
  only while the reconciler is healthy, rescuing per session.
- **Staff** work through the Admin API under `/api/v3/admin/bank_payments`
  (`app/controllers/spree/api/v3/admin/bank_payments/`), which the dashboard
  plugin calls. `RecordManualTransfer` and `IgnoreTransfer` back its record and
  ignore actions; apply goes through `ApplyTransfer`. The `bank_payments`
  permission scope (`config/initializers/spree.rb`) gates it: read for the
  queue, write for everything that changes something.
- **Upgrading from 5.x**: `MigrateLegacyDiscounts`
  (`rake spree_bank_payments:upgrade:legacy_discounts`) restores the 5.x
  discounts Spree's upgrade wrote as 0.00 surcharges.

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
- Spree's test config raises on `Spree.t` and on `Payment#state`; use
  `I18n.t('spree.…')` and `payment.status`.
- Workflow hooks (`Spree.hooks.register`) go at the top level of an
  initializer, by handler class name: the registry is never reset.
- Payment method names are unique per store; the gateway factory sequences them.

## Dashboard plugin facts

- The package entry is `src/index.ts`, not `.tsx`: the host's Vite pre-bundles
  a dependency only when its entry is `.js` or `.ts`. Un-bundled, the plugin's
  imports reach CommonJS the dev server cannot serve, and the page is blank.
- Import UI from the `@spree/dashboard-ui` root, which the host pre-bundles,
  not from deep `ui/*` paths.
- Strings a module reads while it loads (the queue table's labels) need the
  bundle registered first: `src/i18n.ts` is imported before them.
- Every `Link` and `navigate` passes `storeId`. The plugin's own typecheck
  cannot see the host's route tree, so build it inside a host
  (`npm pack` the plugin, install the tarball) to check the paths.
