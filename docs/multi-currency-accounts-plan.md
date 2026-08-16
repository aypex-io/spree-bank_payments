# Multi-currency bank accounts — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a store hold one bank account per currency, quote the right one to each customer, and switch accounts without stranding existing orders.

**Architecture:** First-class `BankAccount` records hold a `jsonb` list of detail sets (coordinates are not standardised across countries, so they are stored as ordered label/value pairs rather than named columns). An admin checklist marks at most one account **offered** per currency — enforced by a partial unique index — while *every* synced account stays watched, so switching accounts is a non-event. Payment sessions and incoming transfers each record the account they relate to, making a payment into the wrong account diagnosable rather than a silent currency mismatch.

**Tech Stack:** Ruby 3.3+, Rails 8.1, Spree 5.6 (`spree`, `spree_admin`), RSpec + `spree_dev_tools`, PostgreSQL (jsonb, partial indexes).

**Spec:** `docs/multi-currency-accounts-design.md`

## Global Constraints

- Namespace `Spree::BankPayments`. Table prefix `spree_bank_payments_`, defined on the **module** in `lib/spree/bank_payments.rb` — never as a class method on `Base` (Spree's own `spree_` prefix wins the `module_parents` lookup).
- **PostgreSQL only.** `jsonb` and partial indexes are load-bearing.
- Target version **5.2.0** — a minor. **No public method may be removed.** `#bank_details` stays as a deprecated shim.
- Contract additions must be **backward compatible with 5.1.1**: a provider gem written against the published contract must keep working untouched.
- Events go through `Spree::Events.publish('dotted.name', payload_hash)` with **serializable primitives only**. There is no `Spree::Bus`.
- Discounts compute from `order.item_total`, never `order.total`.
- Customer-facing copy says "discount"/"save", never "fee"/"surcharge".
- **Sync never sets `offered`** and **never touches `bank_account_id` on existing sessions.**

---

## File Structure

| Path | Responsibility |
|---|---|
| `db/migrate/20260817000001_create_spree_bank_payments_bank_accounts.rb` | Accounts table + indexes |
| `db/migrate/20260817000002_add_bank_account_id_to_sessions_and_transfers.rb` | Linkage columns |
| `db/migrate/20260817000003_migrate_legacy_account_preferences.rb` | Data migration from flat preferences |
| `app/models/spree/bank_payments/bank_account.rb` | The account: currency, offered/active, detail sets |
| `app/models/spree/bank_payments/detail_set.rb` | Read model over one entry in the `details` jsonb |
| `app/models/spree/bank_payments/account_data.rb` | Value object crossing the gem boundary |
| `app/services/spree/bank_payments/sync_accounts.rb` | Diff + apply, with the abort guard |
| `app/controllers/spree/admin/bank_accounts_controller.rb` | Checklist + manual CRUD |
| `app/views/spree/admin/bank_accounts/*` | Admin screens |
| `app/models/spree/bank_payments/gateway.rb` | `bank_accounts`, `bank_details_for`, `available_for_order?` |
| `app/views/spree/bank_payments/_order_instructions.html.erb` | Renders every detail set generically |

---

### Task 1: BankAccount model and schema

**Files:**
- Create: `db/migrate/20260817000001_create_spree_bank_payments_bank_accounts.rb`
- Create: `app/models/spree/bank_payments/bank_account.rb`
- Modify: `lib/spree/bank_payments/factories.rb`
- Test: `spec/models/spree/bank_payments/bank_account_spec.rb`

**Interfaces:**
- Consumes: `Spree::BankPayments::Base` (abstract AR class, existing)
- Produces: `Spree::BankPayments::BankAccount` with `currency`, `details`, `offered`, `active`, `provider_account_id`, `synced_at`; scopes `.offered`, `.active`, `.for_currency(code)`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/spree/bank_payments/bank_account_spec.rb
require 'spec_helper'

RSpec.describe Spree::BankPayments::BankAccount do
  let(:payment_method) { create(:bank_transfer_gateway) }

  it 'upcases the currency on write' do
    account = create(:bank_payments_bank_account, payment_method: payment_method, currency: 'gbp')

    expect(account.reload.currency).to eq('GBP')
  end

  it 'requires at least one detail set with a non-blank field' do
    account = build(:bank_payments_bank_account, payment_method: payment_method, details: [])

    expect(account).not_to be_valid
    expect(account.errors[:details]).to be_present
  end

  it 'rejects a detail set whose fields are all blank' do
    account = build(:bank_payments_bank_account, payment_method: payment_method,
                    details: [{ 'label' => 'UK', 'fields' => [{ 'label' => 'Sort code', 'value' => '' }] }])

    expect(account).not_to be_valid
  end

  # The database, not a form validation, is what guarantees "one offered per
  # currency" -- the admin checklist and sync both depend on it being true.
  it 'refuses a second offered account for the same currency' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    second = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

    expect { second.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows a second NON-offered account for the same currency' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    second = build(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: false)

    expect(second).to be_valid
    expect { second.save! }.not_to raise_error
  end

  it 'refuses a duplicate provider_account_id on the same payment method' do
    create(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1')
    dup = build(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: 'acc-1')

    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'allows many hand-created accounts with no provider_account_id' do
    create(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: nil, currency: 'GBP')
    other = build(:bank_payments_bank_account, payment_method: payment_method, provider_account_id: nil, currency: 'EUR')

    expect { other.save! }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/spree/bank_payments/bank_account_spec.rb`
Expected: FAIL with `uninitialized constant Spree::BankPayments::BankAccount`

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260817000001_create_spree_bank_payments_bank_accounts.rb
class CreateSpreeBankPaymentsBankAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_bank_payments_bank_accounts do |t|
      t.bigint   :payment_method_id, null: false
      t.string   :provider_account_id
      t.string   :currency, null: false
      t.jsonb    :details, null: false, default: []
      t.boolean  :offered, null: false, default: false
      t.boolean  :active,  null: false, default: true
      t.datetime :synced_at
      t.timestamps
    end

    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id active],
              name: 'index_bp_bank_accounts_on_pm_and_active'

    # Sync idempotency. Partial so that hand-created accounts, which have no
    # provider id, are not all collapsed into one NULL row.
    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id provider_account_id],
              unique: true,
              where: 'provider_account_id IS NOT NULL',
              name: 'index_bp_bank_accounts_on_pm_and_provider_id'

    # At most one offered account per currency, guaranteed by the database.
    add_index :spree_bank_payments_bank_accounts, %i[payment_method_id currency],
              unique: true,
              where: 'offered',
              name: 'index_bp_bank_accounts_on_pm_and_currency_offered'
  end
end
```

- [ ] **Step 4: Write the model**

```ruby
# app/models/spree/bank_payments/bank_account.rb
module Spree
  module BankPayments
    # One account money can arrive in. `offered` decides whether customers are
    # quoted it; every active account is watched regardless, which is what makes
    # switching accounts safe for orders already in flight.
    class BankAccount < Base
      belongs_to :payment_method, class_name: 'Spree::PaymentMethod'

      validates :currency, presence: true, format: { with: /\A[A-Za-z]{3}\z/ }
      validate :has_a_usable_detail_set

      scope :offered, -> { where(offered: true) }
      scope :active,  -> { where(active: true) }
      scope :for_currency, ->(code) { where(currency: code.to_s.upcase) }

      before_validation :normalize_currency

      # @return [Array<Spree::BankPayments::DetailSet>]
      def detail_sets
        Array(details).map { |raw| DetailSet.new(raw) }
      end

      def synced?
        provider_account_id.present?
      end

      private

      def normalize_currency
        self.currency = currency.to_s.upcase.presence
      end

      # An account with no payable coordinates is worse than no account: the
      # customer is quoted an empty instruction block and has nowhere to send
      # money.
      def has_a_usable_detail_set
        return if detail_sets.any?(&:usable?)

        errors.add(:details, :blank)
      end
    end
  end
end
```

- [ ] **Step 5: Add the factory**

Append inside the existing `FactoryBot.define` block in `lib/spree/bank_payments/factories.rb`:

```ruby
  factory :bank_payments_bank_account, class: 'Spree::BankPayments::BankAccount' do
    association :payment_method, factory: :bank_transfer_gateway
    currency { 'GBP' }
    offered { true }
    active { true }
    details do
      [
        {
          'label' => 'UK payments',
          'schemes' => %w[faster bacs chaps],
          'beneficiary_name' => 'Example Store Ltd',
          'fields' => [
            { 'label' => 'Sort code', 'value' => '04-00-75' },
            { 'label' => 'Account number', 'value' => '12345678' }
          ]
        },
        {
          'label' => 'International',
          'schemes' => %w[swift],
          'beneficiary_name' => 'Example Store Ltd',
          'fields' => [
            { 'label' => 'IBAN', 'value' => 'GB00REVO00000000000000' },
            { 'label' => 'BIC', 'value' => 'REVOGB21' }
          ]
        }
      ]
    end
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/bank_account_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add db app lib spec
git commit -m "Add BankAccount model with one-offered-per-currency enforced in the database"
```

---

### Task 2: DetailSet read model

**Files:**
- Create: `app/models/spree/bank_payments/detail_set.rb`
- Test: `spec/models/spree/bank_payments/detail_set_spec.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `Spree::BankPayments::DetailSet.new(hash)` with `#label`, `#schemes → Array<String>`, `#beneficiary_name`, `#beneficiary_address`, `#fields → Array<[label, value]>`, `#usable? → Boolean`

The coordinates are **not standardised across countries or the EEA** — sort code here, routing number there, Elixir something else again. `fields` is therefore an ordered list of label/value pairs, and this class is the only thing that knows that shape. Views render pairs and never learn what a routing number is.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/spree/bank_payments/detail_set_spec.rb
require 'spec_helper'

RSpec.describe Spree::BankPayments::DetailSet do
  it 'exposes label, schemes and beneficiary' do
    set = described_class.new(
      'label' => 'UK payments', 'schemes' => %w[faster bacs],
      'beneficiary_name' => 'Example Store Ltd'
    )

    expect(set.label).to eq('UK payments')
    expect(set.schemes).to eq(%w[faster bacs])
    expect(set.beneficiary_name).to eq('Example Store Ltd')
  end

  it 'returns fields as ordered label/value pairs' do
    set = described_class.new('fields' => [
      { 'label' => 'Sort code', 'value' => '04-00-75' },
      { 'label' => 'Account number', 'value' => '12345678' }
    ])

    expect(set.fields).to eq([['Sort code', '04-00-75'], ['Account number', '12345678']])
  end

  # The whole point of label/value pairs: a market we have never heard of
  # renders without a migration or a view change.
  it 'renders coordinate labels it has never seen' do
    set = described_class.new('fields' => [{ 'label' => 'Elixir number', 'value' => '1234' }])

    expect(set.fields).to eq([['Elixir number', '1234']])
    expect(set).to be_usable
  end

  it 'drops blank-valued fields' do
    set = described_class.new('fields' => [
      { 'label' => 'IBAN', 'value' => 'GB00' },
      { 'label' => 'BIC', 'value' => '' }
    ])

    expect(set.fields).to eq([['IBAN', 'GB00']])
  end

  it 'is unusable with no fields at all' do
    expect(described_class.new('label' => 'Empty')).not_to be_usable
  end

  it 'tolerates symbol keys' do
    set = described_class.new(label: 'UK', fields: [{ label: 'Sort code', value: '04-00-75' }])

    expect(set.label).to eq('UK')
    expect(set.fields).to eq([['Sort code', '04-00-75']])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/spree/bank_payments/detail_set_spec.rb`
Expected: FAIL with `uninitialized constant Spree::BankPayments::DetailSet`

- [ ] **Step 3: Write the class**

```ruby
# app/models/spree/bank_payments/detail_set.rb
module Spree
  module BankPayments
    # One set of payable coordinates for an account -- a local scheme, or SWIFT.
    #
    # `fields` is an ordered list of label/value pairs rather than named keys
    # because bank coordinates are not standardised: the UK uses a sort code and
    # account number, the US a routing number, Poland's Elixir something else
    # again. Named columns or fixed keys would mean a migration per market.
    class DetailSet
      def initialize(raw)
        @raw = (raw || {}).transform_keys(&:to_s)
      end

      def label
        @raw['label'].presence
      end

      def schemes
        Array(@raw['schemes']).map(&:to_s)
      end

      def beneficiary_name
        @raw['beneficiary_name'].presence
      end

      def beneficiary_address
        @raw['beneficiary_address']
      end

      # @return [Array<Array(String, String)>] ordered [label, value] pairs
      def fields
        Array(@raw['fields']).filter_map do |field|
          f = field.transform_keys(&:to_s)
          value = f['value'].to_s.strip
          next if value.empty?

          [f['label'].to_s, value]
        end
      end

      def usable?
        fields.any?
      end

      def to_h
        @raw
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/detail_set_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app spec
git commit -m "Add DetailSet read model over the details jsonb"
```

---

### Task 3: Gateway wiring — quoting and availability

**Files:**
- Modify: `app/models/spree/bank_payments/gateway.rb`
- Test: `spec/models/spree/bank_payments/gateway_accounts_spec.rb`

**Interfaces:**
- Consumes: `BankAccount` (Task 1), `DetailSet` (Task 2)
- Produces: `Gateway#bank_accounts`, `#offered_account_for(currency) → BankAccount|nil`, `#bank_details_for(currency) → Array<DetailSet>`, `#bank_details` (deprecated), `#available_for_order?(order) → Boolean`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/spree/bank_payments/gateway_accounts_spec.rb
require 'spec_helper'

RSpec.describe Spree::BankPayments::Gateway, 'accounts' do
  let(:gateway) { create(:bank_transfer_gateway) }

  it 'returns the offered account for a currency' do
    gbp = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'EUR', offered: true)

    expect(gateway.offered_account_for('GBP')).to eq(gbp)
  end

  it 'ignores non-offered and inactive accounts when quoting' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: false)

    expect(gateway.offered_account_for('GBP')).to be_nil
  end

  it 'returns every detail set for the quoted account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)

    labels = gateway.bank_details_for('GBP').map(&:label)

    expect(labels).to eq(['UK payments', 'International'])
  end

  it 'is unavailable for an order whose currency has no offered account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    order = create(:order, currency: 'EUR')

    expect(gateway.available_for_order?(order)).to be(false)
  end

  it 'is available when the order currency has an offered account' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true)
    order = create(:order, currency: 'GBP')

    expect(gateway.available_for_order?(order)).to be(true)
  end

  # 5.2.0 is a minor: removing a public method would break a host's custom view
  # or another extension.
  it 'keeps #bank_details as a deprecated shim' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: Spree::Config[:currency], offered: true)

    expect(gateway).to respond_to(:bank_details)
    expect(gateway.bank_details).to be_an(Array)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/spree/bank_payments/gateway_accounts_spec.rb`
Expected: FAIL with `undefined method 'offered_account_for'`

- [ ] **Step 3: Wire the gateway**

Add to `app/models/spree/bank_payments/gateway.rb`, and **replace** the existing `#bank_details`:

