# AypexBankTransfer Core Gem — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `aypex_bank_transfer`, a bank-agnostic Spree 5.6 extension letting customers check out by bank transfer at a configurable discount, with pluggable reconciliation and a manual reconciler that ships working out of the box.

**Architecture:** A `Spree::PaymentMethod` subclass mints a unique payment reference into a `Spree::PaymentSessions::BankTransfer` STI record at checkout. Observed bank transfers land in an `IncomingTransfer` table keyed by provider transaction id (the idempotency guard), and a single `IngestTransfer` service auto-applies them to a session only on an exact reference + amount + currency match — everything else queues for an admin. An expiry job cancels unpaid orders, but only when the reconciler reports healthy.

**Tech Stack:** Ruby 4.0, Rails 8.1, Spree 5.6 (`spree`, `spree_admin`), RSpec + `spree_dev_tools`, PostgreSQL (with `pg_trgm`), Sidekiq for jobs.

**Spec:** `docs/superpowers/specs/2026-08-15-spree-bank-transfer-design.md`

## Global Constraints

- **PostgreSQL only.** The gem uses `jsonb`, partial unique indexes, and `pg_trgm`. Do not add MySQL to CI.
- **Discounts are always computed from `order.item_total`, never `order.total`.** `order.total` is gross, includes shipping and tax, and mishandles VAT on tax-inclusive stores.
- **Auto-apply demands certainty.** Money is applied automatically only on exact normalized reference *and* exact amount *and* exact currency, against a session in `pending` or `processing`. Every other case sets state `unmatched` and queues for a human. There are no exceptions to this rule anywhere in the codebase.
- **Never cancel while blind.** Any code path that cancels an order or releases stock must first confirm `reconciler.healthy?`.
- **Notifications are Spree events first.** Publish via `Spree::Events.publish('<dotted.name>', payload_hash)`; the bundled mailer is a subscriber stores can disable. Never call a mailer directly from domain code. There is no `Spree::Bus` in Spree 5.6.
- **Event payloads carry serializable primitives only** — IDs and strings, never ActiveRecord objects. Subscribers run async through ActiveJob by default.
- Gem name: `aypex_bank_transfer`. Namespace: `AypexBankTransfer`. Repo: `aypex-io/aypex_bank_transfer`.
- Spree dependency floor: `>= 5.6.0`.
- Surcharging language is prohibited. All customer-facing copy says "discount" or "save", never "fee" or "surcharge".

---

## File Structure

| Path | Responsibility |
|---|---|
| `lib/aypex_bank_transfer.rb` | Gem entrypoint |
| `lib/aypex_bank_transfer/engine.rb` | Rails engine, decorator activation |
| `lib/aypex_bank_transfer/version.rb` | Version constant |
| `lib/aypex_bank_transfer/factories.rb` | FactoryBot factories for consumers |
| `lib/aypex_bank_transfer/testing_support/reconciler_shared_examples.rb` | The cross-gem contract test |
| `config/initializers/spree.rb` | Payment method + event registration |
| `db/migrate/*` | Schema |
| `app/models/aypex_bank_transfer/base.rb` | Shared AR base class |
| `app/models/aypex_bank_transfer/gateway.rb` | The payment method + preferences |
| `app/models/aypex_bank_transfer/incoming_transfer.rb` | Observed transfer, audit log, queue |
| `app/models/aypex_bank_transfer/reconciler_state.rb` | Health state per payment method |
| `app/models/spree/payment_sessions/bank_transfer.rb` | STI payment session |
| `app/models/aypex_bank_transfer/transfer_data.rb` | Value object crossing the gem boundary |
| `app/models/aypex_bank_transfer/reconcilers/base.rb` | The published contract |
| `app/models/aypex_bank_transfer/reconcilers/manual.rb` | Default no-op reconciler |
| `app/services/aypex_bank_transfer/reference_generator.rb` | Crockford base32 references |
| `app/services/aypex_bank_transfer/ingest_transfer.rb` | Match and apply |
| `app/services/aypex_bank_transfer/suggest_matches.rb` | Ranked candidates for unmatched |
| `app/services/aypex_bank_transfer/apply_discount.rb` | Discount adjustment lifecycle |
| `app/jobs/aypex_bank_transfer/expire_sessions_job.rb` | Expiry with health gate |
| `app/jobs/aypex_bank_transfer/poll_job.rb` | Drives the reconciler, records health |
| `app/jobs/aypex_bank_transfer/send_reminders_job.rb` | T-2 / T-1 reminders |
| `app/models/aypex_bank_transfer/payment_decorator.rb` | Hooks discount to payment creation |
| `app/mailers/aypex_bank_transfer/instructions_mailer.rb` | Default notification subscriber |
| `app/controllers/spree/admin/bank_transfers_controller.rb` | Unmatched queue |
| `app/views/spree/admin/...` | Admin surfaces |
| `app/views/spree/checkout/payment/_aypex_bank_transfer.html.erb` | Storefront payment step |

---

### Task 1: Gem scaffold, engine, and CI

**Files:**
- Create: `aypex_bank_transfer.gemspec`, `Gemfile`, `Rakefile`, `bin/rails`, `.rspec`, `.gitignore`, `README.md`, `LICENSE`
- Create: `lib/aypex_bank_transfer.rb`, `lib/aypex_bank_transfer/version.rb`, `lib/aypex_bank_transfer/engine.rb`
- Create: `config/initializers/spree.rb`
- Create: `app/models/aypex_bank_transfer/base.rb`
- Create: `spec/spec_helper.rb`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing
- Produces: `AypexBankTransfer::VERSION`, `AypexBankTransfer::Engine`, `AypexBankTransfer::Base` (abstract AR class all gem models inherit)

- [ ] **Step 1: Create the gemspec**

```ruby
# aypex_bank_transfer.gemspec
lib = File.expand_path('../lib/', __FILE__)
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require 'aypex_bank_transfer/version'

Gem::Specification.new do |s|
  s.platform    = Gem::Platform::RUBY
  s.name        = 'aypex_bank_transfer'
  s.version     = AypexBankTransfer::VERSION
  s.summary     = 'Bank transfer checkout for Spree, with pluggable payment reconciliation'
  s.description = 'Adds a bank transfer payment method to Spree with an optional discount, ' \
                  'unique payment references, automatic reconciliation of incoming transfers, ' \
                  'and an admin queue for payments that cannot be matched automatically.'
  s.required_ruby_version = '>= 3.3'

  s.author   = 'Aypex'
  s.email    = 'hello@aypex.io'
  s.homepage = 'https://github.com/aypex-io/aypex_bank_transfer'
  s.license  = 'MIT'

  s.files = Dir['{app,config,db,lib}/**/*', 'LICENSE', 'Rakefile', 'README.md']
  s.require_path = 'lib'

  spree_opts = '>= 5.6.0'
  s.add_dependency 'spree', spree_opts
  s.add_dependency 'spree_admin', spree_opts

  s.add_development_dependency 'spree_dev_tools'
  s.add_development_dependency 'webmock'
end
```

- [ ] **Step 2: Create the version, entrypoint, and engine**

```ruby
# lib/aypex_bank_transfer/version.rb
module AypexBankTransfer
  VERSION = '0.1.0'.freeze
end
```

```ruby
# lib/aypex_bank_transfer.rb
require 'spree_core'
require 'aypex_bank_transfer/version'
require 'aypex_bank_transfer/engine'
```

```ruby
# lib/aypex_bank_transfer/engine.rb
module AypexBankTransfer
  class Engine < Rails::Engine
    require 'spree/core'
    isolate_namespace Spree
    engine_name 'aypex_bank_transfer'

    config.generators do |g|
      g.test_framework :rspec
    end

    def self.activate
      Dir.glob(File.join(File.dirname(__FILE__), '../../app/**/*_decorator*.rb')) do |c|
        Rails.configuration.cache_classes ? require(c) : load(c)
      end
    end

    config.to_prepare(&method(:activate).to_proc)
  end
end
```

- [ ] **Step 3: Create the abstract model base**

```ruby
# app/models/aypex_bank_transfer/base.rb
module AypexBankTransfer
  class Base < ::ActiveRecord::Base
    self.abstract_class = true

    def self.table_name_prefix
      'aypex_bank_transfer_'
    end
  end
end
```

- [ ] **Step 4: Create the Spree initializer**

Payment method registration is added here now; event registration lands in Task 10.

```ruby
# config/initializers/spree.rb
Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << AypexBankTransfer::Gateway
end
```

- [ ] **Step 5: Create Rakefile, bin/rails, .rspec, and spec_helper**

```ruby
# Rakefile
require 'bundler'
Bundler::GemHelper.install_tasks

require 'rspec/core/rake_task'
require 'spree/testing_support/extension_rake'

RSpec::Core::RakeTask.new

task :default do
  if Dir['spec/dummy'].empty?
    Rake::Task[:test_app].invoke
    Dir.chdir('../../')
  end
  Rake::Task[:spec].invoke
end

desc 'Generates a dummy app for testing'
task :test_app do
  ENV['LIB_NAME'] = 'aypex_bank_transfer'
  Rake::Task['extension:test_app'].execute(install_storefront: true, install_admin: true)
end
```

```ruby
# bin/rails
#!/usr/bin/env ruby
ENGINE_ROOT = File.expand_path('../..', __FILE__)
ENGINE_PATH = File.expand_path('../../lib/aypex_bank_transfer/engine', __FILE__)

require 'rails/all'
require 'rails/engine/commands'
```

```
# .rspec
--color
-r spec_helper
-f documentation
```

```ruby
# spec/spec_helper.rb
ENV['RAILS_ENV'] = 'test'

require File.expand_path('../dummy/config/environment.rb', __FILE__)
require 'spree_dev_tools/rspec/spec_helper'
require 'aypex_bank_transfer/factories'

Dir[File.join(File.dirname(__FILE__), 'support/**/*.rb')].sort.each { |f| require f }
```

Create `lib/aypex_bank_transfer/factories.rb` with an empty `FactoryBot.define do end` block for now — Task 3 fills it.

- [ ] **Step 6: Create CI (Postgres only)**

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  tests:
    name: Tests
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_PASSWORD: password
          POSTGRES_DB: spree_test
        ports: ['5432:5432']
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    env:
      DB: postgres
      DATABASE_URL: postgres://postgres:password@localhost:5432/spree_test
      RAILS_ENV: test
      CI: true
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.3'
          bundler-cache: true
      - name: Install libvips
        run: sudo apt-get update && sudo apt-get install -y libvips
      - name: Create test app
        run: bundle exec rake test_app
      - name: Run specs
        run: bundle exec rspec --format progress
