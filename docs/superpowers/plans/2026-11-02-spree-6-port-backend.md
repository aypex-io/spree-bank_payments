# Spree 6 port, part 1: the backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `spree-bank_payments` 6.0.0 runs on Spree 6.0, taking bank transfers end to end through the Store API: quote at checkout, place the order unpaid, reconcile, expire.

**Architecture:** The gem keeps its 5.x domain (references, reconcilers, ingestion, matching, health, expiry) and re-homes each touchpoint onto Spree 6: the payment session belongs to the cart and moves onto the order at completion; the discount is `manual` `Spree::Discount` rows written by a registered adjuster; transfers settle through Spree's capture workflow; expiry cancels through the order-cancel workflow; every event is declared. The Rails admin and Rails storefront views are removed — Spree 6 has neither. The admin comes back in part 2 as Admin API endpoints plus a dashboard plugin.

**Tech Stack:** Ruby ≥ 3.3, Rails 8.1, Spree `~> 6.0` (6.0.2 at time of writing), PostgreSQL, RSpec via `spree_dev_tools ~> 1.0`, WebMock.

**Spec:** `docs/design-spec.md` and `docs/multi-currency-accounts-design.md` define the behaviour being preserved. The port decisions below are what changes. Spree 6 facts are cited from the Spree source at the `v6.0.1` tag (paths relative to `spree/core/` unless noted).

**This is part 1 of 4.** Part 2: Admin API endpoints + a dashboard plugin package (the hand-match queue, bank accounts, order sidebar widget, payment-method setup guide). Part 3: a headless storefront's checkout and confirmation. Part 4: wiring a host app. Each gets its own plan. Nothing here may depend on them.

## Port decisions

1. **One release line per Spree major.** Gem 6.0.0 requires `spree ~> 6.0`. Spree 5.6 stays on 5.3.x, on a `5-3-stable` branch cut from `v5.3.0` at release time.
2. **The gateway is session-based.** `session_required?` is true. The storefront creates a payment session when the buyer picks bank transfer (the quote: reference, amount, deadline, bank details), completes it when they place the order (a `pending` payment whose `response_code` is the reference), then completes the cart. Spree places a cart whose payment is pending (`workflows/spree/carts/complete.rb:534-537`).
3. **Capture method is `checkout`.** `resolved_capture_method` returns `'checkout'`. Spree's dispatch guard then refuses to ship an unpaid bank-transfer order unless staff force it (`workflows/spree/fulfillments/fulfill.rb:129-157`), and nothing captures on dispatch. `authorize` and `purchase` fail with a message: money moves only when a transfer is reconciled.
4. **The discount is `manual` Discount rows.** A registered adjuster (`Spree::Adjusters::Base`) writes one `Spree::Discount` per line item while the cart's selected bank-transfer session is open, and removes them otherwise. `manual` rows survive recalculation, reduce the VAT basis (`taxable_adjustment_total` sums every discount row), stack with promotions, and are copied onto the order at completion (`carts/complete.rb:487-515`). A promotion rule cannot replace this in 6.0: promotions pick one winner per group.
5. **Switching away releases the selection first.** Spree computes another method's session or payment amount at creation, from the cart total as it stands. So before the Store API creates a session or a payment for any other method, the gem cancels its open sessions on that cart, voids their payments and recalculates. This is a `prepend` on the two Store API controllers' `create`, the only places a storefront chooses a method.
6. **Only placed orders reconcile automatically.** A transfer whose reference belongs to a session whose cart was never placed queues for a human. Spree's webhook workflow would otherwise complete the cart (`workflows/spree/payments/handle_webhook.rb`).
7. **Settlement goes through `Spree.payment_capture_workflow`.** It records the capture event, publishes `payment.captured` and recomputes statuses. The gateway's `capture` returns success: the reconciler has already seen the money.
8. **Events are declared; internal ones never reach webhooks.** Customer-facing events (`instructions_ready`, `reminder_due`, `expired`, `session_superseded`) are declared on the session class and carry everything a store needs to email the buyer, bank details included. Operational events (health, expiry failures) are declared `webhook: false`: they carry error text.
9. **Instructions go out on `order.placed`, not on session creation.** Before placement the session has no order and no email (`app/models/spree/payment_session.rb:163-176`). The deadline is re-stamped at placement, so the buyer gets the full `expiry_days`.
10. **The reconciler contract does not change.** `Reconcilers::Base`, `TransferData`, `AccountData` and both shared example groups stay source-compatible: provider gems build against them.

## Global Constraints