```ruby
      has_many :bank_accounts,
               class_name: 'Spree::BankPayments::BankAccount',
               foreign_key: :payment_method_id,
               dependent: :destroy

      # The account customers are quoted for this currency. Only one can be
      # offered per currency -- guaranteed by a partial unique index.
      def offered_account_for(currency)
        bank_accounts.active.offered.for_currency(currency).first
      end

      # @return [Array<Spree::BankPayments::DetailSet>] every usable detail set,
      #   in order. The buyer is always shown all of them: they know where they
      #   bank, and inferring local-vs-international from billing country would
      #   need a maintained SEPA membership list and would hide the details the
      #   customer actually needed when it guessed wrong.
      def bank_details_for(currency)
        account = offered_account_for(currency)
        return [] if account.nil?

        account.detail_sets.select(&:usable?)
      end

      def available_for_order?(order)
        return false unless super

        offered_account_for(order.currency).present?
      end

      # @deprecated Use #bank_details_for(currency).
      def bank_details
        Spree::Deprecation.warn(
          'Spree::BankPayments::Gateway#bank_details is deprecated; ' \
          'use #bank_details_for(currency).'
        )
        bank_details_for(Spree::Config[:currency])
      end
```

If `Spree::Deprecation` is not defined in this Spree version, use `Rails.logger.warn` with the same message and note it in your report.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/gateway_accounts_spec.rb`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `bundle exec rspec` with `timeout: 600000`
Expected: existing specs referencing `bank_details` will fail — they assert the old hash shape. Update them to `bank_details_for`, and report which and why. Do **not** weaken any assertion.

- [ ] **Step 6: Commit**

```bash
git add app spec
git commit -m "Quote the account matching the order currency"
```

---

### Task 4: Migrate the legacy flat preferences

**Files:**
- Create: `db/migrate/20260817000003_migrate_legacy_account_preferences.rb`
- Test: `spec/migrations/legacy_account_preferences_spec.rb`

**Interfaces:**
- Consumes: `BankAccount` (Task 1)
- Produces: nothing new; existing installs keep quoting what they quoted before

The five `account_*` preferences are superseded. An install upgrading to 5.2.0 must not silently start quoting nothing.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/migrations/legacy_account_preferences_spec.rb
require 'spec_helper'

RSpec.describe 'legacy account preference migration' do
  let(:gateway) do
    create(:bank_transfer_gateway).tap do |g|
      g.preferred_account_name = 'Old Ltd'
      g.preferred_account_iban = 'GB00OLD00000000000000'
      g.preferred_account_bic = 'OLDBGB21'
      g.save!
    end
  end

  it 'folds the flat preferences into one offered default-currency account' do
    gateway
    Spree::BankPayments::MigrateLegacyAccounts.call

    account = gateway.reload.bank_accounts.sole

    expect(account.currency).to eq(Spree::Config[:currency].upcase)
    expect(account).to be_offered
    expect(account.detail_sets.first.fields).to include(['IBAN', 'GB00OLD00000000000000'])
  end

  it 'is idempotent' do
    gateway
    2.times { Spree::BankPayments::MigrateLegacyAccounts.call }

    expect(gateway.reload.bank_accounts.count).to eq(1)
  end

  it 'leaves a gateway that already has accounts alone' do
    create(:bank_payments_bank_account, payment_method: gateway, currency: 'EUR', offered: true)

    expect { Spree::BankPayments::MigrateLegacyAccounts.call }.
      not_to change { gateway.reload.bank_accounts.count }
  end

  it 'creates nothing for a gateway with no legacy preferences set' do
    bare = create(:bank_transfer_gateway)
    bare.preferences = bare.preferences.merge(
      account_name: nil, account_iban: nil, account_bic: nil,
      account_sort_code: nil, account_number: nil
    )
    bare.save!

    Spree::BankPayments::MigrateLegacyAccounts.call

    expect(bare.reload.bank_accounts).to be_empty
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/migrations/legacy_account_preferences_spec.rb`
Expected: FAIL with `uninitialized constant Spree::BankPayments::MigrateLegacyAccounts`