```

- [ ] **Step 7: Verify the dummy app builds**

Run: `bundle install && bundle exec rake test_app`
Expected: dummy app generated under `spec/dummy` with no errors.

- [ ] **Step 8: Commit**

```bash
git add .
git commit -m "chore: scaffold aypex_bank_transfer gem"
```

---

### Task 2: Schema and core models

**Files:**
- Create: `db/migrate/20260815000001_create_aypex_bank_transfer_tables.rb`
- Create: `db/migrate/20260815000002_add_external_id_normalized_to_payment_sessions.rb`
- Create: `app/models/aypex_bank_transfer/incoming_transfer.rb`
- Create: `app/models/aypex_bank_transfer/reconciler_state.rb`
- Test: `spec/models/aypex_bank_transfer/incoming_transfer_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::Base` (Task 1)
- Produces:
  - `AypexBankTransfer::IncomingTransfer` with states `unmatched`/`applied`/`ignored`, scopes `.unmatched`, `.applied`, and `.normalize_reference(String) → String`
  - `AypexBankTransfer::ReconcilerState#healthy?(poll_interval_minutes) → Boolean`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/aypex_bank_transfer/incoming_transfer_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::IncomingTransfer do
  describe '.normalize_reference' do
    it 'upcases, strips non-alphanumerics, and folds Crockford ambiguities' do
      expect(described_class.normalize_reference('tkf-7q4x2')).to eq('TKF7Q4X2')
      expect(described_class.normalize_reference(' TKF 7Q4X2 ')).to eq('TKF7Q4X2')
      expect(described_class.normalize_reference('TKF/7Q4X2')).to eq('TKF7Q4X2')
      expect(described_class.normalize_reference('TKFO7I4L2')).to eq('TKF071412')
    end

    it 'returns an empty string for nil' do
      expect(described_class.normalize_reference(nil)).to eq('')
    end
  end

  describe 'uniqueness' do
    it 'rejects a duplicate provider transaction id' do
      create(:bank_transfer_incoming_transfer, provider: 'test', provider_transaction_id: 'TX1')
      duplicate = build(:bank_transfer_incoming_transfer, provider: 'test', provider_transaction_id: 'TX1')

      expect(duplicate).not_to be_valid
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/incoming_transfer_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::IncomingTransfer`

- [ ] **Step 3: Write the migrations**

```ruby
# db/migrate/20260815000001_create_aypex_bank_transfer_tables.rb
class CreateAypexBankTransferTables < ActiveRecord::Migration[8.1]
  def change
    create_table :aypex_bank_transfer_incoming_transfers do |t|
      t.string   :provider, null: false
      t.string   :provider_transaction_id, null: false
      t.decimal  :amount, precision: 10, scale: 2, null: false
      t.string   :currency, null: false
      t.string   :reference_raw
      t.string   :reference_normalized
      t.string   :payer_name
      t.datetime :occurred_at, null: false
      t.string   :state, null: false, default: 'unmatched'
      t.bigint   :payment_session_id
      t.bigint   :applied_by_id
      t.datetime :applied_at
      t.string   :ignored_reason
      t.jsonb    :raw_payload, null: false, default: {}
      t.timestamps
    end

    add_index :aypex_bank_transfer_incoming_transfers,
              %i[provider provider_transaction_id],
              unique: true, name: 'index_bt_transfers_on_provider_and_txn_id'
    add_index :aypex_bank_transfer_incoming_transfers,
              :reference_normalized, name: 'index_bt_transfers_on_reference_normalized'
    add_index :aypex_bank_transfer_incoming_transfers, :state,
              name: 'index_bt_transfers_on_state'
    add_index :aypex_bank_transfer_incoming_transfers, :payment_session_id,
              name: 'index_bt_transfers_on_payment_session_id'

    create_table :aypex_bank_transfer_reconciler_states do |t|
      t.bigint   :payment_method_id, null: false
      t.datetime :last_successful_run_at
      t.text     :last_error
      t.integer  :consecutive_failures, null: false, default: 0
      t.timestamps
    end

    add_index :aypex_bank_transfer_reconciler_states, :payment_method_id,
              unique: true, name: 'index_bt_reconciler_states_on_payment_method_id'
  end
end
```

```ruby
# db/migrate/20260815000002_add_external_id_normalized_to_payment_sessions.rb
class AddExternalIdNormalizedToPaymentSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :spree_payment_sessions, :external_id_normalized, :string

    # Partial unique index: bank transfer references must be globally unique per
    # payment method, forever, so a late payment quoting an old reference
    # resolves to exactly one session. Scoped to our STI type so other payment
    # session subclasses are unaffected.
    add_index :spree_payment_sessions,
              %i[payment_method_id external_id_normalized],
              unique: true,
              where: "type = 'Spree::PaymentSessions::BankTransfer'",
              name: 'index_payment_sessions_on_bank_transfer_reference'
  end
end
```

- [ ] **Step 4: Write the models**

```ruby
# app/models/aypex_bank_transfer/incoming_transfer.rb
module AypexBankTransfer
  class IncomingTransfer < Base
    STATES = %w[unmatched applied ignored].freeze

    # Crockford base32 decoding folds these ambiguous glyphs. Applied to both
    # sides of a comparison, so a customer typing O for 0 still matches.
    AMBIGUOUS = { 'O' => '0', 'I' => '1', 'L' => '1' }.freeze

    belongs_to :payment_session, class_name: 'Spree::PaymentSession', optional: true
    belongs_to :applied_by, class_name: Spree.admin_user_class.to_s, optional: true

    validates :provider, :provider_transaction_id, :amount, :currency, :occurred_at, presence: true
    validates :provider_transaction_id, uniqueness: { scope: :provider }
    validates :state, inclusion: { in: STATES }

    scope :unmatched, -> { where(state: 'unmatched') }
    scope :applied,   -> { where(state: 'applied') }

    before_validation :normalize_stored_reference

    def self.normalize_reference(value)
      value.to_s.upcase.gsub(/[^A-Z0-9]/, '').gsub(/[OIL]/, AMBIGUOUS)
    end

    STATES.each do |state_name|
      define_method("#{state_name}?") { state == state_name }
    end

    def money
      Spree::Money.new(amount, currency: currency)
    end

    private

    def normalize_stored_reference
      self.reference_normalized = self.class.normalize_reference(reference_raw)
    end
  end
end
```

```ruby
# app/models/aypex_bank_transfer/reconciler_state.rb
module AypexBankTransfer
  class ReconcilerState < Base
    belongs_to :payment_method, class_name: 'Spree::PaymentMethod'

    validates :payment_method_id, uniqueness: true

    # Healthy when we have polled successfully within three poll intervals.
    # A nil last_successful_run_at is unhealthy by design: we have never
    # confirmed we can see the bank, so we must not cancel anything.
    def healthy?(poll_interval_minutes)
      return false if last_successful_run_at.nil?

      last_successful_run_at > (poll_interval_minutes.to_i * 3).minutes.ago
    end

    def record_success!
      update!(last_successful_run_at: Time.current, last_error: nil, consecutive_failures: 0)
    end

    def record_failure!(error)
      update!(last_error: error.to_s.truncate(1000), consecutive_failures: consecutive_failures + 1)
    end
  end
end
```

- [ ] **Step 5: Add the factory**

```ruby
# lib/aypex_bank_transfer/factories.rb
FactoryBot.define do
  factory :bank_transfer_incoming_transfer, class: 'AypexBankTransfer::IncomingTransfer' do
    provider { 'test' }
    sequence(:provider_transaction_id) { |n| "TX-#{n}" }
    amount { 25.00 }
    currency { 'GBP' }
    reference_raw { 'TKF-7Q4X2' }
    payer_name { 'Jane Doe' }
    occurred_at { Time.current }
    state { 'unmatched' }
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/incoming_transfer_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add db app lib spec
git commit -m "feat: add IncomingTransfer and ReconcilerState models"
```

---

### Task 3: Gateway payment method and preferences

**Files:**
- Create: `app/models/aypex_bank_transfer/gateway.rb`
- Modify: `lib/aypex_bank_transfer/factories.rb`
- Test: `spec/models/aypex_bank_transfer/gateway_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::ReconcilerState` (Task 2)
- Produces: `AypexBankTransfer::Gateway` with preferences `reconciler`, `reference_prefix`, `expiry_days`, `discount_percent`, `poll_interval_minutes`, `account_name`, `account_iban`, `account_bic`, `account_sort_code`, `account_number`; plus `#reconciler_state → ReconcilerState`, `#bank_details → Hash`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/aypex_bank_transfer/gateway_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::Gateway do
  let(:gateway) { create(:bank_transfer_gateway) }

  it 'does not require a payment source' do
    expect(gateway.source_required?).to be(false)
    expect(gateway.payment_source_class).to be_nil
  end

  it 'defaults to a three day expiry window' do
    expect(gateway.preferred_expiry_days).to eq(3)
  end

  it 'rejects a discount percent outside 0..100' do
    gateway.preferred_discount_percent = 150
    expect(gateway).not_to be_valid
  end

  it 'lazily creates its reconciler state' do
    expect { gateway.reconciler_state }.to change(AypexBankTransfer::ReconcilerState, :count).by(1)
  end

  it 'exposes bank details for display' do
    expect(gateway.bank_details).to include(account_name: 'Aypex Ltd', iban: 'GB00TEST00000000000000')
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/gateway_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::Gateway`

- [ ] **Step 3: Write the gateway**

```ruby
# app/models/aypex_bank_transfer/gateway.rb
module AypexBankTransfer
  class Gateway < ::Spree::PaymentMethod
    preference :reconciler, :string, default: 'manual'
    preference :reference_prefix, :string, default: ''
    preference :expiry_days, :integer, default: 3
    preference :discount_percent, :decimal, default: 0
    preference :poll_interval_minutes, :integer, default: 15

    preference :account_name, :string
    preference :account_iban, :string
    preference :account_bic, :string
    preference :account_sort_code, :string
    preference :account_number, :string

    validate :discount_percent_within_bounds
    validate :expiry_days_positive

    def payment_source_class
      nil
    end

    def source_required?
      false
    end

    def payment_session_class
      ::Spree::PaymentSessions::BankTransfer
    end

    def auto_capture?
      false
    end

    # Money moves when the reconciler confirms it, never on an admin's click
    # in the payments screen. Void remains available for abandoning an order.
    def actions
      %w[void]
    end

    def can_void?(payment)
      payment.state != 'void'
    end

    def void(*)
      ::Spree::PaymentResponse.new(true, '', {}, {})
    end

    def cancel(*)
      ::Spree::PaymentResponse.new(true, '', {}, {})
    end

    def description_partial_name
      'aypex_bank_transfer'
    end

    def configuration_guide_partial_name
      'aypex_bank_transfer'
    end

    def reconciler_state
      AypexBankTransfer::ReconcilerState.find_or_create_by!(payment_method_id: id)
    end

    def bank_details
      {
        account_name: preferred_account_name,
        iban: preferred_account_iban,
        bic: preferred_account_bic,
        sort_code: preferred_account_sort_code,
        account_number: preferred_account_number
      }
    end

    private

    def discount_percent_within_bounds
      percent = preferred_discount_percent.to_d
      return if percent >= 0 && percent <= 100

      errors.add(:preferred_discount_percent, :inclusion)
    end

    def expiry_days_positive
      return if preferred_expiry_days.to_i.positive?

      errors.add(:preferred_expiry_days, :greater_than, count: 0)
    end
  end
