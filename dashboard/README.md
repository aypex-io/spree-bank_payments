# @aypex/spree-bank-payments-dashboard

The Spree dashboard screens for [`spree-bank_payments`](https://github.com/aypex-io/spree-bank_payments):

- **Bank transfers** (under Orders): the queue, which opens on unmatched transfers, each transfer's
  possible matches with Apply and Ignore, and a form to record a transfer seen on the bank statement.
- **Bank accounts**, linked from the bank transfer payment method: offer one account per currency,
  deactivate, add an account by hand, or, with a provider's reconciler, sync from the provider after
  previewing the changes.
- A **Bank transfer** card on the order page: the reference, amount, deadline and the transfer applied.
- The payment method's **setup guide**: reconciler health, the webhook URL, and a warning when no
  account is offered.

## Install

Add the gem to the Spree server and the plugin to the dashboard app. Their versions match.

```bash
# in the server
bundle add spree-bank_payments
bin/rails g spree:bank_payments:install

# in the dashboard app
pnpm add @aypex/spree-bank-payments-dashboard
```

The dashboard discovers the plugin on its next build: no code changes.

Give staff roles the **Bank transfers** permission: read to see the queue, write to apply, ignore,
record transfers and manage accounts.

## Compatibility

| Plugin | Gem | Spree |
|---|---|---|
| 6.0.x | 6.0.x | 6.0 |