- [ ] **Step 3: Write the service and migration**

```ruby
# app/services/spree/bank_payments/migrate_legacy_accounts.rb
module Spree
  module BankPayments
    # Folds the pre-5.2 flat account_* preferences into a BankAccount so an
    # upgrading install keeps quoting exactly what it quoted before.
    class MigrateLegacyAccounts
      LEGACY_FIELDS = [
        ['Account name',   :preferred_account_name],
        ['IBAN',           :preferred_account_iban],
        ['BIC',            :preferred_account_bic],
        ['Sort code',      :preferred_account_sort_code],
        ['Account number', :preferred_account_number]
      ].freeze

      def self.call
        Spree::BankPayments::Gateway.find_each do |gateway|
          next if gateway.bank_accounts.exists?

          fields = LEGACY_FIELDS.filter_map do |label, reader|
            value = gateway.public_send(reader).to_s.strip
            { 'label' => label, 'value' => value } unless value.empty?
          end
          next if fields.empty?

          gateway.bank_accounts.create!(
            currency: Spree::Config[:currency].to_s.upcase,
            offered: true,
            active: true,
            details: [{ 'label' => 'Bank transfer', 'schemes' => [], 'fields' => fields }]
          )
        end
      end
    end
  end
end
```

```ruby
# db/migrate/20260817000003_migrate_legacy_account_preferences.rb
class MigrateLegacyAccountPreferences < ActiveRecord::Migration[8.1]
  def up
    Spree::BankPayments::MigrateLegacyAccounts.call
  end

  def down
    # Irreversible by design: the accounts may have been edited since.
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/migrations/legacy_account_preferences_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app db spec
git commit -m "Migrate legacy flat account preferences into a BankAccount"
```