end
```

- [ ] **Step 4: Add the factory**

Append to `lib/aypex_bank_transfer/factories.rb` inside the existing `FactoryBot.define` block:

```ruby
  factory :bank_transfer_gateway, class: 'AypexBankTransfer::Gateway' do
    name { 'Bank Transfer' }
    preferences do
      {
        reconciler: 'manual',
        reference_prefix: 'TKF-',
        expiry_days: 3,
        discount_percent: 3,
        poll_interval_minutes: 15,
        account_name: 'Aypex Ltd',
        account_iban: 'GB00TEST00000000000000',
        account_bic: 'REVOGB21'
      }
    end
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/gateway_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app lib spec
git commit -m "feat: add bank transfer payment method with preferences"
```

---

### Task 4: Payment session and reference generation

**Files:**
- Create: `app/models/spree/payment_sessions/bank_transfer.rb`
- Create: `app/services/aypex_bank_transfer/reference_generator.rb`
- Modify: `app/models/aypex_bank_transfer/gateway.rb` (add `create_payment_session`)
- Modify: `lib/aypex_bank_transfer/factories.rb`
- Test: `spec/services/aypex_bank_transfer/reference_generator_spec.rb`, `spec/models/spree/payment_sessions/bank_transfer_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::Gateway` (Task 3), `AypexBankTransfer::IncomingTransfer.normalize_reference` (Task 2)
- Produces:
  - `AypexBankTransfer::ReferenceGenerator.new(payment_method:).generate → String`
  - `Spree::PaymentSessions::BankTransfer` with `#external_id_normalized`, `#reference`, `#notification_payload → Hash`, scope `.open`
  - `AypexBankTransfer::Gateway#create_payment_session(order:, amount: nil, external_data: {}) → Spree::PaymentSessions::BankTransfer`

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/services/aypex_bank_transfer/reference_generator_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::ReferenceGenerator do
  let(:payment_method) { create(:bank_transfer_gateway) }

  subject(:generator) { described_class.new(payment_method: payment_method) }

  it 'prefixes the configured store prefix' do
    expect(generator.generate).to start_with('TKF-')
  end

  it 'emits six characters from the Crockford alphabet' do
    code = generator.generate.delete_prefix('TKF-')

    expect(code.length).to eq(6)
    expect(code).to match(/\A[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{6}\z/)
  end

  it 'never returns a reference already used by this payment method' do
    create(:bank_transfer_payment_session, payment_method: payment_method, external_id: 'TKF-AAAAAA')
    allow(generator).to receive(:random_code).and_return('AAAAAA', 'ZZZZZZ')

    expect(generator.generate).to eq('TKF-ZZZZZZ')
  end

  it 'raises when it cannot find a free reference' do
    allow(generator).to receive(:random_code).and_return('AAAAAA')
    create(:bank_transfer_payment_session, payment_method: payment_method, external_id: 'TKF-AAAAAA')

    expect { generator.generate }.to raise_error(described_class::ExhaustedError)
  end
end
```

```ruby
# spec/models/spree/payment_sessions/bank_transfer_spec.rb
require 'spec_helper'

RSpec.describe Spree::PaymentSessions::BankTransfer do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it 'stores a normalized copy of the reference on save' do
    session = create(:bank_transfer_payment_session,
                     payment_method: payment_method, external_id: 'TKF-7Q4X2')

    expect(session.external_id_normalized).to eq('TKF7Q4X2')
  end

  it 'includes pending and processing sessions in the open scope' do
    open_session = create(:bank_transfer_payment_session, payment_method: payment_method)
    closed_session = create(:bank_transfer_payment_session, payment_method: payment_method)
    closed_session.complete!

    expect(described_class.open).to include(open_session)
    expect(described_class.open).not_to include(closed_session)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/reference_generator_spec.rb spec/models/spree/payment_sessions/bank_transfer_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::ReferenceGenerator`

- [ ] **Step 3: Write the payment session**

```ruby
# app/models/spree/payment_sessions/bank_transfer.rb
module Spree
  module PaymentSessions
    class BankTransfer < Spree::PaymentSession
      before_validation :normalize_external_id

      scope :open, -> { where(status: %w[pending processing]) }

      def expired?
        expires_at.present? && expires_at <= Time.current
      end

      def reference
        external_id
      end

      # Event subscribers may run async via ActiveJob, so payloads must be
      # serializable primitives — never AR objects.
      def notification_payload
        {
          payment_session_id: id,
          order_number: order&.number,
          order_email: order&.email,
          reference: reference,
          amount: amount.to_s,
          currency: currency,
          expires_at: expires_at&.iso8601
        }
      end

      private

      def normalize_external_id
        self.external_id_normalized =
          AypexBankTransfer::IncomingTransfer.normalize_reference(external_id)
      end
    end
  end
end
```

- [ ] **Step 4: Write the reference generator**

```ruby
# app/services/aypex_bank_transfer/reference_generator.rb
module AypexBankTransfer
  class ReferenceGenerator
    # Crockford base32: excludes I, L, O and U so handwritten and mistyped
    # references stay unambiguous.
    ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'.freeze
    LENGTH = 6
    MAX_ATTEMPTS = 10

    class ExhaustedError < StandardError; end

    def initialize(payment_method:)
      @payment_method = payment_method
    end

    def generate
      MAX_ATTEMPTS.times do
        candidate = "#{@payment_method.preferred_reference_prefix}#{random_code}"
        return candidate unless taken?(candidate)
      end

      raise ExhaustedError,
            "could not generate a unique reference after #{MAX_ATTEMPTS} attempts"
    end

    private

    def random_code
      Array.new(LENGTH) { ALPHABET[SecureRandom.random_number(ALPHABET.length)] }.join
    end

    def taken?(candidate)
      normalized = IncomingTransfer.normalize_reference(candidate)

      ::Spree::PaymentSessions::BankTransfer.
        where(payment_method_id: @payment_method.id, external_id_normalized: normalized).
        exists?
    end
  end
end
```

- [ ] **Step 5: Add `create_payment_session` to the gateway**

Add to `app/models/aypex_bank_transfer/gateway.rb`, after `#payment_session_class`:

```ruby
    def create_payment_session(order:, amount: nil, external_data: {})
      ::Spree::PaymentSessions::BankTransfer.create!(
        order: order,
        payment_method: self,
        amount: amount || order.total_minus_store_credits,
        currency: order.currency,
        external_id: ReferenceGenerator.new(payment_method: self).generate,
        external_data: external_data,
        expires_at: preferred_expiry_days.to_i.days.from_now
      )
    end
```

- [ ] **Step 6: Add the factory**

Append inside the `FactoryBot.define` block:

```ruby
  factory :bank_transfer_payment_session, class: 'Spree::PaymentSessions::BankTransfer' do
    association :order, factory: :order
    association :payment_method, factory: :bank_transfer_gateway
    amount { 25.00 }
    currency { 'GBP' }
    status { 'pending' }
    sequence(:external_id) { |n| "TKF-TEST#{n.to_s.rjust(2, '0')}" }
    expires_at { 3.days.from_now }
  end
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/reference_generator_spec.rb spec/models/spree/payment_sessions/bank_transfer_spec.rb`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add app lib spec
git commit -m "feat: add bank transfer payment session and reference generation"
```

---

### Task 5: Reconciler contract, Manual reconciler, and shared examples

**Files:**
- Create: `app/models/aypex_bank_transfer/transfer_data.rb`
- Create: `app/models/aypex_bank_transfer/reconcilers/base.rb`
- Create: `app/models/aypex_bank_transfer/reconcilers/manual.rb`
- Create: `lib/aypex_bank_transfer/testing_support/reconciler_shared_examples.rb`
- Modify: `app/models/aypex_bank_transfer/gateway.rb` (add `#reconciler`)
- Test: `spec/models/aypex_bank_transfer/reconcilers/manual_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::Gateway` (Task 3)
- Produces:
  - `AypexBankTransfer::TransferData` — `Data` type with members `provider`, `provider_transaction_id`, `amount`, `currency`, `reference`, `payer_name`, `occurred_at`, `raw`
  - `AypexBankTransfer::Reconcilers::Base` — `#poll(since:)`, `#parse_webhook(raw_body, headers)`, `#healthy?`, `#configured?`, and `.register(key, klass)` / `.build(payment_method:)`
  - `AypexBankTransfer::Gateway#reconciler → Reconcilers::Base`
  - Shared example group `'a bank transfer reconciler'`

**This is the published cross-gem contract.** Changing any signature here requires a coordinated release of `aypex_bank_transfer_revolut`.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/aypex_bank_transfer/reconcilers/manual_spec.rb
require 'spec_helper'
require 'aypex_bank_transfer/testing_support/reconciler_shared_examples'

RSpec.describe AypexBankTransfer::Reconcilers::Manual do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it_behaves_like 'a bank transfer reconciler'

  it 'is always healthy because it never polls' do
    expect(described_class.new(payment_method: payment_method)).to be_healthy
  end

  it 'returns no transfers when polled' do
    expect(described_class.new(payment_method: payment_method).poll(since: 1.day.ago)).to eq([])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/reconcilers/manual_spec.rb`
Expected: FAIL with `cannot load such file -- aypex_bank_transfer/testing_support/reconciler_shared_examples`

- [ ] **Step 3: Write the value object**

```ruby
# app/models/aypex_bank_transfer/transfer_data.rb
module AypexBankTransfer
  # The single value object crossing the reconciler boundary. Both ingress
  # paths — webhook and poll — return this, so matching is written once and
  # the two paths cannot drift apart.
  TransferData = Data.define(
    :provider,
    :provider_transaction_id,
    :amount,
    :currency,
    :reference,
    :payer_name,
    :occurred_at,
    :raw
  ) do
    def initialize(payer_name: nil, reference: nil, raw: {}, **rest)
      super(payer_name: payer_name, reference: reference, raw: raw, **rest)
    end
  end
end
```

- [ ] **Step 4: Write the contract and the Manual reconciler**

```ruby
# app/models/aypex_bank_transfer/reconcilers/base.rb
module AypexBankTransfer
  module Reconcilers
    class Base
      class NotConfiguredError < StandardError; end

      class << self
        def registry
          @registry ||= {}
        end

        def register(key, klass)
          registry[key.to_s] = klass
        end

        def build(payment_method:)
          key = payment_method.preferred_reconciler.to_s
          klass = registry.fetch(key) do
            raise ArgumentError, "unknown reconciler #{key.inspect}"
          end

          klass.new(payment_method: payment_method)
        end
      end

      attr_reader :payment_method

      def initialize(payment_method:)
        @payment_method = payment_method
      end

      # @param since [Time]
      # @return [Array<AypexBankTransfer::TransferData>]
      def poll(since:)
        raise NotImplementedError, "#{self.class} must implement #poll"
      end

      # @return [AypexBankTransfer::TransferData, nil] nil for unsupported events
      # @raise [Spree::PaymentMethod::WebhookSignatureError]
      def parse_webhook(raw_body, headers)
        raise NotImplementedError, "#{self.class} must implement #parse_webhook"
      end

      # @return [Boolean] false means the expiry job must not cancel anything
      def healthy?
        raise NotImplementedError, "#{self.class} must implement #healthy?"
      end

      # @return [Boolean] whether credentials and settings are complete
      def configured?
        raise NotImplementedError, "#{self.class} must implement #configured?"
      end
    end
  end
end
```

```ruby
# app/models/aypex_bank_transfer/reconcilers/manual.rb
module AypexBankTransfer
  module Reconcilers
    # The default. An admin applies payments by hand from the transfers queue,
    # so there is nothing to poll and nothing that can become unhealthy.
    class Manual < Base
      def poll(since:)
        []
      end

      def parse_webhook(_raw_body, _headers)
        nil
      end

      def healthy?
        true
      end

      def configured?
        true
      end
    end
  end
end
```

- [ ] **Step 5: Write the shared example group**

```ruby
# lib/aypex_bank_transfer/testing_support/reconciler_shared_examples.rb
RSpec.shared_examples 'a bank transfer reconciler' do
  subject(:reconciler) { described_class.new(payment_method: payment_method) }

  it 'inherits the published contract' do
    expect(described_class.ancestors).to include(AypexBankTransfer::Reconcilers::Base)
  end

  it 'accepts a payment_method keyword' do
    expect(reconciler.payment_method).to eq(payment_method)
  end

  it 'returns an array of TransferData from #poll' do
    result = reconciler.poll(since: 1.day.ago)

    expect(result).to be_an(Array)
    expect(result).to all(be_a(AypexBankTransfer::TransferData))
  end

  it 'returns TransferData or nil from #parse_webhook' do
    result = reconciler.parse_webhook('{}', {})

    expect(result).to be_nil.or be_a(AypexBankTransfer::TransferData)
  end

  it 'answers #healthy? with a boolean' do
    expect([true, false]).to include(reconciler.healthy?)
  end

  it 'answers #configured? with a boolean' do
    expect([true, false]).to include(reconciler.configured?)
  end
end
```

- [ ] **Step 6: Register Manual and expose `#reconciler`**

Add to `config/initializers/spree.rb` inside the existing `after_initialize` block:

```ruby
  AypexBankTransfer::Reconcilers::Base.register('manual', AypexBankTransfer::Reconcilers::Manual)
```

Add to `app/models/aypex_bank_transfer/gateway.rb`, after `#reconciler_state`:

```ruby
    def reconciler
      @reconciler ||= Reconcilers::Base.build(payment_method: self)
    end
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/reconcilers/manual_spec.rb`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add app lib config spec
git commit -m "feat: add reconciler contract, manual reconciler, and shared examples"
```

---

### Task 6: IngestTransfer — matching and auto-apply

**Files:**
- Create: `app/services/aypex_bank_transfer/ingest_transfer.rb`
- Test: `spec/services/aypex_bank_transfer/ingest_transfer_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::TransferData` (Task 5), `AypexBankTransfer::IncomingTransfer` (Task 2), `Spree::PaymentSessions::BankTransfer` (Task 4)
- Produces: `AypexBankTransfer::IngestTransfer.new(payment_method:, transfer_data:).call → IncomingTransfer`

**This task carries the "auto-apply demands certainty" rule.** Every negative test below is a guard against silently misapplying money.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/services/aypex_bank_transfer/ingest_transfer_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::IngestTransfer do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:order_with_line_items, currency: 'GBP') }
  let!(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method,
           external_id: 'TKF-7Q4X2', amount: 25.00, currency: 'GBP')
  end

  def transfer_data(overrides = {})
    AypexBankTransfer::TransferData.new(
      **{
        provider: 'test',
        provider_transaction_id: 'TX-1',
        amount: 25.00,
        currency: 'GBP',
        reference: 'TKF-7Q4X2',
        payer_name: 'Jane Doe',
        occurred_at: Time.current,
        raw: {}
      }.merge(overrides)
    )
  end

  def ingest(overrides = {})
    described_class.new(payment_method: payment_method, transfer_data: transfer_data(overrides)).call
  end

  describe 'exact match' do
    it 'applies the payment and completes the session' do
      transfer = ingest

      expect(transfer).to be_applied
      expect(transfer.payment_session).to eq(session)
      expect(session.reload.status).to eq('completed')
      expect(order.reload.payment_state).to eq('paid')
    end

    it 'matches despite casing, spacing and punctuation' do
      expect(ingest(reference: ' tkf/7q4x2 ')).to be_applied
    end

    it 'matches despite Crockford-ambiguous glyphs' do
      # The session reference contains digits 0 and 1; the customer typed the
      # letters O and I. Folding both sides makes them the same reference.
      session.update!(external_id: 'TKF-01ABCD')

      expect(ingest(reference: 'TKF-OIABCD', provider_transaction_id: 'TX-9')).to be_applied
    end
  end

  describe 'idempotency' do
    it 'is a no-op when the same provider transaction arrives twice' do
      ingest
      expect { ingest }.not_to change(Spree::Payment, :count)
      expect(AypexBankTransfer::IncomingTransfer.count).to eq(1)
    end
  end

  describe 'refuses to auto-apply' do
    it 'on underpayment' do
      expect(ingest(amount: 20.00, provider_transaction_id: 'TX-2')).to be_unmatched
    end

    it 'on overpayment' do
      expect(ingest(amount: 30.00, provider_transaction_id: 'TX-3')).to be_unmatched
    end

    it 'on currency mismatch' do
      expect(ingest(currency: 'EUR', provider_transaction_id: 'TX-4')).to be_unmatched
    end

    it 'when the reference matches nothing' do
      expect(ingest(reference: 'TKF-NOPE1', provider_transaction_id: 'TX-5')).to be_unmatched
    end

    it 'when the reference is blank' do
      expect(ingest(reference: nil, provider_transaction_id: 'TX-6')).to be_unmatched
    end

    it 'when the session is already expired' do
      session.expire!
      expect(ingest(provider_transaction_id: 'TX-7')).to be_unmatched
    end

    it 'when the session is already canceled' do
      session.cancel!
      expect(ingest(provider_transaction_id: 'TX-8')).to be_unmatched
    end
  end

  describe 'failure during application' do
    it 'leaves the transfer re-processable rather than half applied' do
      allow_any_instance_of(Spree::Payment).to receive(:complete!).and_raise(StandardError, 'boom')

      expect { ingest }.to raise_error(StandardError, 'boom')
      expect(AypexBankTransfer::IncomingTransfer.last).to be_unmatched
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/ingest_transfer_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::IngestTransfer`

- [ ] **Step 3: Write the service**

```ruby
# app/services/aypex_bank_transfer/ingest_transfer.rb
module AypexBankTransfer
  class IngestTransfer
    def initialize(payment_method:, transfer_data:)
      @payment_method = payment_method
      @data = transfer_data
    end

    def call
      transfer = find_or_create_transfer

      # Webhook and poll both delivering the same transfer is the expected
      # case, not an error. The unique index makes replay a no-op.
      return transfer if transfer.applied?

      session = matching_session(transfer)
      session ? apply!(transfer, session) : transfer

      transfer
    end

    private

    attr_reader :payment_method, :data

    def find_or_create_transfer
      IncomingTransfer.create_with(
        amount: data.amount,
        currency: data.currency,
        reference_raw: data.reference,
        payer_name: data.payer_name,
        occurred_at: data.occurred_at,
        raw_payload: data.raw || {},
        state: 'unmatched'
      ).find_or_create_by!(
        provider: data.provider,
        provider_transaction_id: data.provider_transaction_id
      )
    end

    # Auto-apply demands certainty: exact reference, exact amount, exact
    # currency, against exactly one still-open session. Anything else queues.
    def matching_session(transfer)
      return nil if transfer.reference_normalized.blank?

      candidates = ::Spree::PaymentSessions::BankTransfer.open.where(
        payment_method_id: payment_method.id,
        external_id_normalized: transfer.reference_normalized
      )

      return nil unless candidates.count == 1

      session = candidates.first
      return nil unless session.amount == transfer.amount
      return nil unless session.currency == transfer.currency

      session
    end

    def apply!(transfer, session)
      ActiveRecord::Base.transaction do
        payment = session.find_or_create_payment!
        session.complete! unless session.completed?
        payment.complete! unless payment.completed?

        transfer.update!(state: 'applied', payment_session: session)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/ingest_transfer_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app spec
git commit -m "feat: add transfer ingestion with strict auto-apply matching"
```

---

### Task 7: Match suggestions for the unmatched queue

**Files:**
- Create: `app/services/aypex_bank_transfer/suggest_matches.rb`
- Create: `db/migrate/20260815000003_enable_pg_trgm.rb`
- Modify: `lib/aypex_bank_transfer.rb` (add `pg_trgm_available?`)
- Test: `spec/services/aypex_bank_transfer/suggest_matches_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::IncomingTransfer` (Task 2), `Spree::PaymentSessions::BankTransfer` (Task 4)
- Produces: `AypexBankTransfer::SuggestMatches.new(transfer:).call → Array<Spree::PaymentSessions::BankTransfer>` (at most 5, best first); `AypexBankTransfer.pg_trgm_available? → Boolean`

**Suggestions never auto-apply.** This service is read-only and exists purely to rank candidates for a human.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/services/aypex_bank_transfer/suggest_matches_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::SuggestMatches do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:transfer) do
    create(:bank_transfer_incoming_transfer,
           amount: 25.00, currency: 'GBP', reference_raw: 'GARBAGE', payer_name: 'Jane Doe')
  end

  it 'ranks an exact amount and currency match first' do
    match = create(:bank_transfer_payment_session,
                   payment_method: payment_method, amount: 25.00, currency: 'GBP')
    create(:bank_transfer_payment_session,
           payment_method: payment_method, amount: 99.00, currency: 'GBP')

    expect(described_class.new(transfer: transfer).call.first).to eq(match)
  end

  it 'excludes sessions that are no longer open' do
    closed = create(:bank_transfer_payment_session,
                    payment_method: payment_method, amount: 25.00, currency: 'GBP')
    closed.complete!

    expect(described_class.new(transfer: transfer).call).not_to include(closed)
  end

  it 'returns at most five suggestions' do
    7.times { create(:bank_transfer_payment_session, payment_method: payment_method, amount: 25.00, currency: 'GBP') }

    expect(described_class.new(transfer: transfer).call.length).to eq(5)
  end

  it 'degrades to amount matching when pg_trgm is unavailable' do
    allow(AypexBankTransfer).to receive(:pg_trgm_available?).and_return(false)
    match = create(:bank_transfer_payment_session,
                   payment_method: payment_method, amount: 25.00, currency: 'GBP')

    expect(described_class.new(transfer: transfer).call).to include(match)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/suggest_matches_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::SuggestMatches`

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260815000003_enable_pg_trgm.rb
class EnablePgTrgm < ActiveRecord::Migration[8.1]
  def up
    enable_extension 'pg_trgm'
  rescue ActiveRecord::StatementInvalid => e
    # Suggestions degrade to amount-only matching rather than blocking install
    # on databases where the role cannot create extensions.
    say "Could not enable pg_trgm (#{e.message}); payer name suggestions disabled"
  end

  def down
    disable_extension 'pg_trgm'
  rescue ActiveRecord::StatementInvalid
    nil
  end
end
```

