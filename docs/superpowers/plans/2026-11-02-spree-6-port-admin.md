# Spree 6 port, part 2: the admin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Staff can run bank transfers from Spree 6's dashboard again: the unmatched-transfers queue, recording a received transfer, bank accounts, the order's bank transfer panel, and the payment method's setup guide.

**Architecture:** Two halves that ship together. The **back end** is Admin API v3 endpoints in the gem (`Spree::Api::V3::Admin::ResourceController` subclasses under `/api/v3/admin/bank_payments/…`, Alba serializers, a `bank_payments` permission scope) wrapping the services part 1 already has: `IngestTransfer`, `SuggestMatches`, `ApplyTransfer`, `SyncAccounts`. The **front end** is a dashboard plugin package, `@aypex/spree-bank-payments-dashboard`, in a `dashboard/` folder of the gem repo: TypeScript source, file routes, slots, registered with `defineDashboardPlugin`. Hosts install it from npm, and the dashboard auto-discovers it.

**Tech Stack:** Back end: Ruby ≥ 3.3, Spree `~> 6.0` (spree_api), RSpec controller specs with Spree's `API v3 Admin` shared contexts. Front end: TypeScript, React 19, `@spree/dashboard-core` / `@spree/dashboard-ui` / `@spree/admin-sdk` `~6.0.1`, TanStack Router file routes and React Query, react-hook-form, i18next, Biome, pnpm.

**Spec:** `docs/design-spec.md` ("Admin surfaces") and the 5.x behaviour at tag `v5.3.0` (`app/controllers/spree/admin/bank_transfers_controller.rb`, `bank_accounts_controller.rb`, `app/views/spree/admin/**`, `app/views/spree/bank_payments/admin/_order_panel.html.erb`), which this rebuilds. Spree 6 dashboard plugin docs: `docs/developer/dashboard/` in the Spree source, and the reference plugin `packages/dashboard-plugin-example/`.

**Part 2 of 4.** Part 1 (the backend on Spree 6) is merged. Part 3 is a host storefront's checkout; part 4 wires a host app. This part ends with the gem and the plugin releasable together as 6.0.0.

## Decisions

1. **Distribution is public npm,** chosen by the maintainer: `@aypex/spree-bank-payments-dashboard`, version tracking the gem's (6.0.0). It is published from GitHub Actions by trusted publishing (OIDC) on the same `v*` tag that releases the gem.
2. **The plugin lives in the gem repo,** at `dashboard/`, with its own `package.json`. One tag releases both halves, so the endpoints and the screens never drift apart. The gemspec's `files` already excludes it.
3. **Endpoints are namespaced** under `/api/v3/admin/bank_payments/`, as Spree's plugin docs require of extensions.
4. **Permissions** are one scope, `bank_payments` (keys `read_bank_payments`, `write_bank_payments`), registered with `Spree.permissions.register_scope`. Reads (lists, suggestions, health) need read; everything that changes something (record, apply, ignore, accounts, sync) needs write.
5. **Records reach their store through their payment method**, so every controller scopes to `payment_method_id IN current_store.payment_methods`. Spree's `for_store` returns `none` for a model with no store association.
6. **The 5.x rules carry over unchanged:**
   - Applying a transfer whose amount or currency differs from the session's takes two deliberate steps: the first request is refused with both amounts, and only a second one carrying `confirm_mismatch: true` applies it.
   - A transfer received on one gateway is never applied to another gateway's session.
   - Ignoring needs a reason.
   - A manually recorded transfer's identity is derived from what was typed, so resubmitting the form records nothing twice.
   - A synced account's currency and details cannot be edited, and it cannot be deleted, only deactivated.
   - Offering an account withdraws any other offered account in its currency.
7. **Prefixed ids:** `IncomingTransfer` is `btxfr_` and `BankAccount` is `bacct_`. `has_prefix_id` derives them from the primary key, so no migration is needed.
8. **No storefront code.** The plugin only uses `@spree/dashboard-core` and `@spree/dashboard-ui`, never `@spree/dashboard` (the app shell).

## Global Constraints