---

### Task 5: Session and transfer linkage

**Files:**
- Create: `db/migrate/20260817000002_add_bank_account_id_to_sessions_and_transfers.rb`
- Modify: `app/models/spree/payment_sessions/bank_transfer.rb`, `app/models/spree/bank_payments/incoming_transfer.rb`, `app/models/spree/bank_payments/gateway.rb` (`create_payment_session`), `app/services/spree/bank_payments/ingest_transfer.rb`
- Test: `spec/services/spree/bank_payments/account_linkage_spec.rb`

**Interfaces:**
- Consumes: `BankAccount` (Task 1), `Gateway#offered_account_for` (Task 3)
- Produces: `Spree::PaymentSessions::BankTransfer#bank_account`, `IncomingTransfer#bank_account`

**Both are nullable and advisory.** A session with no account — legacy rows, or the `Manual` reconciler — must match exactly as it does today. Making it mandatory would break the shipped path.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/spree/bank_payments/account_linkage_spec.rb
require 'spec_helper'

RSpec.describe 'bank account linkage' do
  let(:gateway) { create(:bank_transfer_gateway) }
  let!(:gbp) { create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true, provider_account_id: 'acc-gbp') }
  let(:order) { create(:order_with_line_items, currency: 'GBP') }

  it 'records the quoted account on the session' do
    session = gateway.create_payment_session(order: order)

    expect(session.bank_account).to eq(gbp)
  end

  it 'resolves the arriving account on the transfer' do
    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-1', amount: 10.00, currency: 'GBP',
      reference: 'NOPE', payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: 'acc-gbp'
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer.bank_account).to eq(gbp)
  end

  # Money into the wrong account should be diagnosable, not a mystery currency
  # mismatch.
  it 'queues rather than auto-applying when the accounts disagree' do
    other = create(:bank_payments_bank_account, payment_method: gateway, currency: 'EUR',
                   offered: true, provider_account_id: 'acc-eur')
    session = gateway.create_payment_session(order: order)

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-2', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: other.provider_account_id
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_unmatched
  end

  it 'still auto-applies when the session has no recorded account' do
    session = gateway.create_payment_session(order: order)
    session.update!(bank_account_id: nil)

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-3', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: nil
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_applied
  end

  # Offered and watched are independent: this is what makes switching accounts
  # safe for orders already in flight.
  it 'auto-applies a transfer into a watched but no-longer-offered account' do
    session = gateway.create_payment_session(order: order)
    gbp.update!(offered: false)

    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: 'TX-4', amount: session.amount, currency: 'GBP',
      reference: session.reference, payer_name: 'Jane', occurred_at: Time.current, raw: {},
      provider_account_id: 'acc-gbp'
    )

    transfer = Spree::BankPayments::IngestTransfer.new(payment_method: gateway, transfer_data: data).call

    expect(transfer).to be_applied
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/spree/bank_payments/account_linkage_spec.rb`
Expected: FAIL — `bank_account` undefined, and `TransferData` rejects `provider_account_id`

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260817000002_add_bank_account_id_to_sessions_and_transfers.rb
class AddBankAccountIdToSessionsAndTransfers < ActiveRecord::Migration[8.1]
  def change
    add_column :spree_bank_payments_incoming_transfers, :bank_account_id, :bigint
    add_index  :spree_bank_payments_incoming_transfers, :bank_account_id,
               name: 'index_bp_transfers_on_bank_account_id'

    # Same precedent as external_id_normalized: a nullable column on a Spree
    # core table, indexed only for this gem's STI type.
    add_column :spree_payment_sessions, :bank_account_id, :bigint
    add_index  :spree_payment_sessions, :bank_account_id,
               where: "type = 'Spree::PaymentSessions::BankTransfer'",
               name: 'index_payment_sessions_on_bank_account_id'
  end
end
```

- [ ] **Step 4: Wire the models and services**

`app/models/spree/payment_sessions/bank_transfer.rb` — add:

```ruby
      belongs_to :bank_account,
                 class_name: 'Spree::BankPayments::BankAccount',
                 optional: true
```

`app/models/spree/bank_payments/incoming_transfer.rb` — add the same association.

`Gateway#create_payment_session` — set the account when creating the session, immediately after the `ApplyDiscount.call` line and before reading the amount:

```ruby
        account = offered_account_for(order.currency)
```

and pass `bank_account_id: account&.id` into the `create!` call.

`IngestTransfer#find_or_create_transfer` — resolve the arriving account into `create_with`:

```ruby
          bank_account_id: arriving_bank_account&.id,
```

with:

```ruby
      # Watched, not offered: a transfer into an account the merchant has since
      # stopped offering must still reconcile, or switching accounts would
      # strand orders already in flight.
      def arriving_bank_account
        return nil if data.provider_account_id.blank?

        @arriving_bank_account ||= payment_method.bank_accounts.active.
          find_by(provider_account_id: data.provider_account_id)
      end
```