- `spree-bank_payments.gemspec`: `s.add_dependency 'spree', '~> 6.0'`; no `spree_admin`; `required_ruby_version '>= 3.3'`; version `6.0.0` (Task 10).
- PostgreSQL only: `jsonb`, partial unique indexes and `pg_trgm` stay load-bearing.
- This is a public repo. Code, comments, docs, specs and commit messages use example values only (`R1001`, `shop.example.com`, `GB29 NWBK 6016 1331 9268 19`), never a real store, customer or host.
- No `Spree.t` anywhere (Spree 6's test config raises on it). `bundle exec rspec > out.txt 2>&1; grep -c "DEPRECATION WARNING" out.txt` prints `0`.
- Every event the gem publishes is declared, and published through `record.publish_event` (which raises in test for an undeclared name), never bare `Spree::Events.publish`.
- Event payloads and `notification_payload` use string keys and primitive values (Spree 6 stringifies payload keys: `app/models/spree/event.rb:46-47`).
- Matching rules from the spec are unchanged: auto-apply only on exact normalized reference + amount + currency against exactly one open session; anything else queues.
- Existing migrations are history: do not edit them. New migrations only where a task says so.
- Money arithmetic rounds with `Spree::Money::Rounding.to_currency(amount, currency)`; splits use `Spree::Adjusters::LargestRemainder.apportion(amount, weights, currency)`.

## Review Focus

1. **The buyer switches from bank transfer to another method.** The other method's session or payment must be for the undiscounted total, and no bank discount rows may remain on the cart. (Task 5, `release_on_switch_spec.rb`.)
2. **The buyer changes the cart after choosing bank transfer** (adds an item, changes the address so tax moves). The session's quoted amount, the pending payment and the order total must all equal the new discounted total, so an exact-amount match still works. (Task 4 and Task 5, `requote_spec.rb`.)
3. **A transfer quotes a reference from a cart that was never placed.** It must queue as unmatched, never place the cart or create an order. (Task 7, `ingest_transfer_spec.rb`.)
4. **Staff dispatch an unpaid bank-transfer order from the dashboard.** Spree must refuse with its `order_not_paid` error unless forced, and allow it once the transfer is applied. (Task 6, `dispatch_guard_spec.rb`.)
5. **A store subscribes a webhook endpoint to every event (`*`).** It must receive the customer-facing bank-transfer events with the reference, amount, deadline and bank details, and must never receive the health or expiry-failure events. (Task 3, `event_catalogue_spec.rb`.)

---

### Task 1: Build and boot on Spree 6

Get the dummy app generating and the suite running, with the Rails-only layers removed. The suite will be red after this task: the failures are the work list for Tasks 2-9.

**Files:**
- Modify: `spree-bank_payments.gemspec`, `Gemfile`, `Rakefile`, `spec/spec_helper.rb` (already started on this branch: `spree ~> 6.0`, no `spree_admin`, `spree_dev_tools ~> 1.0`, `SPREE_VERSION` pin, `extension:test_app` with no options)
- Modify: `Rakefile`: add a `dummy:verify_schema` task and invoke it from `default`, copied from `spree-shipstation`'s Rakefile (Spree's `test_app` hides migration failures)
- Modify: `config/routes.rb`: remove the admin routes; keep only what Spree 6 still serves (the payments webhook route is core's)
- Modify: `config/initializers/spree.rb`: remove the `Spree.admin.navigation` block
- Delete: `app/controllers/spree/admin/`, `app/views/spree/admin/`, `app/views/spree/bank_payments/admin/`, `app/views/spree/checkout/`, `app/views/spree/bank_payments/_order_instructions.html.erb`
- Delete: `app/models/spree/bank_payments/adjuster/discount.rb`, `Spree::BankPayments.register_discount_adjuster!` and both calls to it (Task 5 replaces them)
- Delete: `spec/controllers/`, `spec/features/`, `spec/views/`, `spec/admin_navigation_spec.rb`
- Modify: `.github/workflows/ci.yml`: matrix `ruby: ['3.3', '4.0']` × `spree: ['6.0.0', '']` (`SPREE_VERSION` env; empty = newest)

The deleted admin behaviour stays readable at the `v5.3.0` tag; part 2 rebuilds it.

- [ ] **Step 1: Generate the dummy app**

Run: `rm -rf spec/dummy && DB=postgres bundle exec rake test_app`
Expected: exits 0, and the log has no `NameError` or `rake aborted!`.

- [ ] **Step 2: Rebuild the schema visibly**

Run: `bundle exec rake dummy:verify_schema`
Expected: `db:migrate` succeeds and `spec/dummy/db/schema.rb` contains `spree_bank_payments_incoming_transfers`, `spree_bank_payments_bank_accounts` and `spree_bank_payments_reconciler_states`.

- [ ] **Step 3: Run the suite to completion and record the baseline**

Run: `bundle exec rspec --format progress > tmp/port-baseline.txt 2>&1; tail -5 tmp/port-baseline.txt`
Expected: the run finishes (no load error); failures are allowed. Keep the file out of git.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Build against Spree 6 and drop the Rails admin and storefront views"
```

---

### Task 2: The gateway on Spree 6

**Files:**
- Modify: `app/models/spree/bank_payments/gateway.rb`
- Modify: `config/locales/en.yml` (`admin.preferences.*` labels and descriptions for every preference; `spree.bank_payments.gateway_name`, `spree.bank_payments.gateway_description`)
- Modify: `lib/spree/bank_payments/factories.rb`: the gateway factory sets `store` (Spree 6 payment methods `belongs_to :store`); the session factory takes a `cart` by default, with a `:placed` trait that builds it through `Spree.carts_complete_workflow`. Later tasks build on these.
- Test: `spec/models/spree/bank_payments/gateway_spec.rb`, `gateway_health_spec.rb`, `gateway_accounts_spec.rb`

**Interfaces:**
- Produces: `Gateway.api_type → 'bank_transfer'`; `Gateway.display_name → 'Bank transfer'`; `#session_required? → true`; `#resolved_capture_method → 'checkout'`; `#capture(amount, response_code, gateway_options = {}) → Spree::PaymentResponse` (success); `#authorize(*) / #purchase(*) → Spree::PaymentResponse` (failure); `#available_for_order?(purchase)` accepting a `Spree::Cart` or `Spree::Order`.

- [ ] **Step 1: Write the failing tests**

In `gateway_spec.rb`, one example each:
- `'reports its API type as bank_transfer'`: `expect(described_class.api_type).to eq('bank_transfer')`
- `'requires a payment session'`: `expect(gateway.session_required?).to be(true)`
- `'captures at checkout so Spree holds dispatch until it is paid'`: `expect(gateway.resolved_capture_method).to eq('checkout')`
- `'refuses to purchase outside a payment session'`: `expect(gateway.purchase(Spree::Money.new(10, currency: 'GBP'), nil, {}).success?).to be(false)`
- `'confirms a capture without contacting anyone'`: `expect(gateway.capture(Spree::Money.new(10, currency: 'GBP'), 'R1001ABC', {}).success?).to be(true)`
- `'is available for a cart in a currency with an offered account'`: build a `Spree::Cart` in GBP with an offered GBP account; `expect(gateway.available_for_order?(cart)).to be(true)`
- `'stays available for a cart that already holds a session in its currency'`: no offered account, an existing `BankTransfer` session on the cart; `be(true)`
- `'hides the legacy single-account preferences from the dashboard'`: `expect(described_class.preference_schema.map { _1[:key] }).not_to include('account_iban')` (match the key shape `preference_schema` actually returns)

Port the remaining 5.x examples in these three files to carts (`create(:cart)` in place of `create(:order)`), keeping their expected values.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/models/spree/bank_payments/gateway_spec.rb`
Expected: FAIL on `api_type` (returns `"gateway"`) and `session_required?`.

- [ ] **Step 3: Implement**

- `def self.api_type = 'bank_transfer'`, `def self.display_name = I18n.t('spree.bank_payments.gateway_name')`, `def self.description = I18n.t('spree.bank_payments.gateway_description')`.
- Remove `auto_capture?` (deprecated, unread). `accepts_money_amounts = true` (amounts arrive as `Spree::Money`).
- `actions` stays `%w[void]`, so the dashboard offers no Capture button.
- Legacy `account_*` preferences: declare with `internal: true` (still readable by migration `20260817000004`). `reconciler`: `choices: -> { Reconcilers::Base.registry.keys }`.
- `available_for_order?`: read `purchase.payment_sessions` and `purchase.currency`; it works for both owners.
- `bank_details` (deprecated in 5.2): remove.

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/gateway_spec.rb spec/models/spree/bank_payments/gateway_health_spec.rb spec/models/spree/bank_payments/gateway_accounts_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "Give the gateway a Spree 6 identity and capture-at-checkout semantics"`

---

### Task 3: The event catalogue

**Files:**
- Create: `lib/spree/bank_payments/events.rb` (the declarations, called from `to_prepare`)
- Modify: `app/models/spree/payment_sessions/bank_transfer.rb` (`notification_payload`, `#publish_bank_transfer_event`)
- Modify: `lib/spree/bank_payments/subscribers.rb` (string payload keys)
- Modify: `app/services/spree/bank_payments/health_reporter.rb`, `app/jobs/spree/bank_payments/{expire_sessions,send_reminders}_job.rb` (publish through the record)
- Test: `spec/lib/spree/bank_payments/event_catalogue_spec.rb`

**Interfaces:**
- Produces:
  - Customer-facing, declared on `Spree::PaymentSessions::BankTransfer`, webhook-visible: `bank_transfer.instructions_ready`, `bank_transfer.reminder_due`, `bank_transfer.expired`, `bank_transfer.session_superseded`.
  - Operational, declared on `Spree::BankPayments::Gateway` with `webhook: false`: `bank_transfer.reconciler_unhealthy`, `bank_transfer.expiry_failed`, `bank_transfer.reconciler_health.unhealthy`, `bank_transfer.reconciler_health.recovered`.
  - `BankTransfer#publish_bank_transfer_event(name)` publishes `notification_payload` under that name.
  - `BankTransfer#notification_payload → Hash` with string keys: `payment_session_id` (prefixed id), `order_id` (prefixed id or nil), `order_number`, `order_email`, `reference`, `amount` (decimal string), `currency`, `expires_at` (ISO 8601), `discount_percent` (string, `formatted_discount_percent`), `bank_details` (`bank_detail_sets.map(&:to_h)`).

- [ ] **Step 1: Write the failing tests**

- `'declares every event the gem publishes'`: for each of the eight names, `expect(Spree::Events.catalog.declared?(name)).to be(true)` (use the catalog's real predicate; see `lib/spree/events/catalog.rb`).
- `'keeps operational events off webhooks'`: for the four operational names, `expect(Spree::Events.catalog.webhook?(name)).to be(false)`.
- `'offers customer-facing events to webhooks'`: for the four customer-facing names, `be(true)`.
- `'gives a webhook receiver everything it needs to email the buyer'`: on a placed order's session, `expect(session.notification_payload.keys).to include('reference', 'amount', 'currency', 'expires_at', 'order_email', 'bank_details')`.
- `'uses string keys'`: `expect(session.notification_payload.keys).to all(be_a(String))`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/lib/spree/bank_payments/event_catalogue_spec.rb`
Expected: FAIL, nothing declared.

- [ ] **Step 3: Implement**

Declare with `publishes_event` (`app/models/concerns/spree/publishable.rb:142-147`) from a `Spree::BankPayments.declare_events!` method called in `to_prepare`. Replace every `Spree::Events.publish(...)` in the gem with a `publish_event` call on the session or gateway. Default mailer subscribers read `event.payload['payment_session_id']`.

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/lib/spree/bank_payments/event_catalogue_spec.rb spec/mailers spec/services/spree/bank_payments/health_reporter_spec.rb`
Expected: event catalogue PASS; mailer specs may still fail on `order` (Task 6).

- [ ] **Step 5: Commit**

`git commit -m "Declare the gem's events and keep operational ones off webhooks"`

---

### Task 4: The payment session lifecycle

**Files:**
- Modify: `app/models/spree/bank_payments/gateway.rb` (`create_payment_session`, `update_payment_session`, `complete_payment_session`, `cancel_payment_session`)
- Modify: `app/models/spree/payment_sessions/bank_transfer.rb` (`#quote`, owner-aware `order`)
- Create: `app/services/spree/bank_payments/release_selection.rb`
- Test: `spec/models/spree/payment_sessions/bank_transfer_spec.rb`, `spec/models/spree/bank_payments/gateway_sessions_spec.rb`, `spec/services/spree/bank_payments/requote_spec.rb`

**Interfaces:**
- Consumes: Task 2 gateway; Task 3 `notification_payload`.
- Produces:
  - `Gateway#create_payment_session(order:, amount: nil, external_data: {}) → Spree::PaymentSessions::BankTransfer`. `order` is the purchase (a cart, or a draft order). The caller's `amount` and the client's `external_data` are ignored for the quote: the gem quotes what it will match on.
  - `Gateway#update_payment_session(payment_session:, amount: nil, external_data: {})` re-quotes from the purchase.
  - `Gateway#complete_payment_session(payment_session:, params: {}) → payment_session`: re-quotes, `process`, then `settle_payment!(captured: false)`, which leaves a `pending` `Spree::Payment` whose `response_code` is the reference.
  - `Gateway#cancel_payment_session(payment_session:) → Boolean`: true for a session with no payment (`cancel`), false otherwise.
  - `BankTransfer#quote → Hash`, string keys: `reference`, `amount`, `currency`, `expires_at`, `discount_percent`, `bank_details`. Stored under `external_data['bank_transfer']`.
  - `Spree::BankPayments::ReleaseSelection.call(purchase:, except: nil) → Boolean`: cancels the purchase's open bank-transfer sessions other than `except`, voids their unsettled payments, and recalculates the purchase when it changed anything. Returns whether it did.
  - `Spree::BankPayments.recalculate!(purchase)`: `purchase.recalculate_totals!` (both `Cart` and `Order` define it: `cart.rb:154`, `order.rb:614`).

- [ ] **Step 1: Write the failing tests**

`gateway_sessions_spec.rb`:
- `'creates a pending session owned by the cart'`: `expect(session.cart).to eq(cart)` and, in a second example, `expect(session.order).to be_nil`.
- `'quotes the amount due at checkout'`: cart of one £100.00 item, no discount; `expect(session.amount).to eq(BigDecimal('100.00'))`.
- `'stores the quote where the storefront can read it'`: `expect(session.external_data['bank_transfer']['reference']).to eq(session.reference)`.
- `'ignores a client-supplied quote'`: create with `external_data: { 'bank_transfer' => { 'amount' => '1.00' } }`; `expect(session.external_data['bank_transfer']['amount']).to eq('100.00')`.
- `'cancels the cart's earlier open session when the buyer re-selects'`: two creates; `expect(first.reload.status).to eq('canceled')`.
- `'leaves a pending payment carrying the reference when completed'`: `expect(cart.payments.last).to have_attributes(state: 'pending', response_code: session.reference)`.
- `'stays open after completion so a transfer can still match it'`: `expect(Spree::PaymentSessions::BankTransfer.open).to include(session)`.
- `'is placed by Carts::Complete with the payment still pending'`: `result = Spree.carts_complete_workflow.call(cart: cart)`; `expect(result.value.payment_status).to eq('authorized')`.

`requote_spec.rb` (Review Focus 2):
- `'requotes when the cart grows after the buyer chose bank transfer'`: add a £50.00 item after creating the session, then complete it; `expect(cart.payments.last.amount).to eq(BigDecimal('150.00'))`.
- `'keeps the reference when it requotes'`: `expect(session.reload.reference).to eq(original_reference)`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/models/spree/bank_payments/gateway_sessions_spec.rb spec/services/spree/bank_payments/requote_spec.rb`
Expected: FAIL (`NoMethodError` on `complete!`/`order`, wrong owner).

- [ ] **Step 3: Implement**

The amount is `Spree::Money::Rounding.to_currency(purchase.amount_due_at_checkout, purchase.currency)`, read after `Spree::BankPayments.recalculate!` so it includes the discount once Task 5 lands. `expires_at` = `preferred_expiry_days.days.from_now` (Task 6 re-stamps it at placement). Use the non-bang transitions (`process`, `complete`, `cancel`, `expire`; `concerns/spree/payment_session_transitions.rb:37-70`), and check their boolean result. Session bookkeeping writes go inside `Spree::Events.disable_lifecycle { }`, as `SendRemindersJob` already does.

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/gateway_sessions_spec.rb spec/services/spree/bank_payments/requote_spec.rb spec/models/spree/payment_sessions/bank_transfer_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "Quote, settle and release bank transfer sessions on the cart"`

---

### Task 5: The discount as typed rows

**Files:**
- Create: `app/models/spree/bank_payments/adjusters/discount.rb`
- Create: `app/controllers/concerns/spree/bank_payments/release_on_other_method.rb` (prepended onto `Spree::Api::V3::Store::Carts::PaymentSessionsController` and `Spree::Api::V3::Store::Carts::PaymentsController`)
- Modify: `config/initializers/spree.rb`, `lib/spree/bank_payments.rb` (`register_discount_adjuster!` re-added for the new class)
- Delete: `app/services/spree/bank_payments/apply_discount.rb`, `app/models/spree/bank_payments/payment_decorator.rb`
- Modify: `config/locales/en.yml` (`spree.bank_payments.discount_label: "Bank transfer discount (%{percent}%)"`)
- Test: `spec/services/spree/bank_payments/discount_tax_spec.rb` (port), `apply_discount_spec.rb` → `spec/models/spree/bank_payments/adjusters/discount_spec.rb`, `spec/requests/spree/bank_payments/release_on_switch_spec.rb`

**Interfaces:**
- Consumes: Task 4 `ReleaseSelection`, `recalculate!`.
- Produces: `Spree::BankPayments::Adjusters::Discount < Spree::Adjusters::Base`, registered in `Rails.application.config.spree.adjusters`. Rows: `Spree::Discount` with `kind: 'manual'`, `line_item_id`, `label` from `discount_label`, `value` = percent, `value_type: 'percent'`, `metadata: { 'source' => 'spree_bank_payments', 'payment_method_id' => <id> }`, `amount` ≤ 0. Its rows are found by `metadata->>'source'`, never by `code`.
- Selection rule: the purchase's newest open (`pending`/`processing`) bank-transfer session whose currency equals the purchase's, on a gateway with `discount_percent > 0`. None means no rows.

- [ ] **Step 1: Write the failing tests**

`discount_tax_spec.rb`, on a market with `tax_inclusive: true` and a 20% rate, one £100.00 line:
- `'records included tax on the full price without bank transfer'`: `expect(cart.included_tax_total).to eq(BigDecimal('16.67'))`.
- `'records included tax on the discounted price with a 3% bank transfer discount'`: `expect(cart.total).to eq(BigDecimal('97.00'))` and, in its own example, `expect(cart.included_tax_total).to eq(BigDecimal('16.17'))`.
- `'counts a subclassed gateway'`: the 16.17 assertion again with `SubclassedBankTransferGateway` (`Class.new(Spree::BankPayments::Gateway)` plus `stub_const`).
- `'weights the split by price times quantity'`: lines £10.00 × 1 and £10.00 × 3; `expect(rows.map(&:amount)).to contain_exactly(BigDecimal('-0.30'), BigDecimal('-0.90'))`.
- `'stacks with a 20% promotion'`: `expect(cart.total).to eq(BigDecimal('77.00'))`.
- `'rounds to whole yen'`: a ¥999 line at 3%; `expect(rows.sum(:amount)).to eq(BigDecimal('-30'))`.
- `'is copied onto the placed order'`: complete the cart; `expect(order.discounts.where("metadata->>'source' = ?", 'spree_bank_payments').sum(:amount)).to eq(BigDecimal('-3.00'))`.
- `'registers the adjuster exactly once across reloads'`: run the `to_prepare` callbacks twice; `expect(Spree.adjusters.map(&:name).count('Spree::BankPayments::Adjusters::Discount')).to eq(1)`.

`release_on_switch_spec.rb` (Review Focus 1), through the Store API with a guest cart token:
- `'creates another method's session for the undiscounted total'`: create a bank session, then `POST /api/v3/store/carts/:id/payment_sessions` for a second session-based test gateway; `expect(json_response['amount']).to eq('100.00')`.
- `'creates a direct payment for the undiscounted total'`: same, via `POST /api/v3/store/carts/:id/payments` with a `Spree::PaymentMethod::Check`; `expect(json_response['amount']).to eq('100.00')`.
- `'leaves no bank discount rows behind'`: `expect(cart.reload.discounts.where("metadata->>'source' = ?", 'spree_bank_payments')).to be_empty`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/services/spree/bank_payments/discount_tax_spec.rb spec/requests/spree/bank_payments/release_on_switch_spec.rb`
Expected: FAIL, no rows written, totals undiscounted.

- [ ] **Step 3: Implement**

`#update` writes and deletes its own rows, idempotently. Base = the purchase's `item_total`. Total discount = `to_currency(item_total * percent / 100)`. Shares come from `LargestRemainder.apportion(total, line_amounts, currency)`. Clamp each share at its line's remaining base: `line.amount` less the line's other discount rows, never below zero. Register in `after_initialize`, because core assigns the array there (`lib/spree/core/engine.rb:217-219`), and re-swap by name in `to_prepare`. The controller concern's `create` resolves the target payment method from `params[:payment_method_id]` exactly as core does. If it is not a `Spree::BankPayments::Gateway`, it calls `ReleaseSelection.call(purchase: @cart)` before `super`. Prepend it from `to_prepare`, guarded by `included_modules`.

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/services/spree/bank_payments/discount_tax_spec.rb spec/models/spree/bank_payments/adjusters spec/requests/spree/bank_payments/release_on_switch_spec.rb spec/services/spree/bank_payments/requote_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "Write the bank transfer discount as manual Discount rows"`

---

### Task 6: Placement — instructions, deadline, dispatch

**Files:**
- Create: `app/subscribers/spree/bank_payments/order_placed_subscriber.rb` (`Spree::Subscriber`, `subscribes_to 'order.placed'`, registered in `Spree.subscribers`)
- Modify: `app/mailers/spree/bank_payments/instructions_mailer.rb`, `app/views/spree/bank_payments/instructions_mailer/*.html.erb` (`I18n.t`, `@order = @session.order`)
- Test: `spec/subscribers/spree/bank_payments/order_placed_subscriber_spec.rb`, `spec/mailers/spree/bank_payments/instructions_mailer_spec.rb`, `spec/workflows/spree/bank_payments/dispatch_guard_spec.rb`

**Interfaces:**
- Consumes: Task 3 `publish_bank_transfer_event`; Task 4 sessions; Task 2 `resolved_capture_method`.
- Produces: on `order.placed`, each `processing` bank-transfer session of that order gets `expires_at` re-stamped from now, then publishes `bank_transfer.instructions_ready` once.

- [ ] **Step 1: Write the failing tests**

- `'publishes instructions once when the order is placed'`: `expect { place! }.to change { published('bank_transfer.instructions_ready').size }.by(1)`.
- `'starts the payment window at placement'`: travel to 12:00 on 2026-11-02, create the session, travel two days, place; `expect(session.reload.expires_at).to eq(Time.zone.parse('2026-11-07 12:00'))` for `expiry_days` 3.
- `'emails the instructions to the order's address'`: `expect(mail.to).to eq([order.email])`.
- `'quotes the discounted amount in the email'`: `expect(mail.body.encoded).to include('97.00')`.
- `dispatch_guard_spec.rb` (Review Focus 4): `'refuses to dispatch an unpaid bank transfer order'`: `result = Spree.fulfillment_fulfill_workflow.call(fulfillment: order.fulfillments.first)`; `expect(result.errors.full_messages).to include(I18n.t('spree.fulfillments.errors.order_not_paid'))`.
- `'dispatches an unpaid one when staff force it'`: `force: true`; `expect(result).to be_success`.
- `'dispatches once the transfer is applied'`: after Task 7's `ApplyTransfer`; `be_success`. Mark it `pending` until Task 7 lands.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/subscribers spec/mailers spec/workflows`
Expected: FAIL. The subscriber does not exist; the dispatch-guard examples should already pass via Task 2's capture method. If they don't, stop and re-read `fulfill.rb:129-157` before adding anything.

- [ ] **Step 3: Implement the subscriber and the mailer changes**

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/subscribers spec/mailers spec/workflows spec/mailers/spree/bank_payments/instructions_ready_subscriber_spec.rb`
Expected: PASS (the Task 7 example pending).

- [ ] **Step 5: Commit**

`git commit -m "Send bank transfer instructions when the order is placed"`

---

### Task 7: Applying transfers

**Files:**
- Modify: `app/services/spree/bank_payments/apply_transfer.rb`, `ingest_transfer.rb`, `suggest_matches.rb`
- Modify: `app/models/spree/bank_payments/gateway.rb` (`parse_webhook_event`)
- Test: `spec/services/spree/bank_payments/{apply_transfer,ingest_transfer,discounted_reconciliation,pooled_account_matching,suggest_matches}_spec.rb`, `spec/models/spree/bank_payments/gateway_webhook_spec.rb`

**Interfaces:**
- Consumes: Task 4 pending payment (`response_code` = reference).
- Produces: `ApplyTransfer.call(transfer:, payment_session:, applied_by: nil) → IncomingTransfer`. It raises `Spree::BankPayments::ApplyTransfer::Refused` (new, `< StandardError`, carrying Spree's error messages) when the capture workflow fails. `IngestTransfer#call` is unchanged in signature.
- Settled payment statuses are `%w[paid overcharged]` (`Spree::Order::PAYMENT_STATUSES`). They replace 5.x `paid`/`credit_owed` everywhere.

- [ ] **Step 1: Write the failing tests**

- `'pays the order on an exact match'`: `expect(order.reload.payment_status).to eq('paid')`.
- `'records the capture'`: `expect(payment.reload.captured_amount).to eq(BigDecimal('97.00'))` (the discounted order from Task 5).
- `'completes the session'`: `expect(session.reload.status).to eq('completed')`.
- `'re-stamps the payment to what arrived when staff apply a short transfer'`: transfer £90.00 against a £97.00 session, `applied_by: admin`; `expect(order.reload.payment_status).to eq('partially_paid')`.
- `'queues a transfer for a cart that was never placed'` (Review Focus 3): session on an uncompleted cart, exact reference and amount; `expect(transfer.reload.state).to eq('unmatched')` and, in its own example, `expect(Spree::Order.count).to eq(0)`.
- `'queues a second payment for an order already paid'`: order paid by another method first; `expect(transfer.reload.state).to eq('unmatched')`.
- `'treats a replayed delivery as a no-op'`: ingest twice; `expect(Spree::BankPayments::IncomingTransfer.count).to eq(1)`.
- `gateway_webhook_spec.rb`: `'ingests the transfer and leaves nothing for Spree to settle'`: `expect(gateway.parse_webhook_event(body, headers)).to be_nil`.
- Un-pend Task 6's `'dispatches once the transfer is applied'`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/services/spree/bank_payments/apply_transfer_spec.rb spec/services/spree/bank_payments/ingest_transfer_spec.rb`
Expected: FAIL (`complete!` undefined, `payment_state` values).

- [ ] **Step 3: Implement**

`ApplyTransfer`, under `payment_session.order.with_lock`:
1. Take the session's payment (`find_or_create_payment!` as a fallback).
2. If the payment is still `pending`/`checkout` and its amount differs from `transfer.amount`, update the amount to `transfer.amount`.
3. Call `Spree.payment_capture_workflow.call(payment: payment)` and raise `Refused` unless it succeeded.
4. Call `payment_session.complete`, then update the transfer as before.

`IngestTransfer#matching_session` requires `session.order&.placed?` (use whichever predicate `Spree::Order` defines for `status == 'placed'`). `SuggestMatches` ranks only sessions on placed orders. `parse_webhook_event` ingests, then returns `nil`.

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/services spec/models/spree/bank_payments/gateway_webhook_spec.rb spec/workflows`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "Settle reconciled transfers through Spree's capture workflow"`

---

### Task 8: Expiry and reminders

**Files:**
- Modify: `app/jobs/spree/bank_payments/expire_sessions_job.rb`, `send_reminders_job.rb`
- Test: `spec/jobs/spree/bank_payments/{expire_sessions,send_reminders,poll}_job_spec.rb`

**Interfaces:**
- Consumes: Task 3 events, Task 7 settled statuses.
- Produces: for each open session past `expires_at`, on a healthy gateway:

  | Session owner | Result |
  |---|---|
  | A cart never placed | `expire`; no `bank_transfer.*` event |
  | A placed order, `payment_status` paid or overcharged | `cancel`; publishes `bank_transfer.session_superseded` |
  | A placed order, unpaid | `Spree.order_cancel_workflow.call(order:, reason: 'bank_transfer_expired', notify_customer: false)`; on success `expire`, then publishes `bank_transfer.expired` |

  An unhealthy gateway publishes `bank_transfer.reconciler_unhealthy` and touches nothing. Reminders go only for sessions on placed orders.

- [ ] **Step 1: Write the failing tests**

- `'cancels an unpaid placed order after the deadline'`: `expect(order.reload.status).to eq('canceled')`.
- `'releases the stock of the cancelled order'`: `expect(stock_item.reload.count_on_hand).to eq(on_hand_before + 1)`.
- `'expires an abandoned cart's session without an expired event'`: `expect(published('bank_transfer.expired')).to be_empty`.
- `'leaves an order paid another way alone'`: `expect(order.reload.status).to eq('placed')`.
- `'touches nothing while the reconciler is unhealthy'`: `expect(order.reload.status).to eq('placed')`.
- `'reports a cancellation Spree refuses and carries on'`: two gateways, the first order fulfilled (Spree refuses), the second unpaid; `expect(second_order.reload.status).to eq('canceled')`.
- `send_reminders_job_spec.rb`: `'does not remind a cart that was never placed'`: `expect(published('bank_transfer.reminder_due')).to be_empty`.
- Port the 5.x examples in all three files.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/jobs`
Expected: FAIL (`expire!`, `cancel!`, `allow_cancel?` path).

- [ ] **Step 3: Implement**

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/jobs`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "Expire unpaid orders through Spree's cancel workflow"`

---

### Task 9: What the Store API shows a storefront

**Files:**
- Create: `lib/spree/bank_payments/api_fields.rb` (registrations, called from `after_initialize`)
- Test: `spec/requests/spree/bank_payments/store_api_spec.rb`

**Interfaces:**
- Consumes: Task 4 `#quote`, Task 5 discount.
- Produces (`Spree.api.extension_fields.attribute`, `spree/api/lib/spree/api/extension_fields.rb:49`):
  - `:payment_method_serializer`, field `bank_transfer`: `{ 'discount_percent' => String, 'expiry_days' => Integer }` for a bank gateway, `nil` otherwise.
  - `:payment_serializer`, field `bank_transfer`: the payment's session `quote` for a bank gateway payment, `nil` otherwise. This covers the cart's and the placed order's payments.

- [ ] **Step 1: Write the failing tests**

Drive the whole checkout through the Store API with a guest token:
- `'lists the discount on the payment method'`: `GET /api/v3/store/payment_methods` (or the cart's methods endpoint core exposes); `expect(bank_method['bank_transfer']['discount_percent']).to eq('3')`.
- `'quotes the discounted amount when the session is created'`: `expect(json_response['external_data']['bank_transfer']['amount']).to eq('97.00')`.
- `'places the order with the payment pending'`: `POST .../payment_sessions/:id/complete`, then `POST /api/v3/store/carts/:id/complete`; `expect(json_response['payment_status']).to eq('authorized')`.
- `'shows the reference and bank details on the placed order'`: `GET /api/v3/store/orders/:id`; `expect(payment['bank_transfer']['reference']).to eq(session.reference)` and, in its own example, `expect(payment['bank_transfer']['bank_details'].first['fields']).not_to be_empty` (match `DetailSet#to_h`'s keys).
- `'shows nothing extra on other payments'`: a check payment; `expect(payment['bank_transfer']).to be_nil`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/requests/spree/bank_payments/store_api_spec.rb`
Expected: FAIL, the `bank_transfer` keys are missing.

- [ ] **Step 3: Implement the two registrations**

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/requests`
Expected: PASS.

- [ ] **Step 5: Commit**

`git commit -m "Show storefronts the bank transfer quote and order instructions"`

---

### Task 10: Release readiness

**Files:**
- Modify: `lib/spree/bank_payments/version.rb` (`'6.0.0'`), `CHANGELOG.md` (`## 6.0.0`, with "Upgrading from 5.3"), `README.md`
- Create: `docs/upgrading-5-to-6.md`, `CLAUDE.md` (repo guidance in the style of `spree-shipstation`'s: commands, architecture, the Spree 6 facts this code rests on)

- [ ] **Step 1: Write the docs**

The CHANGELOG and upgrade page state:
- Requirements: Spree `~> 6.0`, Ruby 3.3+; Spree 5.6 stays on 5.3.x.
- Run 5.3.0's migrations before upgrading.
- Spree's own `bin/rake spree:upgrade` comes first.
- There is no admin UI until the dashboard plugin ships (part 2). Transfers still reconcile automatically and expire on schedule.
- The storefront flow: create session, read `external_data.bank_transfer`, complete session, complete cart, read `payments[].bank_transfer` on the order.
- The event list, and that payload keys are strings.
- The payment-method type is now `bank_transfer`.
- `#bank_details` is removed.

- [ ] **Step 2: Bring the specs no earlier task owns to green**

These cover behaviour the port must not change, so their expected values stay as they are; only Spree 6 setup changes (stores, carts, factories, preferences stored as JSON):
- `spec/models/spree/bank_payments/{account_data,bank_account,detail_set,incoming_transfer,reconciler_state,transfer_data}_spec.rb`
- `spec/models/spree/bank_payments/reconcilers/`
- `spec/services/spree/bank_payments/{account_linkage,health_reporter,reference_generator,sync_accounts}_spec.rb`
- `spec/jobs/spree/bank_payments/poll_job_spec.rb`
- `spec/migrations/`

A migration spec that reads legacy preferences may need the Spree 6 JSON shape. Change its setup, never the migration.

Run: `bundle exec rspec spec/models spec/services spec/jobs spec/migrations`
Expected: PASS.

- [ ] **Step 3: Full suite, zero deprecations**

Run: `bundle exec rake > tmp/full.txt 2>&1; tail -3 tmp/full.txt; grep -c "DEPRECATION WARNING" tmp/full.txt`
Expected: `0 failures`, then `0`.

- [ ] **Step 4: Run against the oldest Spree the gemspec allows**

Run: `SPREE_VERSION=6.0.0 bundle update spree && bundle exec rspec; bundle update spree`
Expected: `0 failures`.

- [ ] **Step 5: Commit**

`git commit -m "Document the Spree 6 release"`

Do not tag, push the `5-3-stable` branch or publish: the release waits for part 2, and for the maintainer.
