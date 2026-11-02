# Upgrading from 5.3 to 6.0

`spree-bank_payments` 6.0 runs on Spree 6 only. Upgrade Spree first, then
this gem.

## Before you start

1. **Be on 5.3.0.** Run its migrations (`bin/rails
   spree_bank_payments:install:migrations && bin/rails db:migrate`) so the
   schema is current before Spree's own upgrade runs.
2. **Upgrade Spree** by its guide, including `bin/rake spree:upgrade`. Spree
   moves incomplete orders into carts and gives every payment method a store.

## Upgrade the gem

```ruby
gem 'spree-bank_payments', '~> 6.0'
```

```bash
bundle update spree-bank_payments
bin/rails spree_bank_payments:install:migrations
bin/rails db:migrate
bin/rails spree_bank_payments:upgrade:legacy_discounts
```

6.0.0 adds no migrations of its own.

**Run `spree_bank_payments:upgrade:legacy_discounts` after Spree's
`spree:upgrade`.** Spree's conversion of 5.x adjustments does not know a
discount sourced from a payment method, so it writes every 5.x bank transfer
discount as a 0.00 surcharge. The order's stored total is still right, but
the next time Spree re-sums the order (a cancel, an edit, a refund) its total
rises by the discount. The task puts each one back as a discount, from the
amount Spree left in `spree_adjustments`. It is safe to run more than once.

## What changes for staff

There is no Rails admin on Spree 6. The 5.x screens (the unmatched-transfers
queue, the "record a received transfer" form, the bank accounts screen and
the order panel) are now a Spree dashboard plugin, released with the gem at
the same version:

```bash
# in the dashboard app
pnpm add @aypex/spree-bank-payments-dashboard
```

The next dashboard build picks it up. Then give staff roles the **Bank
transfers** permission: read to see the queue, write to apply, ignore,
record and manage accounts.

- The queue is under Orders, and opens on unmatched transfers.
- The bank accounts screen is linked from the bank transfer payment method,
  next to its setup guide.
- The order page has a Bank transfer card in place of the 5.x panel.
- Without the dashboard, the README's "Without the dashboard" section does
  the same from a console.

Staff can no longer dispatch an unpaid bank transfer order by accident:
Spree refuses with "This order is not paid for yet" unless they force it.
Nor can they mark one paid with Capture: a bank transfer payment is captured
only when a transfer is applied to it.

## What changes for the storefront

Spree 6 has no Rails storefront, so the checkout partial and
`spree/bank_payments/_order_instructions` are gone. A storefront takes bank
transfer through the Store API:

1. `POST /api/v3/store/carts/:cart_id/payment_sessions` with the bank
   transfer payment method when the buyer chooses it. Read the quote from
   `external_data.bank_transfer`.
2. `PATCH .../payment_sessions/:id/complete`, then
   `POST /api/v3/store/carts/:cart_id/complete`, when they place the order.
3. Show the instructions from `payments[].bank_transfer` on
   `GET /api/v3/store/orders/:id`.

The payment method's type is `bank_transfer`.

## What changes for code

- **Event payloads have string keys and prefixed ids.** Read
  `event.payload['payment_session_id']` (a `ps_...` id) and resolve it with
  `Spree::PaymentSessions::BankTransfer.find_by_prefix_id!`.
- **`bank_transfer.instructions_ready` fires when the order is placed**, not
  when bank transfer is selected.
- **The operational events never reach webhook endpoints.** Subscribe to
  `bank_transfer.reconciler_unhealthy`, `bank_transfer.expiry_failed` and
  `bank_transfer.reconciler_health.*` in the application if you alert on
  them.
- **Subscribe through `Spree.subscribers`**, with a `Spree::Subscriber`
  added in `after_initialize`, not with `Spree::Events.subscribe` from
  `to_prepare`. Spree activates its subscribers only while its registry is
  empty.
- Removed: `Gateway#bank_details` (use `#bank_details_for(currency)`),
  `#method_type`, `#description_partial_name`,
  `#configuration_guide_partial_name`, `#auto_capture?`, and
  `Spree::BankPayments.gateway_type_names` / `.gateway_scope`.
- A reconciler gem builds against the same `Reconcilers::Base` contract and
  shared examples as in 5.3.