- [ ] **Step 4: Add the availability check**

Append to `lib/aypex_bank_transfer.rb`:

```ruby
module AypexBankTransfer
  def self.pg_trgm_available?
    return @pg_trgm_available if defined?(@pg_trgm_available)

    @pg_trgm_available = ActiveRecord::Base.connection.extension_enabled?('pg_trgm')
  rescue StandardError
    @pg_trgm_available = false
  end
end
```

- [ ] **Step 5: Write the service**

```ruby
# app/services/aypex_bank_transfer/suggest_matches.rb
module AypexBankTransfer
  # Ranks candidate sessions for an unmatched transfer so an admin can decide.
  # Never applies anything.
  class SuggestMatches
    LIMIT = 5
    NAME_SIMILARITY_THRESHOLD = 0.3

    def initialize(transfer:)
      @transfer = transfer
    end

    def call
      exact = amount_matches.limit(LIMIT).to_a
      return exact if exact.length >= LIMIT

      (exact + name_matches(exclude: exact)).uniq.first(LIMIT)
    end

    private

    attr_reader :transfer

    def open_sessions
      ::Spree::PaymentSessions::BankTransfer.open
    end

    def amount_matches
      open_sessions.where(amount: transfer.amount, currency: transfer.currency).
        order(created_at: :desc)
    end

    def name_matches(exclude:)
      return [] unless AypexBankTransfer.pg_trgm_available?
      return [] if transfer.payer_name.blank?

      open_sessions.
        where.not(id: exclude.map(&:id)).
        joins(order: :bill_address).
        where(
          "similarity(concat_ws(' ', spree_addresses.firstname, spree_addresses.lastname), ?) > ?",
          transfer.payer_name, NAME_SIMILARITY_THRESHOLD
        ).
        order(
          Arel.sql(
            ActiveRecord::Base.sanitize_sql_array([
              "similarity(concat_ws(' ', spree_addresses.firstname, spree_addresses.lastname), ?) DESC",
              transfer.payer_name
            ])
          )
        ).
        limit(LIMIT).to_a
    end
  end
end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/suggest_matches_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app db lib spec
git commit -m "feat: add ranked match suggestions for unmatched transfers"
```