- Everything from part 1's Global Constraints still holds: public repo with example values only, `I18n.t` never `Spree.t`, zero `DEPRECATION WARNING`, declared events, PostgreSQL.
- Admin API error shape is Spree's `{ error: { code, message, details? } }`; field errors go under `details` on a 422.
- Money in and out of the Admin API is a canonical decimal string with the currency's decimals (`"97.00"`), written with `Spree::Money::Rounding.format`; amounts arriving as JSON numbers are refused (`invalid_money_format`), as Spree's own endpoints do.
- Plugin peer dependencies: `@spree/admin-sdk`, `@spree/dashboard-core` and `@spree/dashboard-ui` at `>=6.0.1 <7`; React, react-dom, i18next, react-i18next, `@tanstack/react-query` and `@tanstack/react-router` at the host's ranges (copy them from a dashboard-starter `package.json` of `@spree/cli` 3.6.1).
- The plugin imports icons from `@spree/dashboard-ui/icons`, never from `lucide-react` directly: the host does not list it.
- Every user-facing string in the plugin is an i18n key under `admin.bank_payments.*` in `dashboard/src/locales/en.json`.

## Review Focus

1. **Staff double-click Apply, or two of them apply the same transfer at once.** Exactly one payment is captured, and the second request gets a clear refusal. (Task 4, `transfers_controller_spec.rb`.)
2. **Staff apply a transfer to a session on a different store's order.** It must 404 as if the session did not exist, never apply. (Task 4.)
3. **A staff member with a role that grants `read_bank_payments` only** sees the queue but cannot apply, ignore, record or change accounts: 403 from the API, and the plugin hides those controls. (Task 1, Task 4, Task 7.)
4. **The queue holds hundreds of unmatched transfers.** The list paginates server-side, and suggestions are fetched per transfer, not computed for the whole page at once. (Task 2, Task 7.)
5. **An account is offered while another account in the same currency is offered.** The first is withdrawn in the same transaction; the partial unique index never raises a 500. (Task 5.)

---

### Task 1: Admin API foundation