`IngestTransfer#matching_session` — after the existing amount and currency guards, add:

```ruby
        # Advisory: only compare when both sides recorded an account. A legacy
        # session, or the Manual reconciler, has none and matches as before.
        if session.bank_account_id.present? && transfer.bank_account_id.present? &&
           session.bank_account_id != transfer.bank_account_id
          return nil
        end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/spree/bank_payments/account_linkage_spec.rb`
Expected: PASS (after Task 6 adds `provider_account_id` to `TransferData` — if run before, that member is rejected; run Task 6 first if so and note the ordering in your report)

- [ ] **Step 6: Commit**

```bash
git add db app spec
git commit -m "Record the bank account on sessions and incoming transfers"
```

---

### Task 6: Contract additions

**Files:**
- Create: `app/models/spree/bank_payments/account_data.rb`
- Modify: `app/models/spree/bank_payments/transfer_data.rb`, `app/models/spree/bank_payments/reconcilers/base.rb`, `app/models/spree/bank_payments/reconcilers/manual.rb`, `lib/spree/bank_payments/testing_support/reconciler_shared_examples.rb`
- Test: `spec/models/spree/bank_payments/account_data_spec.rb`, `spec/models/spree/bank_payments/reconcilers/manual_spec.rb`

**Interfaces:**
- Consumes: nothing
- Produces: `AccountData` (`provider_account_id`, `currency`, `details`); `Reconcilers::Base#sync_accounts → []`; `TransferData#provider_account_id`

**This is published API.** A provider gem written against 5.1.1 must keep working untouched — additions only, no signature changes.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/spree/bank_payments/account_data_spec.rb
require 'spec_helper'

RSpec.describe Spree::BankPayments::AccountData do
  it 'carries provider id, currency and details' do
    data = described_class.new(provider_account_id: 'acc-1', currency: 'GBP', details: [])

    expect(data.provider_account_id).to eq('acc-1')
    expect(data.currency).to eq('GBP')
    expect(data.details).to eq([])
  end

  it 'defaults details to an empty array' do
    expect(described_class.new(provider_account_id: 'acc-1', currency: 'GBP').details).to eq([])
  end
end
```

Add to `spec/models/spree/bank_payments/reconcilers/manual_spec.rb`:

```ruby
  it 'syncs no accounts' do
    expect(described_class.new(payment_method: payment_method).sync_accounts).to eq([])
  end
```

And a backward-compatibility example in `spec/models/spree/bank_payments/transfer_data_spec.rb`:

```ruby
  it 'still constructs without provider_account_id, as a 5.1.1 provider would' do
    data = described_class.new(
      provider: 'x', provider_transaction_id: 'y', amount: 1, currency: 'GBP',
      occurred_at: Time.current
    )

    expect(data.provider_account_id).to be_nil
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/spree/bank_payments/account_data_spec.rb`
Expected: FAIL with `uninitialized constant Spree::BankPayments::AccountData`

- [ ] **Step 3: Add the value object and contract method**

```ruby
# app/models/spree/bank_payments/account_data.rb
module Spree
  module BankPayments
    # One account as reported by a provider, in the gem's normalised shape.
    # The reconciler maps its provider's response into this -- the database and
    # views never see provider-specific schemas.
    AccountData = Data.define(:provider_account_id, :currency, :details) do
      def initialize(details: [], **rest)
        super(details: details, **rest)
      end
    end
  end
end
```

`TransferData` — add `:provider_account_id` to the member list and default it in the initializer:

```ruby
      def initialize(payer_name: nil, reference: nil, raw: {}, provider_account_id: nil, **rest)
        super(payer_name: payer_name, reference: reference, raw: raw,
              provider_account_id: provider_account_id, **rest)
      end
```

`Reconcilers::Base` — add:

```ruby
        # Accounts this provider can see, for the admin sync flow.
        # Providers that cannot enumerate accounts return [].
        #
        # @return [Array<Spree::BankPayments::AccountData>]
        def sync_accounts
          []
        end
```

`Reconcilers::Manual` — add an explicit `sync_accounts` returning `[]` with a comment that manual stores create accounts by hand in the admin.

Shared examples — add to `'a bank transfer reconciler'`:

```ruby
  it 'returns an array of AccountData from #sync_accounts' do
    result = reconciler.sync_accounts

    expect(result).to be_an(Array)
    expect(result).to all(be_a(Spree::BankPayments::AccountData))
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app lib spec
git commit -m "Add sync_accounts and AccountData to the reconciler contract"
```

---

### Task 7: SyncAccounts service

**Files:**
- Create: `app/services/spree/bank_payments/sync_accounts.rb`
- Test: `spec/services/spree/bank_payments/sync_accounts_spec.rb`

**Interfaces:**
- Consumes: `AccountData` (Task 6), `BankAccount` (Task 1)
- Produces: `SyncAccounts.new(payment_method:).plan → Hash`, `.apply!(plan) → void`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/spree/bank_payments/sync_accounts_spec.rb
require 'spec_helper'

RSpec.describe Spree::BankPayments::SyncAccounts do
  let(:gateway) { create(:bank_transfer_gateway) }

  def account_data(id, currency = 'GBP')
    Spree::BankPayments::AccountData.new(
      provider_account_id: id, currency: currency,
      details: [{ 'label' => 'UK', 'fields' => [{ 'label' => 'Sort code', 'value' => '04-00-75' }] }]
    )
  end

  def stub_sync(values)
    reconciler = gateway.reconciler
    allow(reconciler).to receive(:sync_accounts).and_return(values)
    allow(gateway).to receive(:reconciler).and_return(reconciler)
  end

  it 'creates new accounts, NOT offered' do
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!

    account = gateway.bank_accounts.sole
    expect(account.provider_account_id).to eq('acc-1')
    expect(account).not_to be_offered
  end

  it 'never changes offered on an existing account' do
    existing = create(:bank_payments_bank_account, payment_method: gateway,
                      provider_account_id: 'acc-1', currency: 'GBP', offered: true)
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!

    expect(existing.reload).to be_offered
  end

  it 'deactivates an account absent from the response' do
    gone = create(:bank_payments_bank_account, payment_method: gateway,
                  provider_account_id: 'acc-old', currency: 'GBP')
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!

    expect(gone.reload).not_to be_active
    expect(Spree::BankPayments::BankAccount.where(id: gone.id)).to exist
  end

  # THE guard. An auth failure returning [] must not withdraw bank transfer
  # from the storefront for every currency at once.
  it 'aborts entirely when the provider returns empty but accounts exist' do
    existing = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')
    stub_sync([])

    expect { described_class.new(payment_method: gateway).apply! }.
      to raise_error(described_class::EmptyResponseError)
    expect(existing.reload).to be_active
  end

  it 'aborts and writes nothing when the provider raises' do
    existing = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')
    reconciler = gateway.reconciler
    allow(reconciler).to receive(:sync_accounts).and_raise(StandardError, 'auth expired')
    allow(gateway).to receive(:reconciler).and_return(reconciler)

    expect { described_class.new(payment_method: gateway).apply! }.to raise_error(StandardError, 'auth expired')
    expect(existing.reload).to be_active
  end

  it 'skips an account with no usable details and reports it' do
    stub_sync([Spree::BankPayments::AccountData.new(provider_account_id: 'acc-2', currency: 'GBP', details: [])])

    plan = described_class.new(payment_method: gateway).plan

    expect(plan[:skipped].map(&:provider_account_id)).to eq(['acc-2'])
    expect { described_class.new(payment_method: gateway).apply! }.
      not_to change(Spree::BankPayments::BankAccount, :count)
  end

  # The consent-callback trigger fires while someone is mid-OAuth-redirect.
  # Additive changes cannot lose anything; a deactivation can withdraw a
  # currency from the storefront, and that must not happen without a human
  # looking at it.
  it 'skips deactivations in additive_only mode' do
    gone = create(:bank_payments_bank_account, payment_method: gateway,
                  provider_account_id: 'acc-old', currency: 'GBP')
    stub_sync([account_data('acc-1')])

    described_class.new(payment_method: gateway).apply!(additive_only: true)

    expect(gone.reload).to be_active
    expect(gateway.bank_accounts.find_by(provider_account_id: 'acc-1')).to be_present
  end

  it 'never touches bank_account_id on existing sessions' do
    account = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1', offered: true)
    order = create(:order_with_line_items, currency: 'GBP')
    session = gateway.create_payment_session(order: order)
    stub_sync([account_data('acc-1')])

    expect { described_class.new(payment_method: gateway).apply! }.
      not_to change { session.reload.bank_account_id }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/spree/bank_payments/sync_accounts_spec.rb`