---

### Task 8: Health gate and expiry job

**Files:**
- Create: `app/jobs/aypex_bank_transfer/expire_sessions_job.rb`
- Modify: `app/models/aypex_bank_transfer/gateway.rb` (add `#reconciler_healthy?`)
- Test: `spec/jobs/aypex_bank_transfer/expire_sessions_job_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::Gateway#reconciler` (Task 5), `ReconcilerState#healthy?` (Task 2), `Spree::PaymentSessions::BankTransfer.open` (Task 4)
- Produces: `AypexBankTransfer::ExpireSessionsJob.perform_now`

**The most important test in the suite lives here.** If the health gate regresses, paying customers lose orders silently.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/jobs/aypex_bank_transfer/expire_sessions_job_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::ExpireSessionsJob do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let!(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method, expires_at: 1.hour.ago)
  end

  context 'when the reconciler is healthy' do
    before { allow_any_instance_of(AypexBankTransfer::Gateway).to receive(:reconciler_healthy?).and_return(true) }

    it 'expires the session and cancels the order' do
      described_class.perform_now

      expect(session.reload.status).to eq('expired')
      expect(order.reload.state).to eq('canceled')
    end

    it 'leaves sessions that have not yet expired alone' do
      session.update!(expires_at: 1.day.from_now)

      described_class.perform_now

      expect(session.reload.status).to eq('pending')
      expect(order.reload.state).not_to eq('canceled')
    end
  end

  context 'when the reconciler is unhealthy' do
    before { allow_any_instance_of(AypexBankTransfer::Gateway).to receive(:reconciler_healthy?).and_return(false) }

    # THE critical test. A blind reconciler must never cancel: the customer
    # may well have paid and we simply cannot see it.
    it 'cancels nothing' do
      described_class.perform_now

      expect(session.reload.status).to eq('pending')
      expect(order.reload.state).not_to eq('canceled')
    end

    it 'publishes an unhealthy event instead' do
      expect(Spree::Events).to receive(:publish).with(
        'bank_transfer.reconciler_unhealthy',
        hash_including(payment_method_id: payment_method.id)
      )

      described_class.perform_now
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/jobs/aypex_bank_transfer/expire_sessions_job_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::ExpireSessionsJob`

- [ ] **Step 3: Add the gateway health check**

Add to `app/models/aypex_bank_transfer/gateway.rb`, after `#reconciler`:

```ruby
    # Gate on both the reconciler's own opinion and our recorded poll history.
    # The Manual reconciler is always healthy because it never polls.
    def reconciler_healthy?
      return false unless reconciler.healthy?
      return true if reconciler.is_a?(Reconcilers::Manual)

      reconciler_state.healthy?(preferred_poll_interval_minutes)
    end
```

- [ ] **Step 4: Write the job**

```ruby
# app/jobs/aypex_bank_transfer/expire_sessions_job.rb
module AypexBankTransfer
  class ExpireSessionsJob < ActiveJob::Base
    queue_as :default

    def perform
      AypexBankTransfer::Gateway.find_each do |payment_method|
        unless payment_method.reconciler_healthy?
          # Never cancel while blind: the customer may have paid and we simply
          # cannot see it. Alert and leave everything untouched.
          Spree::Events.publish(
            'bank_transfer.reconciler_unhealthy',
            {
              payment_method_id: payment_method.id,
              reconciler: payment_method.preferred_reconciler,
              last_successful_run_at: payment_method.reconciler_state.last_successful_run_at&.iso8601,
              last_error: payment_method.reconciler_state.last_error
            }
          )
          next
        end

        expire_for(payment_method)
      end
    end

    private

    def expire_for(payment_method)
      ::Spree::PaymentSessions::BankTransfer.
        open.
        where(payment_method_id: payment_method.id).
        where(expires_at: ...Time.current).
        find_each do |session|
          ActiveRecord::Base.transaction do
            session.expire!
            cancel_order(session.order)
          end

          Spree::Events.publish('bank_transfer.expired', session.notification_payload)
        end
    end

    def cancel_order(order)
      return if order.blank? || order.canceled?

      order.cancel!
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/jobs/aypex_bank_transfer/expire_sessions_job_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app spec
git commit -m "feat: add expiry job gated on reconciler health"
```

---

### Task 9: Discount adjustment

**Files:**
- Create: `app/services/aypex_bank_transfer/apply_discount.rb`
- Create: `app/models/aypex_bank_transfer/payment_decorator.rb`
- Create: `config/locales/en.yml`
- Test: `spec/services/aypex_bank_transfer/apply_discount_spec.rb`

**Interfaces:**
- Consumes: `AypexBankTransfer::Gateway` (Task 3)
- Produces: `AypexBankTransfer::ApplyDiscount.call(order:, payment_method:) → void`

**Constraint reminder: the discount base is `order.item_total`, never `order.total`.**

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/services/aypex_bank_transfer/apply_discount_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::ApplyDiscount do
  let(:payment_method) { create(:bank_transfer_gateway) } # 3% in the factory
  let(:card_method) { create(:credit_card_payment_method) }
  let(:order) { create(:order_with_line_items, item_total: 100.00) }

  it 'discounts a percentage of item_total, not order total' do
    described_class.call(order: order, payment_method: payment_method)

    adjustment = order.adjustments.reload.find_by(source: payment_method)
    expect(adjustment.amount).to eq(-3.00)
  end

  it 'removes the discount when the customer switches to another method' do
    described_class.call(order: order, payment_method: payment_method)
    described_class.call(order: order, payment_method: card_method)

    expect(order.adjustments.reload.where(source: payment_method)).to be_empty
  end

  it 'creates no adjustment when the discount is zero' do
    payment_method.update!(preferred_discount_percent: 0)

    described_class.call(order: order, payment_method: payment_method)

    expect(order.adjustments.reload.where(source: payment_method)).to be_empty
  end

  it 'does not stack when applied twice' do
    2.times { described_class.call(order: order, payment_method: payment_method) }

    expect(order.adjustments.reload.where(source: payment_method).count).to eq(1)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/apply_discount_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::ApplyDiscount`

- [ ] **Step 3: Write the service**

```ruby
# app/services/aypex_bank_transfer/apply_discount.rb
module AypexBankTransfer
  class ApplyDiscount
    def self.call(order:, payment_method:)
      new(order: order, payment_method: payment_method).call
    end

    def initialize(order:, payment_method:)
      @order = order
      @payment_method = payment_method
    end

    def call
      remove_existing
      return unless bank_transfer?
      return if percent.zero?

      order.adjustments.create!(
        adjustable: order,
        order: order,
        source: payment_method,
        amount: discount_amount,
        label: label,
        eligible: true,
        included: false
      )

      order.update_with_updater!
    end

    private

    attr_reader :order, :payment_method

    def bank_transfer?
      payment_method.is_a?(AypexBankTransfer::Gateway)
    end

    def percent
      return 0.to_d unless bank_transfer?

      payment_method.preferred_discount_percent.to_d
    end

    # Always item_total. order.total is gross, rolls in shipping and tax, and
    # mishandles VAT on tax-inclusive stores.
    def discount_amount
      -(order.item_total * percent / 100).round(2)
    end

    def label
      Spree.t('bank_transfer.discount_label', percent: percent.to_i)
    end

    def remove_existing
      existing = order.adjustments.where(source_type: 'Spree::PaymentMethod').
                 joins("INNER JOIN spree_payment_methods ON spree_payment_methods.id = spree_adjustments.source_id").
                 where(spree_payment_methods: { type: 'AypexBankTransfer::Gateway' })

      return if existing.empty?

      existing.destroy_all
      order.update_with_updater!
    end
  end
end
```

- [ ] **Step 4: Hook it to payment creation**

```ruby
# app/models/aypex_bank_transfer/payment_decorator.rb
module AypexBankTransfer
  module PaymentDecorator
    def self.prepended(base)
      base.after_create :sync_bank_transfer_discount
    end

    private

    # Called for every payment, not just bank transfer ones, so switching away
    # from bank transfer removes the discount rather than leaving it behind.
    def sync_bank_transfer_discount
      return if order.blank?

      AypexBankTransfer::ApplyDiscount.call(order: order, payment_method: payment_method)
    end
  end
end

Spree::Payment.prepend(AypexBankTransfer::PaymentDecorator) unless
  Spree::Payment.included_modules.include?(AypexBankTransfer::PaymentDecorator)
```

- [ ] **Step 5: Add the locale file**

```yaml
# config/locales/en.yml
en:
  spree:
    bank_transfer:
      discount_label: "Bank Transfer discount (%{percent}%)"
      payment_method_label: "Bank Transfer — save %{percent}%"
      pay_within: "Please transfer within %{days} days"
      dispatch_note: "Your order is dispatched once funds clear."
      reference: "Payment reference"
      reference_help: "Please quote this reference exactly, or we may not be able to match your payment."
      amount_to_transfer: "Amount to transfer"
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/aypex_bank_transfer/apply_discount_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app config spec
git commit -m "feat: add bank transfer discount adjustment on item_total"
```

---

### Task 10: Notification events and default mailer

**Files:**
- Modify: `config/initializers/spree.rb` (register events)
- Create: `app/mailers/aypex_bank_transfer/instructions_mailer.rb`
- Create: `app/views/aypex_bank_transfer/instructions_mailer/instructions.html.erb`
- Create: `app/views/aypex_bank_transfer/instructions_mailer/reminder.html.erb`
- Create: `app/jobs/aypex_bank_transfer/send_reminders_job.rb`
- Modify: `app/models/aypex_bank_transfer/gateway.rb` (publish on session creation)
- Test: `spec/jobs/aypex_bank_transfer/send_reminders_job_spec.rb`, `spec/mailers/aypex_bank_transfer/instructions_mailer_spec.rb`

**Interfaces:**
- Consumes: `Spree::PaymentSessions::BankTransfer` (Task 4), `Gateway#bank_details` (Task 3)
- Produces: events `'bank_transfer.instructions_ready'`, `'bank_transfer.reminder_due'`, `'bank_transfer.expired'`, `'bank_transfer.reconciler_unhealthy'`; `AypexBankTransfer::SendRemindersJob`