**Files:**
- Modify: `app/models/spree/bank_payments/incoming_transfer.rb` (`has_prefix_id :btxfr`, `whitelisted_ransackable_attributes = %w[state currency payer_name reference_raw occurred_at amount]`, `whitelisted_ransackable_associations = %w[bank_account]`)
- Modify: `app/models/spree/bank_payments/bank_account.rb` (`has_prefix_id :bacct`, ransackable `currency offered active`)
- Create: `app/controllers/spree/api/v3/admin/bank_payments/base_controller.rb` (`Spree::Api::V3::Admin::BankPayments::ResourceController < Spree::Api::V3::Admin::ResourceController`: `scoped_resource :bank_payments`; `store_scope` overridden to scope by the store's payment methods)
- Create: `config/routes.rb` (`Spree::Core::Engine.add_routes`, namespace `api/v3/admin/bank_payments`, `defaults: { format: 'json' }`)
- Modify: `config/initializers/spree.rb` (permission scope registration), `config/locales/en.yml` (`spree.permissions_catalog.resources.bank_payments.label` / `.description`)
- Test: `spec/support/admin_api.rb` (requires `spree/api/testing_support/v3/base`, defines `json_response`, sets `routes { Spree::Core::Engine.routes }` for `type: :controller` specs under `spec/controllers/spree/api/v3/admin/`), `spec/controllers/spree/api/v3/admin/bank_payments/permissions_spec.rb`

**Interfaces:**
- Produces: the base controller every later controller subclasses; `Spree::BankPayments::IncomingTransfer#prefixed_id` (`btxfr_…`), `Spree::BankPayments::BankAccount#prefixed_id` (`bacct_…`); permission keys `read_bank_payments`, `write_bank_payments`.

- [ ] **Step 1: Write the failing tests**
  - `'registers a bank_payments permission scope'`: `expect(Spree.permissions.catalog.keys).to include('read_bank_payments', 'write_bank_payments')` (use the catalog's real accessor; see `spree/core/lib/spree/core/permissions/`).
  - `'gives incoming transfers a btxfr_ prefixed id'`: `expect(create(:bank_transfer_incoming_transfer).prefixed_id).to start_with('btxfr_')`.
  - `'gives bank accounts a bacct_ prefixed id'`: the same, with `bacct_`.
- [ ] **Step 2: Run them to verify they fail** — `bundle exec rspec spec/controllers/spree/api/v3/admin/bank_payments/permissions_spec.rb` → FAIL.
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run them to verify they pass**
- [ ] **Step 5: Commit** — `Add the Admin API foundation: prefixed ids and a bank_payments permission scope`

---

### Task 2: The unmatched-transfers queue

**Files:**
- Create: `app/controllers/spree/api/v3/admin/bank_payments/transfers_controller.rb` (`index`, `show`, `suggestions`)
- Create: `app/serializers/spree/api/v3/admin/bank_payments/incoming_transfer_serializer.rb`, `suggestion_serializer.rb`
- Test: `spec/controllers/spree/api/v3/admin/bank_payments/transfers_controller_spec.rb`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `GET /bank_payments/transfers` with `q[state_eq]` (default `unmatched`), `sort` (default `-occurred_at`), `page` and `limit`. Returns `{ data: [IncomingTransfer], meta }`.
  - `GET /bank_payments/transfers/:id` returns `IncomingTransfer`.
  - `GET /bank_payments/transfers/:id/suggestions` returns `{ data: [Suggestion] }`. This is a `read_actions` member action.
  - `IncomingTransfer` JSON: `id`, `state` (`unmatched`/`applied`/`ignored`), `amount`, `currency`, `reference` (as received), `payer_name`, `occurred_at`, `provider`, `payment_method_id`, `bank_account` (`{ id, label, pooled }` or null), `applied_at`, `ignored_reason`, `payment_session_id`, `order` (`{ id, number }` or null).
  - `Suggestion` JSON: `payment_session_id`, `reference`, `amount`, `currency`, `expires_at`, `order` (`{ id, number, email, customer_name }`), `exact_match` (amount and currency equal).

- [ ] **Step 1: Write the failing tests** (`include_context 'API v3 Admin authenticated'`)
  - `'lists unmatched transfers by default'`.
  - `'filters by state'`.
  - `"excludes another store's transfers"`.
  - `'paginates'` (`limit: 2` over 3 rows returns 2 rows, and `meta.count` is 3).
  - `'shows a transfer'`.
  - `'suggests the exact match first'`.
  - `'answers 403 without read_bank_payments'` (`include_context 'API v3 Admin with custom permissions'`, `custom_permissions` `[]`).
  - Each example asserts one thing about `json_response`.
- [ ] **Step 2: Run them to verify they fail**
- [ ] **Step 3: Implement.** Suggestions come from `SuggestMatches.new(transfer:).call`. Money goes through `Spree::Money::Rounding.format`.
- [ ] **Step 4: Run them to verify they pass**
- [ ] **Step 5: Commit** — `List unmatched transfers and their suggested matches in the Admin API`

---

### Task 3: Recording a received transfer

**Files:**
- Modify: `transfers_controller.rb` (`create`)
- Create: `app/services/spree/bank_payments/record_manual_transfer.rb` (the 5.x form logic, as a service)
- Test: `transfers_controller_spec.rb` (`describe 'POST create'`), `spec/services/spree/bank_payments/record_manual_transfer_spec.rb`

**Interfaces:**
- Produces:
  - `POST /bank_payments/transfers` with `{ payment_method_id, amount, currency, payer_name?, reference, occurred_at }`. It returns `201` with `IncomingTransfer` plus `already_recorded: Boolean`, or a `422` with field `details`.
  - `RecordManualTransfer.call(payment_method:, amount:, currency:, reference:, payer_name:, occurred_at:, recorded_by:) → [IncomingTransfer, already_recorded]`. It raises `ActiveModel::ValidationError` for bad input.
  - The provider transaction id is `"manual-#{sha256(pm_id | amount | currency | normalized reference | payer name downcased | occurred date)[0, 32]}"`, exactly as at `v5.3.0`.

- [ ] **Step 1: Write the failing tests**
  - `'applies an exact match at once'` (`state` is `applied`).
  - `'queues anything else'`.
  - `'records nothing twice when the form is resubmitted'` (the second response has `already_recorded` true, and `IncomingTransfer.count` is 1).
  - `'refuses an amount that is not positive'` (422, with `details.amount`).
  - `"refuses another store's payment method"` (422 on `payment_method_id`).
  - `'refuses a JSON number for the amount'` (422, `invalid_money_format`).
  - `'answers 403 without write_bank_payments'`.
- [ ] **Steps 2-5** — commit `Record a received transfer through the Admin API`

---

### Task 4: Applying and ignoring

**Files:**
- Modify: `transfers_controller.rb` (`apply`, `ignore`)
- Test: `transfers_controller_spec.rb`

**Interfaces:**
- Produces:
  - `POST /bank_payments/transfers/:id/apply` with `{ payment_session_id, confirm_mismatch? }`, returning `IncomingTransfer`. The refusals:

    | Code | Status | When |
    |---|---|---|
    | `already_applied` | 422 | the transfer is already applied |
    | `gateway_mismatch` | 422 | it was received on a different gateway |
    | `amount_mismatch` | 422 | the amounts differ; `details` carries `transfer_amount`, `session_amount` and `currency` |
    | `apply_refused` | 422 | `ApplyTransfer::Refused` |
    | `not_found` | 404 | the session is on another store's order, or does not exist |

  - `POST /bank_payments/transfers/:id/ignore` with `{ reason }` (required). Returns `IncomingTransfer`; `already_applied` is a 422.
  - `applied_by` is the current admin.

- [ ] **Step 1: Write the failing tests**
  - `'applies a transfer to the session staff chose'` (order `payment_status` is `paid`).
  - `'records who applied it'`.
  - `'refuses a mismatched amount without confirmation'` (one example asserting the code, one asserting `details.session_amount` is `"97.00"`).
  - `'applies a mismatched amount once confirmed'` (`payment_status` is `partially_paid`).
  - `"refuses another gateway's session"`.
  - `"answers 404 for another store's session"` (Review Focus 2).
  - `'refuses to apply twice'` (Review Focus 1: apply, then apply again; the second is `already_applied` and exactly one capture is recorded).
  - `'ignores with a reason'`, `'refuses to ignore without a reason'`, `'refuses to ignore an applied transfer'`.
  - `'answers 403 to read-only staff'` (Review Focus 3).
- [ ] **Steps 2-5** — commit `Apply and ignore transfers through the Admin API`

---

### Task 5: Bank accounts

**Files:**
- Create: `app/controllers/spree/api/v3/admin/bank_payments/accounts_controller.rb` (nested under a payment method: `index`, `create`, `update`, `destroy`, and collection actions `sync_plan` (read) and `sync`)
- Create: `app/serializers/spree/api/v3/admin/bank_payments/bank_account_serializer.rb`
- Test: `spec/controllers/spree/api/v3/admin/bank_payments/accounts_controller_spec.rb`

**Interfaces:**
- Produces:
  - `GET /bank_payments/payment_methods/:payment_method_id/accounts` returns `{ data: [BankAccount] }`.
  - `POST` the same path with `{ currency, details }` creates a manual account.
  - `PATCH .../accounts/:id` with `{ offered?, active?, currency?, details? }`.
  - `DELETE .../accounts/:id` soft-deletes it; a synced account is a 422 `synced_account`.
  - `GET .../accounts/sync_plan` returns `{ create: [...], update: [...], deactivate: [...], skipped: [...] }`, the `SyncAccounts#plan` diff.
  - `POST .../accounts/sync` applies it; an empty provider response is a 422 `sync_empty`.
  - `BankAccount` JSON: `id`, `currency`, `offered`, `active`, `pooled`, `synced`, `provider_account_id`, `detail_sets` (`DetailSet#to_h` list), `created_at`.
  - Offering an account withdraws the other offered account in its currency, in one transaction.
  - A synced account refuses `currency` and `details` changes with a 422 `synced_account`.

- [ ] **Step 1: Write the failing tests**
  - `'lists the accounts of a payment method'`.
  - `"answers 404 for another store's payment method"`.
  - `'creates a manual account'`.
  - `'offers an account'`.
  - `'withdraws the other offered account in its currency'` (Review Focus 5).
  - `'refuses to edit a synced account's details'`.
  - `'soft-deletes a manual account'`.
  - `'refuses to delete a synced account'`.
  - `'previews a sync'`, `'applies a sync'`, `'refuses an empty sync'` (stub the reconciler's `sync_accounts`, the provider boundary).
- [ ] **Steps 2-5** — commit `Manage bank accounts through the Admin API`

---

### Task 6: Order panel and gateway health

**Files:**
- Create: `app/controllers/spree/api/v3/admin/bank_payments/orders_controller.rb` (`show`, keyed by the order's prefixed id)
- Create: `app/controllers/spree/api/v3/admin/bank_payments/health_controller.rb` (`show`, keyed by payment method)
- Create: the matching serializers
- Test: `spec/controllers/spree/api/v3/admin/bank_payments/{orders,health}_controller_spec.rb`

**Interfaces:**
- Produces:
  - `GET /bank_payments/orders/:order_id` returns `{ sessions: [{ id, reference, status, amount, currency, expires_at, bank_details }], transfers: [IncomingTransfer] }`. Empty arrays mean the order is not a bank transfer order.
  - `GET /bank_payments/payment_methods/:payment_method_id/health` returns:
    - `health` (`ok` / `transient` / `consent_revoked`);
    - `reconciler`;
    - `last_successful_run_at`, `last_error`, `consecutive_failures`;
    - `webhook_url` (`payment_method.webhook_url`);
    - `offered_currencies`, the currencies with an offered account (an empty list means the method is offered nowhere).

- [ ] **Step 1: Write the failing tests**
  - `'shows the bank transfer sessions of an order'`.
  - `'shows the transfer applied to it'`.
  - `'answers with empty lists for an order paid another way'`.
  - `"answers 404 for another store's order"`.
  - `'reports the reconciler health'`.
  - `'gives the webhook URL to paste into the provider'`.
  - `'lists no currencies before an account is offered'`.
- [ ] **Steps 2-5** — commit `Show an order's bank transfer and the gateway's health in the Admin API`

---

### Task 7: The dashboard plugin package

**Files:**
- Create: `dashboard/package.json`:
  - name `@aypex/spree-bank-payments-dashboard`, version `6.0.0`, `"type": "module"`, `main`/`types`/`exports` pointing at `./src/index.tsx`, `"files": ["src", "README.md"]`;
  - `"spree": { "dashboard": { "plugin": true, "routes": "./src/routes" } }`, `"sideEffects": ["./src/index.tsx"]`;
  - peer and dev dependencies per Global Constraints, `"packageManager": "pnpm@11.13.1"`.
- Create: `dashboard/tsconfig.json`, `dashboard/biome.json` (copied from `packages/dashboard-plugin-example/` in the Spree source, with paths adjusted), `dashboard/README.md`, `dashboard/src/index.tsx`, `dashboard/src/client.ts`, `dashboard/src/types.ts`, `dashboard/src/locales/en.json`
- Create: `.github/workflows/dashboard.yml` (on push and PR: `pnpm install --frozen-lockfile`, `pnpm typecheck`, `pnpm lint` in `dashboard/`)

**Interfaces:**
- Produces:
  - `bankPaymentsClient` in `client.ts`: typed wrappers over `adminClient.request` for every Task 2-6 endpoint: `transfers.list/get/suggestions/record/apply/ignore`, `accounts.list/create/update/destroy/syncPlan/sync`, `orderPanel(orderId)`, `health(paymentMethodId)`.
  - TS types in `types.ts`, hand-written to match Tasks 2-6 exactly.
  - A nav entry (`key: 'orders.bank_transfers'`, under Orders, path `/bank-transfers`, `subject: 'incoming_transfer'`, action `read`).
  - The translations bundle.

- [ ] **Step 1:** `cd dashboard && corepack pnpm install` → lockfile created.
- [ ] **Step 2:** `corepack pnpm typecheck && corepack pnpm lint` → both exit 0.
- [ ] **Step 3: Commit** — `Scaffold the dashboard plugin package`

---

### Task 8: Queue, transfer and record screens

**Files:**
- Create: `dashboard/src/routes/bank-transfers.index.tsx` (`/_authenticated/$storeId/bank-transfers/`), `bank-transfers.$transferId.tsx`, `bank-transfers.new.tsx`
- Create: `dashboard/src/pages/transfers-list.tsx`, `transfer-detail.tsx`, `record-transfer.tsx`; the `defineTable('bank_transfers', …)` declaration goes in `index.tsx`

**Behaviour:**
- **List:** `ResourceTable` over `transfers.list`, with columns occurred, amount, reference, payer, account (a `pooled` badge when pooled) and state. A state filter defaults to `unmatched`, and each row links to the detail page.
- **Detail:**
  - It shows the transfer, and its suggestions fetched from `transfers.suggestions`.
  - Exact matches are marked, and each suggestion has an Apply button.
  - When the API answers `amount_mismatch`, a `confirm-dialog` (from `@spree/dashboard-ui`) shows both amounts; confirming resends with `confirm_mismatch: true`.
  - Ignore opens a dialog that requires a reason.
  - After apply or ignore, the transfer and list queries are invalidated (`useResourceMutation({ invalidate })`) and staff return to the list.
- **Record:** a react-hook-form form (payment method select over the store's bank transfer methods, amount, currency, payer, reference, date received). API errors map to fields with `mapSpreeErrorsToForm`. On success it shows whether the transfer was applied, queued or already recorded.
- **Permissions:** write controls (Apply, Ignore, Record) render only when `usePermissions().permissions.can('update', 'incoming_transfer')` (Review Focus 3).

- [ ] **Step 1:** typecheck and lint pass.
- [ ] **Step 2: Commit** — `Add the transfer queue, detail and record screens to the dashboard plugin`

---

### Task 9: Bank accounts screen, order panel and setup guide

**Files:**
- Create: `dashboard/src/routes/bank-transfers.accounts.$paymentMethodId.tsx`, `dashboard/src/pages/accounts.tsx`
- Create: `dashboard/src/slots/order-bank-transfer-card.tsx` (`order.form_sidebar`), `payment-method-guide.tsx` (`payment_method.guide.bank_transfer`), `payment-method-actions.tsx` (`payment_method.actions.bank_transfer`, a "Bank accounts" link)

**Behaviour:**
- **Accounts:**
  - One card per account, showing currency, detail sets, and offered, active, pooled and synced badges.
  - Offer and withdraw switches, Deactivate, and Delete (manual accounts only).
  - "Sync from provider" fetches `syncPlan`, shows the diff in a dialog, and applies it on confirm.
- **Order card:** renders nothing when the order has no bank transfer sessions. Otherwise it shows the reference (with `copy-to-clipboard-button`), amount, status, deadline (`relative-time`) and any applied transfer, with a link to it.
- **Setup guide:**
  - Shows health, last poll and last error.
  - Shows the webhook URL with a copy button.
  - Warns plainly when no currency has an offered account.

- [ ] **Step 1:** typecheck and lint pass.
- [ ] **Step 2: Commit** — `Add the bank accounts screen, order card and setup guide to the dashboard plugin`

---

### Task 10: Try it in a real dashboard

Not committed: verification only. It runs in a host dashboard app made from Spree's dashboard-starter, which installs the plugin from an `npm pack` tarball (what npm will publish). Nothing in the host is committed.

- [ ] **Step 1:** In the host's `package.json`, add `"@aypex/spree-bank-payments-dashboard": "file:<the packed tarball>"`. Then run `corepack pnpm install` and `VITE_BASE_PATH=/dashboard/ corepack pnpm build` → exit 0. This proves discovery, file routes and Tailwind scanning.
- [ ] **Step 2:** Boot a Spree 6 backend with the gem (the gem's dummy app will do), and seed one bank transfer gateway with an offered account, one placed bank transfer order and two unmatched transfers.
- [ ] **Step 3:** With the dashboard dev server running, walk every screen in Chrome and screenshot it: the queue, a transfer with its suggestions, a mismatch confirmation, an ignore, recording a transfer, the accounts screen with a sync preview, the order card, and the setup guide. Fix what is broken (TDD on the API side for any back-end defect).
- [ ] **Step 4:** Stop the servers; the host is scratch and is thrown away.

---

### Task 11: Release plumbing and docs

**Files:**
- Modify: `.github/workflows/release.yml` (a second job, `npm`, on the same `v*` tag: `actions/setup-node`, `npm publish --provenance --access public` in `dashboard/` with `id-token: write`, under the npm trusted publisher)
- Modify: `README.md` (the "Applying transfers by hand" section becomes "The dashboard", with install steps: `pnpm add @aypex/spree-bank-payments-dashboard` in the dashboard app, role permissions, screens; the console snippets stay as a fallback), `CHANGELOG.md` (6.0.0: the Admin API and the plugin), `docs/upgrading-5-to-6.md`, `CLAUDE.md`

- [ ] **Step 1:** Full gem suite: `bundle exec rake` → 0 failures, 0 `DEPRECATION WARNING`. Plugin: `corepack pnpm typecheck && corepack pnpm lint` → 0.
- [ ] **Step 2: Commit** — `Document the dashboard and publish it with the gem`

Release prerequisites, for the maintainer (not part of this plan): an npm org `aypex`, the package's first publish, and a trusted publisher registered for `aypex-io/spree-bank_payments`, workflow `release.yml`. Then tag `v6.0.0`, and cut `5-3-stable` from `v5.3.0`.