Expected: FAIL with `uninitialized constant Spree::BankPayments::SyncAccounts`

- [ ] **Step 3: Write the service**

```ruby
# app/services/spree/bank_payments/sync_accounts.rb
module Spree
  module BankPayments
    # Reconciles provider-reported accounts against BankAccount rows.
    #
    # Never sets `offered` -- that is the admin's checklist -- and never touches
    # bank_account_id on existing sessions: historical quotes are immutable,
    # because changing what a customer was told after the fact makes a dispute
    # unwinnable.
    class SyncAccounts
      class EmptyResponseError < StandardError; end

      def initialize(payment_method:)
        @payment_method = payment_method
      end

      # @return [Hash] :create, :update, :deactivate, :skipped
      def plan
        reported = payment_method.reconciler.sync_accounts
        existing = payment_method.bank_accounts.to_a

        # An auth failure that returns [] must not be read as "every account
        # disappeared" -- that would deactivate them all in one pass and
        # silently withdraw bank transfer from the storefront.
        raise EmptyResponseError, 'provider reported no accounts' if reported.empty? && existing.any?

        usable, skipped = reported.partition { |a| usable?(a) }
        seen = usable.map(&:provider_account_id)
        by_id = existing.index_by(&:provider_account_id)

        {
          create: usable.reject { |a| by_id.key?(a.provider_account_id) },
          update: usable.select { |a| by_id.key?(a.provider_account_id) },
          deactivate: existing.select { |a| a.provider_account_id.present? && seen.exclude?(a.provider_account_id) },
          skipped: skipped
        }
      end

      # @param additive_only [Boolean] skip deactivations. Used by the consent
      #   re-approval trigger, which fires mid-OAuth-redirect: creating and
      #   refreshing accounts is always safe, but withdrawing a currency from
      #   the storefront needs a human looking at a diff.
      def apply!(prepared = nil, additive_only: false)
        prepared ||= plan

        ActiveRecord::Base.transaction do
          prepared[:create].each do |data|
            payment_method.bank_accounts.create!(
              provider_account_id: data.provider_account_id,
              currency: data.currency,
              details: data.details,
              offered: false,
              active: true,
              synced_at: Time.current
            )
          end

          prepared[:update].each do |data|
            account = payment_method.bank_accounts.find_by(provider_account_id: data.provider_account_id)
            account.update!(currency: data.currency, details: data.details,
                            active: true, synced_at: Time.current)
          end

          # Deactivate, never delete: sessions quoted against a retired account
          # must still render what the customer was told.
          unless additive_only
            prepared[:deactivate].each { |account| account.update!(active: false) }
          end
        end
      end

      private

      attr_reader :payment_method

      def usable?(data)
        Array(data.details).any? { |raw| DetailSet.new(raw).usable? }
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/spree/bank_payments/sync_accounts_spec.rb`
Expected: PASS

- [ ] **Step 5: Mutation-test the guard**

Delete the `raise EmptyResponseError` line and re-run. The "aborts entirely when the provider returns empty" example must turn red. Restore, confirm green, and report what you saw. This guard is three lines and its absence is the most consequential failure in this flow.

- [ ] **Step 6: Commit**

```bash
git add app spec
git commit -m "Add SyncAccounts with an abort guard on empty provider responses"
```

---

### Task 8: Render every detail set

**Files:**
- Modify: `app/views/spree/bank_payments/_order_instructions.html.erb`, `app/views/spree/bank_payments/instructions_mailer/instructions.html.erb`, `app/views/spree/bank_payments/instructions_mailer/reminder.html.erb`
- Test: `spec/views/spree/bank_payments/order_instructions_spec.rb`

**Interfaces:**
- Consumes: `Gateway#bank_details_for` (Task 3), `DetailSet` (Task 2)
- Produces: nothing

- [ ] **Step 1: Write the failing test**

```ruby
# add to spec/views/spree/bank_payments/order_instructions_spec.rb
  it 'renders every detail set, labelled' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

    render partial: 'spree/bank_payments/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include('UK payments')
    expect(rendered).to include('International')
    expect(rendered).to include('04-00-75')
    expect(rendered).to include('GB00REVO00000000000000')
  end

  it 'renders coordinate labels the view has never seen' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true,
           details: [{ 'label' => 'Local', 'fields' => [{ 'label' => 'Elixir number', 'value' => '99887766' }] }])

    render partial: 'spree/bank_payments/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include('Elixir number')
    expect(rendered).to include('99887766')
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/views/spree/bank_payments/order_instructions_spec.rb`
Expected: FAIL — the partial still reads the old `bank_details` hash