**Events are the primary mechanism.** TKF delivers mail via storefront webhooks to Resend, so a mailer-only implementation would deliver nothing there.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/jobs/aypex_bank_transfer/send_reminders_job_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::SendRemindersJob do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }

  it 'publishes a reminder for a session expiring within two days' do
    session = create(:bank_transfer_payment_session,
                     order: order, payment_method: payment_method, expires_at: 36.hours.from_now)

    expect(Spree::Events).to receive(:publish).with(
      'bank_transfer.reminder_due', hash_including(payment_session_id: session.id)
    )

    described_class.perform_now
  end

  it 'does not publish for a session expiring far in the future' do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method, expires_at: 10.days.from_now)

    expect(Spree::Events).not_to receive(:publish)

    described_class.perform_now
  end

  it 'does not publish twice for the same session on the same day' do
    session = create(:bank_transfer_payment_session,
                     order: order, payment_method: payment_method, expires_at: 36.hours.from_now)
    session.update!(external_data: { 'last_reminder_on' => Date.current.to_s })

    expect(Spree::Events).not_to receive(:publish)

    described_class.perform_now
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/jobs/aypex_bank_transfer/send_reminders_job_spec.rb`
Expected: FAIL with `uninitialized constant AypexBankTransfer::SendRemindersJob`

- [ ] **Step 3: Register the events**

Replace `config/initializers/spree.rb` with:

```ruby
Rails.application.config.after_initialize do
  Rails.application.config.spree.payment_methods << AypexBankTransfer::Gateway

  AypexBankTransfer::Reconcilers::Base.register('manual', AypexBankTransfer::Reconcilers::Manual)

  # Spree::Events needs no up-front event registration — publishing a name is
  # enough, and subscribers match on string patterns (wildcards supported).
  unless AypexBankTransfer::Config.disable_default_mailer
    Spree::Events.subscribe('bank_transfer.instructions_ready') do |event|
      AypexBankTransfer::InstructionsMailer.
        instructions(event.payload[:payment_session_id]).deliver_later
    end

    Spree::Events.subscribe('bank_transfer.reminder_due') do |event|
      AypexBankTransfer::InstructionsMailer.
        reminder(event.payload[:payment_session_id]).deliver_later
    end
  end
end
```

> Event names are dotted strings, and payloads must contain only serializable
> primitives — subscribers run async through ActiveJob by default, so an
> ActiveRecord object in a payload will not survive the trip. This is why
> `#notification_payload` (Task 4) exists and why nothing publishes a model.

Create `lib/aypex_bank_transfer/configuration.rb`:

```ruby
module AypexBankTransfer
  class Configuration < Spree::Preferences::Configuration
    preference :disable_default_mailer, :boolean, default: false
  end
end
```

Add to `lib/aypex_bank_transfer/engine.rb` inside the `Engine` class:

```ruby
    initializer 'aypex_bank_transfer.environment', before: :load_config_initializers do |_app|
      AypexBankTransfer::Config = AypexBankTransfer::Configuration.new
    end
```

Add `require 'aypex_bank_transfer/configuration'` to `lib/aypex_bank_transfer.rb`.

- [ ] **Step 4: Publish on session creation**

In `app/models/aypex_bank_transfer/gateway.rb`, change `#create_payment_session` to publish after creating:

```ruby
    def create_payment_session(order:, amount: nil, external_data: {})
      session = ::Spree::PaymentSessions::BankTransfer.create!(
        order: order,
        payment_method: self,
        amount: amount || order.total_minus_store_credits,
        currency: order.currency,
        external_id: ReferenceGenerator.new(payment_method: self).generate,
        external_data: external_data,
        expires_at: preferred_expiry_days.to_i.days.from_now
      )

      Spree::Events.publish('bank_transfer.instructions_ready', session.notification_payload)

      session
    end
```

- [ ] **Step 5: Write the reminders job**

```ruby
# app/jobs/aypex_bank_transfer/send_reminders_job.rb
module AypexBankTransfer
  class SendRemindersJob < ActiveJob::Base
    queue_as :default

    REMIND_WITHIN = 2.days

    def perform
      ::Spree::PaymentSessions::BankTransfer.
        open.
        where(expires_at: Time.current..REMIND_WITHIN.from_now).
        find_each do |session|
          next if reminded_today?(session)

          Spree::Events.publish('bank_transfer.reminder_due', session.notification_payload)
          mark_reminded(session)
        end
    end

    private

    def reminded_today?(session)
      session.external_data.to_h['last_reminder_on'] == Date.current.to_s
    end

    def mark_reminded(session)
      session.update!(external_data: session.external_data.to_h.merge('last_reminder_on' => Date.current.to_s))
    end
  end
end
```

- [ ] **Step 6: Write the mailer and templates**

```ruby
# app/mailers/aypex_bank_transfer/instructions_mailer.rb
module AypexBankTransfer
  class InstructionsMailer < ApplicationMailer
    def instructions(payment_session_id)
      @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
      @order = @session.order
      @bank_details = @session.payment_method.bank_details

      mail(to: @order.email, subject: Spree.t('bank_transfer.reference'))
    end

    def reminder(payment_session_id)
      @session = ::Spree::PaymentSessions::BankTransfer.find(payment_session_id)
      @order = @session.order
      @bank_details = @session.payment_method.bank_details

      mail(to: @order.email, subject: Spree.t('bank_transfer.pay_within', days: 2))
    end
  end
end
```

```erb
<%# app/views/aypex_bank_transfer/instructions_mailer/instructions.html.erb %>
<h1><%= Spree.t('bank_transfer.reference') %>: <%= @session.reference %></h1>

<p><%= Spree.t('bank_transfer.reference_help') %></p>

<p>
  <strong><%= Spree.t('bank_transfer.amount_to_transfer') %>:</strong>
  <%= @session.money.to_s %>
</p>

<ul>
  <li><%= @bank_details[:account_name] %></li>
  <% if @bank_details[:iban].present? %><li>IBAN: <%= @bank_details[:iban] %></li><% end %>
  <% if @bank_details[:bic].present? %><li>BIC: <%= @bank_details[:bic] %></li><% end %>
  <% if @bank_details[:sort_code].present? %><li>Sort code: <%= @bank_details[:sort_code] %></li><% end %>
  <% if @bank_details[:account_number].present? %><li>Account number: <%= @bank_details[:account_number] %></li><% end %>
</ul>

<p><%= Spree.t('bank_transfer.dispatch_note') %></p>
```

Create `reminder.html.erb` with the same body preceded by:

```erb
<p><%= Spree.t('bank_transfer.pay_within', days: ((@session.expires_at.to_date - Date.current).to_i)) %></p>
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bundle exec rspec spec/jobs/aypex_bank_transfer/send_reminders_job_spec.rb`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add app config lib spec
git commit -m "feat: publish bank transfer events and ship a default mailer"
```

---

### Task 11: Storefront payment step and confirmation

**Files:**
- Create: `app/views/spree/checkout/payment/_aypex_bank_transfer.html.erb`
- Create: `app/views/spree/admin/payment_methods/descriptions/_aypex_bank_transfer.html.erb`
- Create: `app/views/aypex_bank_transfer/_order_instructions.html.erb`
- Test: `spec/views/aypex_bank_transfer/order_instructions_spec.rb`, `spec/views/spree/checkout/payment/bank_transfer_spec.rb`

**Interfaces:**
- Consumes: `Gateway#bank_details`, `Gateway#preferred_discount_percent` (Task 3), `Spree::PaymentSessions::BankTransfer#reference` (Task 4)
- Produces: renderable partials; no Ruby API

- [ ] **Step 1: Write the failing test**

```ruby
# spec/views/aypex_bank_transfer/order_instructions_spec.rb
require 'spec_helper'

RSpec.describe 'aypex_bank_transfer/_order_instructions', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let(:payment_session) { payment_method.create_payment_session(order: order) }

  it 'shows the reference prominently' do
    render partial: 'aypex_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include(payment_session.reference)
  end

  it 'shows the bank details' do
    render partial: 'aypex_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include('GB00TEST00000000000000')
  end

  it 'never uses surcharge language' do
    render partial: 'aypex_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered.downcase).not_to include('surcharge')
    expect(rendered.downcase).not_to include('fee')
  end
end
```

Also create `spec/views/spree/checkout/payment/bank_transfer_spec.rb`:

```ruby
require 'spec_helper'

RSpec.describe 'spree/checkout/payment/_aypex_bank_transfer', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) } # 3% in the factory

  it 'advertises the saving as a discount, never a fee' do
    render partial: 'spree/checkout/payment/aypex_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).to include('save 3%')
    expect(rendered.downcase).not_to include('surcharge')
  end

  it 'states the payment window' do
    render partial: 'spree/checkout/payment/aypex_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).to include('3 days')
  end

  it 'omits the discount line when no discount is configured' do
    payment_method.update!(preferred_discount_percent: 0)

    render partial: 'spree/checkout/payment/aypex_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).not_to include('save')
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/views`
Expected: FAIL — partials missing

- [ ] **Step 3: Write the checkout partial**

```erb
<%# app/views/spree/checkout/payment/_aypex_bank_transfer.html.erb %>
<div class="bank-transfer-payment" data-payment-method-id="<%= payment_method.id %>">
  <% if payment_method.preferred_discount_percent.to_d.positive? %>
    <p class="bank-transfer-discount">
      <%= Spree.t('bank_transfer.payment_method_label',
                  percent: payment_method.preferred_discount_percent.to_i) %>
    </p>
  <% end %>

  <p><%= Spree.t('bank_transfer.pay_within', days: payment_method.preferred_expiry_days) %></p>
  <p><%= Spree.t('bank_transfer.dispatch_note') %></p>
</div>
```

- [ ] **Step 4: Write the instructions partial**

```erb
<%# app/views/aypex_bank_transfer/_order_instructions.html.erb %>
<% bank_details = payment_session.payment_method.bank_details %>

<section class="bank-transfer-instructions">
  <h2><%= Spree.t('bank_transfer.reference') %></h2>

  <p class="bank-transfer-reference" data-controller="clipboard">
    <code data-clipboard-target="source"><%= payment_session.reference %></code>
    <button type="button" data-action="clipboard#copy">Copy</button>
  </p>

  <p class="bank-transfer-reference-help"><%= Spree.t('bank_transfer.reference_help') %></p>

  <dl>
    <dt><%= Spree.t('bank_transfer.amount_to_transfer') %></dt>
    <dd><%= payment_session.money.to_s %></dd>

    <dt>Account name</dt>
    <dd><%= bank_details[:account_name] %></dd>

    <% if bank_details[:iban].present? %>
      <dt>IBAN</dt><dd><%= bank_details[:iban] %></dd>
    <% end %>
    <% if bank_details[:bic].present? %>
      <dt>BIC</dt><dd><%= bank_details[:bic] %></dd>
    <% end %>
    <% if bank_details[:sort_code].present? %>
      <dt>Sort code</dt><dd><%= bank_details[:sort_code] %></dd>
    <% end %>
    <% if bank_details[:account_number].present? %>
      <dt>Account number</dt><dd><%= bank_details[:account_number] %></dd>
    <% end %>
  </dl>

  <p><%= Spree.t('bank_transfer.dispatch_note') %></p>
</section>
```

- [ ] **Step 5: Write the admin description partial**

