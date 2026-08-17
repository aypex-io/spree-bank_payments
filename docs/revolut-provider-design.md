# Revolut provider — design

Status: **approved, one open question** (see "The open question" below).
Date: 2026-08-17.

This covers two shipping units:

1. **`spree-bank_payments` 5.3.0** — three changes the provider work forces
   back into core.
2. **`spree-bank_payments-revolut` 0.1.0** — a new provider gem implementing
   the reconciler contract against the Revolut Business API.

Core ships first. The provider gem cannot be finished against 5.2.0, for the
same reason a chart is promoted before the values that consume it.

The API shapes this design relies on were verified on 2026-08-17 against both
the live OpenAPI spec and a fork of Revolut's own Postman collection. They are
recorded in the `reference_revolut_business_api_shapes` memory rather than
restated here.

---

## Part A — core 5.3.0

### A1. Three-state reconciler health

`Reconcilers::Base#healthy?` returns a boolean today. A boolean cannot
distinguish "Revolut returned a 502, retry in a minute" from "the OAuth
consent expired and no amount of retrying will fix it" — and those need
different humans on different timescales. Conflating them means the store
either silently stops reconciling or silently stops accepting bank transfers,
with nothing to say why.

Replace with `#health`, returning one of:

| Value              | Meaning                                    | Offers at checkout? |
|--------------------|--------------------------------------------|---------------------|
| `:ok`              | Working.                                   | yes                 |
| `:transient`       | Provider unreachable or erroring. Retry.   | yes                 |
| `:consent_revoked` | Authorisation is dead. A human must act.   | no                  |

`healthy?` stays, defined as `health == :ok`, so a reconciler written against
5.1.1 or 5.2.0 keeps working unmodified. Providers that do not override
`#health` get `:ok`/`:transient` inferred from `healthy?`.

`:transient` deliberately still offers at checkout. A brief provider outage
must not take the payment method off the storefront — the transfers still
arrive and reconcile once the provider returns. Only `:consent_revoked`
withdraws it, because in that state nothing will ever reconcile.

### A2. Health transition logging

Core owns this, not each provider. `reconciler_healthy?` is already a core
concept gating checkout; if every provider logs its own way, each new provider
re-invents it and every downstream alert rule needs another clause.

Log on **transition**, then at most **hourly** while the condition persists —
often enough that a window-based alert still fires after a Loki gap or a pod
restart, rare enough that the recovery line is not buried. A 5-minute poll
against a dead consent would otherwise write ~288 identical lines a day.

Severity splits by actionability: `:transient` logs WARN, `:consent_revoked`
logs ERROR. Recovery logs INFO.

The line carries a stable `event=` key so alert rules never depend on prose:

```
[spree-bank_payments] reconciler unhealthy
  event=bank_payments.reconciler.unhealthy
  reconciler=revolut payment_method_id=12 reason=consent_revoked
  consecutive_failures=3 last_success_at=2026-08-17T09:14:22Z
```

`reason` is drawn from a fixed enum. It is **never** interpolated from an
exception message or response body — that is exactly how a bearer token ends
up in a log aggregator.

Alongside the log, publish `bank_payments.reconciler.unhealthy` through
`Spree::Events` so a host can hook it programmatically instead of parsing
logs. Payload is serializable primitives only; subscribers run async.

For the LGTM stack this reduces to:

```logql
{namespace=~"tkf-.*"} |= "bank_payments.reconciler.unhealthy" | logfmt
```

Page immediately on `reason="consent_revoked"`; alert on anything else only
after ~30 minutes sustained.

### A3. `pooled` on `BankAccount`

A pooled account shares one IBAN across many customers, so the payment
reference is the *only* thing separating two payers. Matching on amount and
currency without an exact reference hit is unsafe there in a way it is not on
a dedicated account.

The matcher lives in core, so the flag must too:

- `spree_bank_payments_bank_accounts.pooled` — boolean, default `false`,
  not null.
- `AccountData` carries `pooled:`, defaulting to `false`.
- A provider that never sets it behaves exactly as it does today.

**Rule:** on a pooled account, auto-apply requires an exact normalized
reference match. Amount-plus-currency agreement is not sufficient and routes
to the manual queue instead.

**Amended 2026-08-17, during planning.** This rule is already enforced, and
universally: `IngestTransfer#matching_session` returns `nil` on a blank
`reference_normalized` and looks sessions up by exact `external_id_normalized`.
No amount-only auto-apply path exists for any account, pooled or not.

So `pooled` adds no matcher behaviour. Its value is that an admin can see the
account is pooled and understand why the reference matters when hand-matching,
plus a regression spec that locks the invariant — so that a later fuzzy or
amount-only fallback fails loudly instead of silently crediting the wrong payer
on shared coordinates. The plan implements it that way rather than adding a
rule that would be a no-op.

---

## Part B — `spree-bank_payments-revolut`

Namespace `Spree::BankPayments::Revolut`. Depends on
`spree-bank_payments >= 5.3`. It implements the reconciler contract and the
reconnect UI, and nothing else — checkout, sessions, discounts, the manual
queue and the matcher all stay in core.

### B1. Credentials

The signing key is deploy-time config; everything else is store-configurable.
This keeps the private key out of the database and out of any admin-UI
screenshot, while still letting a store connect its own Revolut account
without a redeploy.

| Where                      | What                                              |
|----------------------------|---------------------------------------------------|
| ENV / Rails credentials    | `REVOLUT_PRIVATE_KEY` (PEM)                        |
| Payment method preferences | `client_id`, `refresh_token` (encrypted), `environment` (`sandbox`/`production`) |