- [ ] **Step 3: Update the partial**

Replace the `bank_details` lookup and the `<dl>` block with:

```erb
<% detail_sets = payment_session.payment_method.bank_details_for(payment_session.currency) %>

<% detail_sets.each do |set| %>
  <div class="bank-transfer-instructions__account">
    <% if set.label.present? %>
      <h3><%= set.label %></h3>
    <% end %>

    <dl>
      <% if set.beneficiary_name.present? %>
        <dt><%= Spree.t('bank_payments.beneficiary') %></dt>
        <dd><%= set.beneficiary_name %></dd>
      <% end %>

      <%# Label/value pairs, rendered generically: bank coordinates are not
          standardised across countries, so the view must never assume which
          fields exist. %>
      <% set.fields.each do |label, value| %>
        <dt><%= label %></dt>
        <dd><%= value %></dd>
      <% end %>
    </dl>
  </div>
<% end %>
```

Apply the same change to both mailer templates. Add the `bank_payments.beneficiary` key to `config/locales/en.yml`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/views`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app config spec
git commit -m "Render every detail set generically in instructions and emails"
```

---

### Task 9: Admin — checklist and manual CRUD

**Files:**
- Create: `app/controllers/spree/admin/bank_accounts_controller.rb`, `app/views/spree/admin/bank_accounts/index.html.erb`, `app/views/spree/admin/bank_accounts/_form.html.erb`
- Modify: `config/routes.rb`, `app/views/spree/admin/payment_methods/configuration_guides/_spree_bank_payments.html.erb`
- Test: `spec/controllers/spree/admin/bank_accounts_controller_spec.rb`

**Interfaces:**
- Consumes: `BankAccount` (Task 1), `SyncAccounts` (Task 7)
- Produces: routes `admin_payment_method_bank_accounts_path`, member `toggle_offered`, collection `sync`

**Manual CRUD is required, not optional.** `Manual` is the default reconciler and the only one core ships; without hand entry, a core-only store has no way to tell customers where to pay.

- [ ] **Step 1: Write the failing test**

```ruby
# spec/controllers/spree/admin/bank_accounts_controller_spec.rb
require 'spec_helper'

RSpec.describe Spree::Admin::BankAccountsController, type: :controller do
  stub_authorization!

  let(:gateway) { create(:bank_transfer_gateway) }

  it 'lists accounts for the payment method' do
    account = create(:bank_payments_bank_account, payment_method: gateway)

    get :index, params: { payment_method_id: gateway.id }

    expect(assigns(:bank_accounts)).to include(account)
  end

  it 'offers an account and unoffers the previous one for that currency' do
    old = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: true, provider_account_id: 'a')
    new_account = create(:bank_payments_bank_account, payment_method: gateway, currency: 'GBP', offered: false, provider_account_id: 'b')

    put :toggle_offered, params: { payment_method_id: gateway.id, id: new_account.id }

    expect(new_account.reload).to be_offered
    expect(old.reload).not_to be_offered
  end

  it 'creates a hand-entered account' do
    expect {
      post :create, params: {
        payment_method_id: gateway.id,
        bank_account: {
          currency: 'EUR', offered: '1',
          details: [{ label: 'SEPA', fields: [{ label: 'IBAN', value: 'DE00' }] }].to_json
        }
      }
    }.to change(Spree::BankPayments::BankAccount, :count).by(1)
  end

  it 'refuses to edit details on a synced account' do
    synced = create(:bank_payments_bank_account, payment_method: gateway, provider_account_id: 'acc-1')

    put :update, params: { payment_method_id: gateway.id, id: synced.id,
                           bank_account: { details: [].to_json } }

    expect(synced.reload.details).to be_present
    expect(flash[:error]).to be_present
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/controllers/spree/admin/bank_accounts_controller_spec.rb`
Expected: FAIL with `uninitialized constant Spree::Admin::BankAccountsController`

- [ ] **Step 3: Add routes**

In `config/routes.rb`, inside the existing `Spree::Core::Engine.add_routes` admin namespace:

```ruby
    resources :payment_methods, only: [] do
      resources :bank_accounts, only: %i[index new create edit update destroy] do
        member { put :toggle_offered }
        collection { post :sync }
      end
    end
```

- [ ] **Step 4: Write the controller**

```ruby
# app/controllers/spree/admin/bank_accounts_controller.rb
module Spree
  module Admin
    class BankAccountsController < Spree::Admin::BaseController
      before_action :load_payment_method
      before_action :load_bank_account, only: %i[edit update destroy toggle_offered]

      def index
        @bank_accounts = @payment_method.bank_accounts.order(:currency, :id)
      end

      def new
        @bank_account = @payment_method.bank_accounts.new
      end

      def create
        @bank_account = @payment_method.bank_accounts.new(bank_account_params)

        if @bank_account.save
          redirect_to_index 'Bank account created.'
        else
          render :new
        end
      end

      def edit; end

      def update
        # Synced accounts are the provider's record, not ours -- editing their
        # details here would silently diverge from the account actually watched.
        if @bank_account.synced? && bank_account_params.key?(:details)
          flash[:error] = 'Synced accounts cannot be edited. Re-sync to refresh them.'
          return redirect_to_index
        end

        if @bank_account.update(bank_account_params)
          redirect_to_index 'Bank account updated.'
        else
          render :edit
        end
      end

      def destroy
        if @bank_account.synced?
          flash[:error] = 'Synced accounts cannot be deleted. Deactivate instead.'
        else
          @bank_account.destroy
        end

        redirect_to_index
      end

      def toggle_offered
        Spree::BankPayments::BankAccount.transaction do
          @payment_method.bank_accounts.
            for_currency(@bank_account.currency).offered.
            where.not(id: @bank_account.id).
            update_all(offered: false)

          @bank_account.update!(offered: !@bank_account.offered?)
        end

        redirect_to_index
      end

      def sync
        Spree::BankPayments::SyncAccounts.new(payment_method: @payment_method).apply!
        redirect_to_index 'Accounts synced.'
      rescue Spree::BankPayments::SyncAccounts::EmptyResponseError, StandardError => e
        flash[:error] = "Sync failed: #{e.message}. No accounts were changed."
        redirect_to_index
      end

      private

      def load_payment_method
        @payment_method = Spree::BankPayments::Gateway.find(params[:payment_method_id])
      end

      def load_bank_account
        @bank_account = @payment_method.bank_accounts.find(params[:id])
      end

      def redirect_to_index(notice = nil)
        flash[:success] = notice if notice
        redirect_to spree.admin_payment_method_bank_accounts_path(@payment_method)
      end

      def bank_account_params
        permitted = params.require(:bank_account).permit(:currency, :offered, :active, :details)
        permitted[:details] = JSON.parse(permitted[:details]) if permitted[:details].is_a?(String)
        permitted
      end
    end
  end
end
```