```erb
<%# app/views/spree/admin/payment_methods/descriptions/_aypex_bank_transfer.html.erb %>
<p>
  Accept direct bank transfers with a unique payment reference per order,
  an optional discount, and automatic reconciliation of incoming payments.
</p>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/views`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app spec
git commit -m "feat: add storefront payment step and transfer instructions"
```

---

### Task 12: Admin configuration guide

**Files:**
- Create: `app/views/spree/admin/payment_methods/configuration_guides/_aypex_bank_transfer.html.erb`
- Test: `spec/features/admin/bank_transfer_configuration_spec.rb`

**Interfaces:**
- Consumes: `Gateway#webhook_url` (Spree core), `Gateway#reconciler_state`, `Gateway#reconciler_healthy?` (Task 8)
- Produces: renderable partial

- [ ] **Step 1: Write the failing test**

```ruby
# spec/features/admin/bank_transfer_configuration_spec.rb
require 'spec_helper'

RSpec.feature 'Bank transfer configuration guide', type: :feature do
  stub_authorization!

  let!(:payment_method) { create(:bank_transfer_gateway) }

  scenario 'shows the webhook URL and reconciler health' do
    visit spree.edit_admin_payment_method_path(payment_method)

    expect(page).to have_content('/api/v3/webhooks/payments/')
    expect(page).to have_content('Reconciler')
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/features/admin/bank_transfer_configuration_spec.rb`
Expected: FAIL — partial missing

- [ ] **Step 3: Write the partial**

```erb
<%# app/views/spree/admin/payment_methods/configuration_guides/_aypex_bank_transfer.html.erb %>
<% state = payment_method.reconciler_state %>
<% healthy = payment_method.reconciler_healthy? %>

<div class="card mb-3">
  <div class="card-body">
    <h5>Webhook URL</h5>
    <p>Paste this into your bank's webhook settings:</p>
    <pre><%= payment_method.webhook_url %></pre>

    <h5>Reconciler</h5>
    <ul class="list-unstyled">
      <li><strong>Adapter:</strong> <%= payment_method.preferred_reconciler %></li>
      <li>
        <strong>Status:</strong>
        <span class="badge <%= healthy ? 'bg-success' : 'bg-danger' %>">
          <%= healthy ? 'Healthy' : 'Unhealthy — expiry paused' %>
        </span>
      </li>
      <li><strong>Last successful poll:</strong>
        <%= state.last_successful_run_at ? l(state.last_successful_run_at, format: :short) : 'never' %>
      </li>
      <% if state.consecutive_failures.positive? %>
        <li><strong>Consecutive failures:</strong> <%= state.consecutive_failures %></li>
        <li><strong>Last error:</strong> <code><%= state.last_error %></code></li>
      <% end %>
    </ul>

    <% unless healthy %>
      <div class="alert alert-warning mb-0">
        Order expiry is paused while the reconciler is unhealthy. Unpaid orders
        will not be cancelled until reconciliation resumes.
      </div>
    <% end %>
  </div>
</div>
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/features/admin/bank_transfer_configuration_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app spec
git commit -m "feat: add admin configuration guide with reconciler health"
```

---

### Task 13: Admin unmatched transfers queue

**Files:**
- Create: `app/controllers/spree/admin/bank_transfers_controller.rb`
- Create: `app/views/spree/admin/bank_transfers/index.html.erb`
- Create: `config/routes.rb`
- Test: `spec/controllers/spree/admin/bank_transfers_controller_spec.rb`

**Interfaces:**
- Consumes: `IncomingTransfer` (Task 2), `SuggestMatches` (Task 7), `IngestTransfer#apply!` semantics (Task 6)
- Produces: routes `admin_bank_transfers_path`, `apply_admin_bank_transfer_path(id)`, `ignore_admin_bank_transfer_path(id)`

**Required in v1.** Without this every mistyped reference is a support ticket with no tool behind it.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/controllers/spree/admin/bank_transfers_controller_spec.rb
require 'spec_helper'

RSpec.describe Spree::Admin::BankTransfersController, type: :controller do
  stub_authorization!

  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let(:session_record) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method, amount: 25.00, currency: 'GBP')
  end
  let(:transfer) do
    create(:bank_transfer_incoming_transfer, amount: 25.00, currency: 'GBP', reference_raw: 'WRONG')
  end

  describe 'GET #index' do
    it 'lists unmatched transfers' do
      transfer
      get :index

      expect(assigns(:transfers)).to include(transfer)
    end
  end

  describe 'PUT #apply' do
    it 'applies the transfer to the chosen session and records who did it' do
      put :apply, params: { id: transfer.id, payment_session_id: session_record.id }

      transfer.reload
      expect(transfer).to be_applied
      expect(transfer.payment_session).to eq(session_record)
      expect(transfer.applied_by_id).to be_present
      expect(transfer.applied_at).to be_present
    end

    it 'refuses to apply an already applied transfer' do
      transfer.update!(state: 'applied', payment_session: session_record)

      put :apply, params: { id: transfer.id, payment_session_id: session_record.id }

      expect(response).to redirect_to(spree.admin_bank_transfers_path)
      expect(flash[:error]).to be_present
    end
  end

  describe 'PUT #ignore' do
    it 'marks the transfer ignored with a reason' do
      put :ignore, params: { id: transfer.id, reason: 'refunded manually' }

      transfer.reload
      expect(transfer.state).to eq('ignored')
      expect(transfer.ignored_reason).to eq('refunded manually')
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/controllers/spree/admin/bank_transfers_controller_spec.rb`
Expected: FAIL with `uninitialized constant Spree::Admin::BankTransfersController`

- [ ] **Step 3: Write the routes**

```ruby
# config/routes.rb
Spree::Core::Engine.add_routes do
  namespace :admin do
    resources :bank_transfers, only: [:index] do
      member do
        put :apply
        put :ignore
      end
    end
  end
end
```

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/spree/admin/bank_transfers_controller.rb
module Spree
  module Admin
    class BankTransfersController < Spree::Admin::BaseController
      before_action :load_transfer, only: %i[apply ignore]

      def index
        @transfers = AypexBankTransfer::IncomingTransfer.
                     unmatched.
                     order(occurred_at: :desc).
                     page(params[:page]).per(25)

        @suggestions = @transfers.each_with_object({}) do |transfer, acc|
          acc[transfer.id] = AypexBankTransfer::SuggestMatches.new(transfer: transfer).call
        end
      end

      def apply
        if @transfer.applied?
          flash[:error] = 'That transfer has already been applied.'
          return redirect_to spree.admin_bank_transfers_path
        end

        session_record = ::Spree::PaymentSessions::BankTransfer.find(params[:payment_session_id])

        ActiveRecord::Base.transaction do
          payment = session_record.find_or_create_payment!
          session_record.complete! unless session_record.completed?
          payment.complete! unless payment.completed?

          @transfer.update!(
            state: 'applied',
            payment_session: session_record,
            applied_by_id: try_spree_current_user&.id,
            applied_at: Time.current
          )
        end

        flash[:success] = 'Payment applied.'
        redirect_to spree.admin_bank_transfers_path
      end

      def ignore
        @transfer.update!(state: 'ignored', ignored_reason: params[:reason])

        flash[:success] = 'Transfer ignored.'
        redirect_to spree.admin_bank_transfers_path
      end

      private

      def load_transfer
        @transfer = AypexBankTransfer::IncomingTransfer.find(params[:id])
      end
    end
  end
end
```

- [ ] **Step 5: Write the view**

```erb
<%# app/views/spree/admin/bank_transfers/index.html.erb %>
<h1>Unmatched bank transfers</h1>

<% if @transfers.empty? %>
  <p>Nothing waiting. Every observed transfer has been matched or ignored.</p>
<% else %>
  <table class="table">
    <thead>
      <tr>
        <th>Received</th><th>Amount</th><th>Payer</th>
        <th>Reference as sent</th><th>Suggested orders</th><th></th>
      </tr>
    </thead>
    <tbody>
      <% @transfers.each do |transfer| %>
        <tr>
          <td><%= l(transfer.occurred_at, format: :short) %></td>
          <td><%= transfer.money.to_s %></td>
          <td><%= transfer.payer_name %></td>
          <td><code><%= transfer.reference_raw.presence || '—' %></code></td>
          <td>
            <% Array(@suggestions[transfer.id]).each do |suggestion| %>
              <%= form_tag spree.apply_admin_bank_transfer_path(transfer), method: :put, class: 'd-inline' do %>
                <%= hidden_field_tag :payment_session_id, suggestion.id %>
                <%= submit_tag "#{suggestion.order.number} — #{suggestion.money}", class: 'btn btn-sm btn-primary' %>
              <% end %>
            <% end %>
            <% if Array(@suggestions[transfer.id]).empty? %>—<% end %>
          </td>
          <td>
            <%= form_tag spree.ignore_admin_bank_transfer_path(transfer), method: :put do %>
              <%= text_field_tag :reason, nil, placeholder: 'Reason', class: 'form-control form-control-sm d-inline w-auto' %>
              <%= submit_tag 'Ignore', class: 'btn btn-sm btn-outline-secondary' %>
            <% end %>
          </td>
        </tr>
      <% end %>
    </tbody>
  </table>

  <%= paginate @transfers %>
<% end %>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/controllers/spree/admin/bank_transfers_controller_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app config spec
git commit -m "feat: add admin unmatched transfers queue"
```

---

### Task 14: Admin order detail panel and full-suite verification

**Files:**
- Create: `app/views/aypex_bank_transfer/admin/_order_panel.html.erb`
- Modify: `README.md`
- Test: `spec/views/aypex_bank_transfer/admin/order_panel_spec.rb`

**Interfaces:**
- Consumes: everything built so far
- Produces: renderable admin panel; documented install instructions

- [ ] **Step 1: Write the failing test**

```ruby
# spec/views/aypex_bank_transfer/admin/order_panel_spec.rb
require 'spec_helper'

RSpec.describe 'aypex_bank_transfer/admin/_order_panel', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }

  it 'shows the reference and awaiting status for an unpaid order' do
    session = payment_method.create_payment_session(order: order)

    render partial: 'aypex_bank_transfer/admin/order_panel', locals: { order: order }

    expect(rendered).to include(session.reference)
    expect(rendered).to include('Awaiting transfer')
  end

  it 'renders nothing for an order with no bank transfer session' do
    render partial: 'aypex_bank_transfer/admin/order_panel', locals: { order: order }

    expect(rendered.strip).to be_empty
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/views/aypex_bank_transfer/admin/order_panel_spec.rb`
Expected: FAIL — partial missing

- [ ] **Step 3: Write the panel**

```erb
<%# app/views/aypex_bank_transfer/admin/_order_panel.html.erb %>
<% session = Spree::PaymentSessions::BankTransfer.where(order_id: order.id).order(created_at: :desc).first %>
<% return if session.blank? %>

<div class="card mb-3">
  <div class="card-header">Bank transfer</div>
  <div class="card-body">
    <dl class="row mb-0">
      <dt class="col-4">Reference</dt>
      <dd class="col-8"><code><%= session.reference %></code></dd>

      <dt class="col-4">Amount</dt>
      <dd class="col-8"><%= session.money.to_s %></dd>

      <dt class="col-4">Status</dt>
      <dd class="col-8">
        <% if session.completed? %>
          <span class="badge bg-success">Paid</span>
        <% elsif session.expired? || session.status == 'expired' %>
          <span class="badge bg-secondary">Expired</span>
        <% else %>
          <span class="badge bg-warning text-dark">Awaiting transfer</span>
        <% end %>
      </dd>

      <% if session.expires_at.present? && session.status == 'pending' %>
        <dt class="col-4">Expires</dt>
        <dd class="col-8">
          <%= l(session.expires_at, format: :short) %>
          (<%= distance_of_time_in_words(Time.current, session.expires_at) %> from now)
        </dd>
      <% end %>

      <% transfer = AypexBankTransfer::IncomingTransfer.find_by(payment_session_id: session.id) %>
      <% if transfer.present? %>
        <dt class="col-4">Matched transfer</dt>
        <dd class="col-8">
          <%= transfer.provider %> <code><%= transfer.provider_transaction_id %></code>
          <% if transfer.applied_by_id.present? %>
            <span class="text-muted">(applied manually)</span>
          <% end %>
        </dd>
      <% end %>
    </dl>
  </div>
</div>
```