### B2. `Revolut::Client`

HTTP plus token lifecycle.

- Builds the RS256 client-assertion JWT: `iss` = redirect-URI host,
  `sub` = `client_id`, `aud` = `https://revolut.com`, short `exp`.
- Access tokens last ~40 minutes (`expires_in: 2399` observed). Cache in
  `Rails.cache` keyed by `client_id` with a lock, so a Sidekiq fleet does not
  stampede the token endpoint on expiry.
- A refresh failure that is unambiguously terminal (invalid_grant) maps to
  `:consent_revoked`. Everything else maps to `:transient`. When in doubt,
  `:transient` — wrongly withdrawing the payment method from checkout is worse
  than a delayed page.

### B3. Ingestion — webhook primary, polling as the safety net

Not a choice between them. Webhook delivery is not guaranteed; Revolut ships a
"failed webhook events" endpoint precisely because of that. Core's `PollJob`
already re-scans with an overlap window. Both paths dedupe on Revolut's
transaction `id`.

**Webhook verification** — HMAC-SHA256 over `v1.{timestamp}.{body}`,
constant-time comparison, and rejection when the timestamp is outside a
5-minute window so a captured payload cannot be replayed later.

**The asymmetry that must not be missed:**

- `TransactionCreated` — `data` is the complete transaction. Map directly.
- `TransactionStateChanged` — `data` is only
  `{id, request_id, old_state, new_state}`. No legs, no amount, no reference.
  It **must** trigger a re-fetch of the transaction; acting on this payload
  alone silently does nothing.

### B4. Mapping

Ingest only transactions where `type == "topup"` **and** the leg amount is
positive. A real business account carries card payments, fees, FX and outgoing
transfers; all of it is dropped before reaching core's matcher. Outgoing
amounts are negative, so sign gives direction without a second lookup.

Only `state == "completed"` credits an order.

```
TransferData(
  provider_reference:   txn["id"],
  provider_account_id:  txn["legs"][0]["account_id"],
  amount:               txn["legs"][0]["amount"],
  currency:             txn["legs"][0]["currency"],
  reference:            <see "The open question">,
  paid_at:              txn["completed_at"]
)
```

An incoming transfer has exactly one leg, so `legs[0]` is safe here — but
assert it rather than assuming, and route a multi-leg topup to the manual
queue rather than guessing which leg is ours.

### B5. `sync_accounts`

`GET /accounts`, then `GET /accounts/{id}/bank-details` per account.

`bank-details` returns an **array** of detail sets, each with `iban`, `bic`,
`beneficiary`, `beneficiary_address`, `bank_country`, `schemes`,
`estimated_time` and `pooled`. This maps onto core's `DetailSet` directly.

Label each set from its `schemes` so a customer sees "UK payments (Faster
Payments)" and "International (SWIFT)" rather than two unlabelled blobs.
Carry `pooled` up to `AccountData` per A3.

### B6. Reconnect flow

When consent expires, an admin must re-authorise without shell access.

- A **Reconnect Revolut** button on the payment method admin page, shown with
  the current consent status and, when expired, the fact that bank transfers
  are no longer offering at checkout.
- `GET /admin/bank_payments/revolut/callback` — verifies a signed `state`
  parameter (CSRF), swaps the code for a fresh refresh token, stores it, and
  redirects back with the status refreshed.
- The consent URL is built for the configured `environment`, so a sandbox
  install never bounces an admin at production Revolut.

---

## The open question

**Which field carries the payer's reference on an incoming transfer.**

`reference` is top-level on the transaction object, documented as "The payment
reference". But the canonical incoming example reads:

```json
"reference": "Top up Revolut account",
"legs": [{ "description": "Payment from John Smith" }]
```

— where the `reference` value looks like canned text and the payer narrative
sits in the leg. Matching the wrong field means the matcher never fires and
every real payment lands in the manual queue, which presents as "installed and
working, just never matching".

This is settled empirically before B4 is implemented, not guessed.
`POST /sandbox/topup` accepts a caller-supplied `reference`, so a known marker
can be sent and traced. A probe script exists; its output also becomes the
gem's transaction fixture.

Both branches are cheap to accommodate — the matcher takes an ordered list of
candidate fields — so this blocks only the choice of that list, not the
surrounding design.

---

## Out of scope for v1

**Reverted incoming transfers.** A completed transfer can later move to
`reverted` — money clawed back after an order was credited and possibly
shipped. Core has no unwind concept, and inventing one here would be a larger
change than this gem. Explicitly deferred; rare on bank rails, not impossible.

**Merchant API / card acceptance.** Different product, different collection.

**Outgoing payments and refunds.** This gem reconciles money in. Paying money
out through Revolut is a separate concern with a much higher blast radius.

---

## Testing

- Contract: run all three exported shared example groups —
  `'a bank transfer reconciler'`, `'…that returns transfers'`, and
  `'…that returns accounts'`. The latter two exist because an `all(be_a(X))`
  assertion passes vacuously against `[]`.
- Webhook verification gets its own adversarial specs: wrong secret, tampered
  body, replayed timestamp, and a signature of the right shape over the wrong
  payload.
- At least one test asserts against the **real** captured sandbox transaction,
  not a hand-written hash. A fixture we invented cannot tell us the wire shape
  changed.
- Token refresh is tested for the stampede case: concurrent callers on an
  expired token must produce one refresh, not N.