- [ ] **Step 5: Write the views**

```erb
<%# app/views/spree/admin/bank_accounts/index.html.erb %>
<h1>Bank accounts — <%= @payment_method.name %></h1>

<% if @bank_accounts.none?(&:offered?) %>
  <div class="alert alert-warning">
    No account is offered yet — bank transfer is unavailable to customers
    until you choose one per currency.
  </div>
<% end %>

<p>
  <%= link_to 'Add account', spree.new_admin_payment_method_bank_account_path(@payment_method),
              class: 'btn btn-primary' %>

  <% if @payment_method.preferred_reconciler != 'manual' %>
    <%= button_to 'Sync from provider',
                  spree.sync_admin_payment_method_bank_accounts_path(@payment_method),
                  method: :post, class: 'btn btn-secondary' %>
  <% end %>
</p>

<table class="table">
  <thead>
    <tr><th>Currency</th><th>Account</th><th>Source</th><th>Offered</th><th>Active</th><th></th></tr>
  </thead>
  <tbody>
    <% @bank_accounts.each do |account| %>
      <tr>
        <td><%= account.currency %></td>
        <td>
          <% account.detail_sets.each do |set| %>
            <div><strong><%= set.label %></strong>
              <%= set.fields.map { |label, value| "#{label} #{value}" }.join(' · ') %></div>
          <% end %>
        </td>
        <td><%= account.synced? ? "Synced #{l(account.synced_at, format: :short) if account.synced_at}" : 'Manual' %></td>
        <td>
          <%= button_to account.offered? ? 'Offered' : 'Offer',
                        spree.toggle_offered_admin_payment_method_bank_account_path(@payment_method, account),
                        method: :put,
                        class: account.offered? ? 'btn btn-sm btn-success' : 'btn btn-sm btn-outline-secondary' %>
        </td>
        <td><%= account.active? ? 'Yes' : 'No' %></td>
        <td>
          <% unless account.synced? %>
            <%= link_to 'Edit', spree.edit_admin_payment_method_bank_account_path(@payment_method, account) %>
          <% end %>
        </td>
      </tr>
    <% end %>
  </tbody>
</table>
```

```erb
<%# app/views/spree/admin/bank_accounts/_form.html.erb -- hand-created accounts only %>
<%= form_with model: @bank_account,
              url: @bank_account.persisted? ?
                spree.admin_payment_method_bank_account_path(@payment_method, @bank_account) :
                spree.admin_payment_method_bank_accounts_path(@payment_method) do |f| %>
  <% if @bank_account.errors.any? %>
    <div class="alert alert-danger"><%= @bank_account.errors.full_messages.to_sentence %></div>
  <% end %>

  <div class="form-group">
    <%= f.label :currency %>
    <%= f.text_field :currency, class: 'form-control', maxlength: 3 %>
  </div>

  <div class="form-group">
    <%= f.label :details, 'Detail sets (JSON)' %>
    <%# Ordered label/value pairs, because bank coordinates are not
        standardised across countries. %>
    <%= f.text_area :details, value: @bank_account.details.to_json, rows: 12, class: 'form-control' %>
    <small class="form-text text-muted">
      <code>[{"label":"UK payments","schemes":["faster"],"fields":[{"label":"Sort code","value":"04-00-75"}]}]</code>
    </small>
  </div>

  <%= f.submit 'Save', class: 'btn btn-primary' %>
<% end %>
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec rspec spec/controllers/spree/admin/bank_accounts_controller_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add app config spec
git commit -m "Add admin bank account checklist and manual CRUD"
```

---

### Task 10: Documentation and release

**Files:**
- Modify: `README.md`, `CHANGELOG.md`, `lib/spree/bank_payments/version.rb`, `docs/design-spec.md`

**Interfaces:**
- Consumes: everything
- Produces: nothing

- [ ] **Step 1: Update the README**

Document: configuring accounts per currency; that customers see every detail set and choose local or international themselves; that the admin checklist offers one account per currency; that **every synced account stays watched, so switching accounts does not strand orders in flight**; the sync triggers; and that a currency with no offered account means bank transfer is not available for that currency.

Add a provider-authors note that `sync_accounts` returns `Array<AccountData>` with `details` in the normalised shape, and that both shared example groups must be run.

- [ ] **Step 2: Update the CHANGELOG**

New `## 5.2.0` section covering the feature, the deprecation of `#bank_details`, the legacy preference migration, and the contract additions with an explicit note that a 5.1.1 provider gem keeps working.

- [ ] **Step 3: Bump the version**

`lib/spree/bank_payments/version.rb` → `5.2.0`.

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rspec` with `timeout: 600000`
Expected: 0 failures. Report the example count.

- [ ] **Step 5: Verify a clean-room rebuild**

Run: `rm -rf spec/dummy && bundle exec rake test_app && bundle exec rspec`
Expected: all three new migrations apply in order on a fresh database with no manual steps.

- [ ] **Step 6: Commit**

```bash
git add README.md CHANGELOG.md lib docs
git commit -m "Document multi-currency accounts and bump to 5.2.0"
```

---

## Definition of done

- [ ] `bundle exec rspec` green from a clean-room `rake test_app`
- [ ] A store with GBP and EUR accounts quotes the right one per order currency
- [ ] Every detail set renders, including labels the view has never seen
- [ ] The switch scenario passes end to end: quote against GBP-A, offer B instead, a transfer into A still auto-applies and a new session quotes B
- [ ] An empty or failing sync leaves every account untouched — mutation-tested
- [ ] The database rejects a second offered account for one currency
- [ ] A currency with no offered account removes the method from checkout
- [ ] Legacy flat preferences migrate to one offered account and quote identically
- [ ] `#bank_details` still responds, deprecated
- [ ] A `TransferData` constructed without `provider_account_id` still works