- [ ] **Step 4: Write the README**

```markdown
# aypex_bank_transfer

Bank transfer checkout for Spree 5.6+, with pluggable reconciliation of
incoming payments.

## Requirements

PostgreSQL. The gem uses `jsonb`, partial unique indexes, and `pg_trgm`.

## Installation

```ruby
gem 'aypex_bank_transfer', github: 'aypex-io/aypex_bank_transfer'
```

```bash
bundle install
bin/rails g aypex_bank_transfer:install
```

## Configuration

Add a Bank Transfer payment method in the Spree admin and set:

| Preference | Purpose |
|---|---|
| `reconciler` | `manual` by default; `revolut` with `aypex_bank_transfer_revolut` installed |
| `reference_prefix` | Prefix on generated references, e.g. `TKF-` |
| `expiry_days` | Days before an unpaid order is cancelled and restocked |
| `discount_percent` | Percentage off `item_total` for paying by transfer |
| `poll_interval_minutes` | How often the reconciler polls; drives the health gate |
| `account_*` | Bank details shown to the customer |

## Scheduling

Both jobs must be scheduled — without them nothing expires and no reminders send:

```ruby
AypexBankTransfer::ExpireSessionsJob  # hourly
AypexBankTransfer::SendRemindersJob   # daily
```

## The health gate

`ExpireSessionsJob` refuses to cancel orders when the reconciler has not polled
successfully within three poll intervals. A lapsed credential therefore raises
an alert rather than cancelling orders for customers who have paid. Subscribe to
`bank_transfer.reconciler_unhealthy` to route that alert.

## Events

Notifications are published to `Spree::Events`, not sent directly:

- `bank_transfer.instructions_ready`
- `bank_transfer.reminder_due`
- `bank_transfer.expired`
- `bank_transfer.reconciler_unhealthy`

Payloads contain serializable primitives only — see
`Spree::PaymentSessions::BankTransfer#notification_payload`. Subscribe with
`Spree::Events.subscribe('bank_transfer.*', MyHandler)`.

A default mailer subscribes to the first two. Disable it with
`AypexBankTransfer::Config.disable_default_mailer = true` when your store
delivers mail another way.

## Writing a reconciler

Subclass `AypexBankTransfer::Reconcilers::Base`, implement `#poll(since:)`,
`#parse_webhook(raw_body, headers)`, `#healthy?` and `#configured?`, register it,
and run the shared contract test:

```ruby
require 'aypex_bank_transfer/testing_support/reconciler_shared_examples'

RSpec.describe MyReconciler do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it_behaves_like 'a bank transfer reconciler'
end
```
```

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS, all specs green

- [ ] **Step 6: Verify the critical guarantee explicitly**

Run: `bundle exec rspec spec/jobs/aypex_bank_transfer/expire_sessions_job_spec.rb -e 'cancels nothing'`
Expected: PASS. If this test does not exist or does not pass, stop — the gem is not safe to ship.

- [ ] **Step 7: Commit**

```bash
git add app spec README.md
git commit -m "feat: add admin order panel and document the gem"
```

---

### Task 15: Webhook entrypoint and poll job

**Files:**
- Modify: `app/models/aypex_bank_transfer/gateway.rb` (add `parse_webhook_event`)
- Create: `app/jobs/aypex_bank_transfer/poll_job.rb`
- Test: `spec/models/aypex_bank_transfer/gateway_webhook_spec.rb`, `spec/jobs/aypex_bank_transfer/poll_job_spec.rb`

**Interfaces:**
- Consumes: `Reconcilers::Base#parse_webhook`, `#poll` (Task 5), `IngestTransfer` (Task 6), `ReconcilerState#record_success!`/`#record_failure!` (Task 2)
- Produces: `AypexBankTransfer::Gateway#parse_webhook_event(raw_body, headers) → Hash|nil`, `AypexBankTransfer::PollJob.perform_now`

Both ingress paths are bank-agnostic wiring and belong in core. The `Manual`
reconciler makes them harmless no-ops; `aypex_bank_transfer_revolut` makes them
live by supplying an adapter that actually returns data.

Spree's `Spree::Api::V3::Webhooks::PaymentsController` calls
`payment_method.parse_webhook_event(request.raw_post, request.headers)` and
expects `{ action:, payment_session:, metadata: }` or `nil`. We persist the
`IncomingTransfer` first and return `nil` when nothing matched, which that
controller treats as acknowledge-receipt.

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/models/aypex_bank_transfer/gateway_webhook_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::Gateway, '#parse_webhook_event' do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:order_with_line_items, currency: 'GBP') }
  let!(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method,
           external_id: 'TKF-7Q4X2', amount: 25.00, currency: 'GBP')
  end

  def stub_reconciler(transfer_data)
    reconciler = payment_method.reconciler
    allow(reconciler).to receive(:parse_webhook).and_return(transfer_data)
    allow(payment_method).to receive(:reconciler).and_return(reconciler)
  end

  let(:data) do
    AypexBankTransfer::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-1', amount: 25.00,
      currency: 'GBP', reference: 'TKF-7Q4X2', payer_name: 'Jane Doe',
      occurred_at: Time.current, raw: {}
    )
  end

  it 'returns nil when the reconciler ignores the event' do
    stub_reconciler(nil)

    expect(payment_method.parse_webhook_event('{}', {})).to be_nil
  end

  it 'ingests and reports a captured action on an exact match' do
    stub_reconciler(data)

    result = payment_method.parse_webhook_event('{}', {})

    expect(result[:action]).to eq(:captured)
    expect(result[:payment_session]).to eq(session)
    expect(AypexBankTransfer::IncomingTransfer.last).to be_applied
  end

  it 'persists the transfer but returns nil when nothing matches' do
    stub_reconciler(data.with(reference: 'TKF-NOPE1'))

    expect(payment_method.parse_webhook_event('{}', {})).to be_nil
    expect(AypexBankTransfer::IncomingTransfer.last).to be_unmatched
  end
end
```

```ruby
# spec/jobs/aypex_bank_transfer/poll_job_spec.rb
require 'spec_helper'

RSpec.describe AypexBankTransfer::PollJob do
  let(:payment_method) { create(:bank_transfer_gateway) }

  before { payment_method }

  it 'records a successful run when the reconciler returns cleanly' do
    described_class.perform_now

    expect(payment_method.reconciler_state.reload.last_successful_run_at).to be_present
  end

  it 'records a failure and does not raise when the reconciler blows up' do
    allow_any_instance_of(AypexBankTransfer::Reconcilers::Manual).
      to receive(:poll).and_raise(StandardError, 'credentials expired')

    expect { described_class.perform_now }.not_to raise_error

    state = payment_method.reconciler_state.reload
    expect(state.last_error).to include('credentials expired')
    expect(state.consecutive_failures).to eq(1)
    expect(state.last_successful_run_at).to be_nil
  end

  it 'ingests every transfer the reconciler returns' do
    data = AypexBankTransfer::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-77', amount: 10.00,
      currency: 'GBP', reference: 'TKF-ZZZZZZ', payer_name: 'Jane Doe',
      occurred_at: Time.current, raw: {}
    )
    allow_any_instance_of(AypexBankTransfer::Reconcilers::Manual).
      to receive(:poll).and_return([data])

    expect { described_class.perform_now }.
      to change(AypexBankTransfer::IncomingTransfer, :count).by(1)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/gateway_webhook_spec.rb spec/jobs/aypex_bank_transfer/poll_job_spec.rb`
Expected: FAIL — `parse_webhook_event` raises `NotImplementedError`, `PollJob` undefined

- [ ] **Step 3: Implement `parse_webhook_event`**

Add to `app/models/aypex_bank_transfer/gateway.rb`, after `#reconciler_healthy?`:

```ruby
    # Called by Spree::Api::V3::Webhooks::PaymentsController. Signature
    # verification happens inside the reconciler and raises
    # Spree::PaymentMethod::WebhookSignatureError, which the controller turns
    # into a 401.
    def parse_webhook_event(raw_body, headers)
      data = reconciler.parse_webhook(raw_body, headers)
      return nil if data.nil?

      transfer = IngestTransfer.new(payment_method: self, transfer_data: data).call
      return nil unless transfer.applied?

      {
        action: :captured,
        payment_session: transfer.payment_session,
        metadata: { incoming_transfer_id: transfer.id }
      }
    end
```

- [ ] **Step 4: Write the poll job**

```ruby
# app/jobs/aypex_bank_transfer/poll_job.rb
module AypexBankTransfer
  class PollJob < ActiveJob::Base
    queue_as :default

    # Deliberate overlap with the previous run. Ingestion is idempotent, so
    # re-reading recent transfers costs nothing and closes the gap when a
    # provider exhausts its webhook retries.
    OVERLAP = 2.hours

    def perform
      AypexBankTransfer::Gateway.find_each do |payment_method|
        poll_one(payment_method)
      end
    end

    private

    def poll_one(payment_method)
      state = payment_method.reconciler_state
      since = (state.last_successful_run_at || 7.days.ago) - OVERLAP

      payment_method.reconciler.poll(since: since).each do |data|
        IngestTransfer.new(payment_method: payment_method, transfer_data: data).call
      end

      state.record_success!
    rescue StandardError => e
      # Never re-raise: one misconfigured payment method must not stop the
      # others, and the recorded failure is what flips the health gate.
      state.record_failure!(e.message)
      Rails.error.report(e, source: 'aypex_bank_transfer.poll')
    end
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/aypex_bank_transfer/gateway_webhook_spec.rb spec/jobs/aypex_bank_transfer/poll_job_spec.rb`
Expected: PASS

- [ ] **Step 6: Document the schedule**

Add `AypexBankTransfer::PollJob` to the scheduling table in `README.md`, at the payment method's `poll_interval_minutes` cadence (default every 15 minutes), noting that the health gate derives from this job's success.

- [ ] **Step 7: Commit**

```bash
git add app spec README.md
git commit -m "feat: add webhook entrypoint and poll job orchestration"
```

---

## Definition of done

- [ ] `bundle exec rspec` fully green against PostgreSQL
- [ ] A store can install the gem, add a Bank Transfer method, and take an order end to end with the `manual` reconciler
- [ ] Underpayment, overpayment, currency mismatch, unknown reference, blank reference, expired session and cancelled session all queue rather than auto-apply, each with a passing test
- [ ] The same transfer ingested twice produces exactly one `Spree::Payment`
- [ ] `ExpireSessionsJob` cancels nothing when the reconciler is unhealthy
- [ ] The reconciler shared example group is exported and passes against `Manual`
- [ ] `PollJob` records failures without raising, and a failure flips the health gate
- [ ] `parse_webhook_event` persists an `IncomingTransfer` even when nothing matches
- [ ] No customer-facing copy uses the words "fee" or "surcharge"
