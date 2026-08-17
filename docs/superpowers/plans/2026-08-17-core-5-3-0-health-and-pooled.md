# Core 5.3.0 — Reconciler Health and Pooled Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the reconciler contract a three-state health signal, log health transitions from core so any provider is alertable without reinventing it, and carry a `pooled` flag on bank accounts.

**Architecture:** `Reconcilers::Base` grows `#health` returning `:ok`, `:transient` or `:consent_revoked`, with `#healthy?` and `#health` each deriving from whichever the provider overrode. `ReconcilerState` persists the last reported status so `Gateway#health` — which is called on the checkout hot path — never makes a network call. A `HealthReporter` service owns the log line and the `Spree::Events` publication, logging on transition and at most hourly thereafter. `pooled` is a plain boolean carried from `AccountData` through `SyncAccounts` to `BankAccount`.

**Tech Stack:** Ruby, Rails engine, RSpec, PostgreSQL only (jsonb and partial unique indexes are load-bearing).

**Spec:** `docs/revolut-provider-design.md`, Part A.

## Global Constraints

- Target version is `5.3.0`. `lib/spree/bank_payments/version.rb` holds `VERSION`.
- **Backward compatibility is the hard gate:** a reconciler written against 5.1.1 or 5.2.0, overriding only `#healthy?`, must keep working with no changes. Task 1 has a spec that proves this.
- **`available_for_order?` must never make a network call.** It runs on every checkout render. It reads persisted state only.
- **`reason` is drawn from a fixed enum and is never interpolated from an exception message or a response body.** That is how a bearer token reaches a log aggregator. `ReconcilerState#last_error` continues to store exception text in the database; that is a different field with a different audience.
- Migrations are numbered after the highest existing, `20260817000006`.
- PostgreSQL only. Do not add SQLite fallbacks.
- Run the suite with `bundle exec rspec`. `ENV['DB']` defaults to `postgres`.
- Commits are signed. Never pass `--no-gpg-sign`. End each commit message with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility |
|---|---|
| `app/models/spree/bank_payments/reconcilers/base.rb` | Adds `#health`; makes `#healthy?` derive from it without mutual recursion. |
| `app/models/spree/bank_payments/reconcilers/manual.rb` | Returns `:ok`. |
| `lib/spree/bank_payments/testing_support/reconciler_shared_examples.rb` | Asserts `#health` returns a member of the enum. |
| `db/migrate/20260817000007_add_health_to_reconciler_states.rb` | `health_status`, `health_reason`, `health_reported_at`. |
| `app/models/spree/bank_payments/reconciler_state.rb` | Persists the reported health; unchanged `#healthy?(interval)`. |
| `app/services/spree/bank_payments/health_reporter.rb` | Transition detection, log line, event publication. **New.** |
| `app/jobs/spree/bank_payments/poll_job.rb` | Calls the reporter with the live result. |
| `app/models/spree/bank_payments/gateway.rb` | `#health` (persisted read); `available_for_order?` withdraws on `:consent_revoked`. |
| `db/migrate/20260817000008_add_pooled_to_bank_accounts.rb` | `pooled` boolean. |
| `app/models/spree/bank_payments/account_data.rb` | Carries `pooled:`, default `false`. |
| `app/services/spree/bank_payments/sync_accounts.rb` | Writes `pooled` on create and update. |

---

### Task 1: Three-state `#health` on the reconciler contract

**Files:**
- Modify: `app/models/spree/bank_payments/reconcilers/base.rb:44-52`
- Modify: `app/models/spree/bank_payments/reconcilers/manual.rb`
- Modify: `lib/spree/bank_payments/testing_support/reconciler_shared_examples.rb:29-35`
- Test: `spec/models/spree/bank_payments/reconcilers/health_contract_spec.rb` (create)

**Interfaces:**
- Produces: `Reconcilers::Base::HEALTH_STATES` = `%i[ok transient consent_revoked].freeze`; `Reconcilers::Base#health` returning one of those symbols; `#healthy?` returning `health == :ok`.

- [ ] **Step 1: Write the failing test**

Create `spec/models/spree/bank_payments/reconcilers/health_contract_spec.rb`:

```ruby
require 'spec_helper'

RSpec.describe Spree::BankPayments::Reconcilers::Base do
  let(:payment_method) { create(:bank_transfer_gateway) }

  # A provider gem written against 5.1.1 or 5.2.0 overrides #healthy? and has
  # never heard of #health. It must keep working untouched -- this is the
  # whole backward-compatibility promise of 5.3.0.
  describe 'a legacy reconciler that implements only #healthy?' do
    let(:klass) do
      Class.new(described_class) do
        def healthy? = false
      end
    end

    it 'derives :transient from a false #healthy?' do
      expect(klass.new(payment_method: payment_method).health).to eq(:transient)
    end

    it 'derives :ok from a true #healthy?' do
      healthy = Class.new(described_class) { def healthy? = true }
      expect(healthy.new(payment_method: payment_method).health).to eq(:ok)
    end
  end

  describe 'a 5.3 reconciler that implements only #health' do
    let(:klass) do
      Class.new(described_class) do
        def health = :consent_revoked
      end
    end

    it 'derives #healthy? from #health' do
      expect(klass.new(payment_method: payment_method).healthy?).to be(false)
    end

    it 'reports :ok as healthy' do
      ok = Class.new(described_class) { def health = :ok }
      expect(ok.new(payment_method: payment_method).healthy?).to be(true)
    end
  end

  # Neither overridden is a contract violation. It must say so, not recurse
  # until the stack blows -- the two defaults are defined in terms of each
  # other, so an unguarded pair would SystemStackError.
  describe 'a reconciler that implements neither' do
    let(:klass) { Class.new(described_class) }

    it 'raises NotImplementedError rather than recursing' do
      expect { klass.new(payment_method: payment_method).healthy? }.
        to raise_error(NotImplementedError, /must implement/)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/models/spree/bank_payments/reconcilers/health_contract_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'health'`.

- [ ] **Step 3: Implement**

In `app/models/spree/bank_payments/reconcilers/base.rb`, replace the `#healthy?` definition (lines 44-47) with:

```ruby
        HEALTH_STATES = %i[ok transient consent_revoked].freeze

        # @return [Symbol] one of HEALTH_STATES.
        #
        # :transient still offers at checkout -- a brief provider outage must
        # not pull bank transfer off the storefront, because the money still
        # arrives and reconciles once the provider returns. Only
        # :consent_revoked withdraws it, because in that state nothing will
        # ever reconcile.
        #
        # Providers written against <= 5.2 implement #healthy? only, so the
        # default derives from it.
        def health
          healthy? ? :ok : :transient
        end

        # @return [Boolean] false means the expiry job must not cancel anything
        #
        # Providers written against >= 5.3 may implement #health only, so the
        # default derives from it. The two defaults are mutually recursive by
        # construction; the owner check breaks the cycle and turns "overrode
        # neither" into a clear contract error instead of a SystemStackError.
        def healthy?
          if method(:health).owner == Spree::BankPayments::Reconcilers::Base
            raise NotImplementedError, "#{self.class} must implement #health or #healthy?"
          end

          health == :ok
        end
```

In `app/models/spree/bank_payments/reconcilers/manual.rb`, replace `def healthy?` with:

```ruby
        # The manual reconciler never talks to anything, so it cannot be
        # unhealthy.
        def health
          :ok
        end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/reconcilers/ spec/models/spree/bank_payments/gateway_health_spec.rb`
Expected: PASS.

- [ ] **Step 5: Extend the shared examples**

In `lib/spree/bank_payments/testing_support/reconciler_shared_examples.rb`, replace the `#healthy?` example (lines 29-31) with:

```ruby
  it 'answers #healthy? with a boolean' do
    expect([true, false]).to include(reconciler.healthy?)
  end

  it 'answers #health with a member of the published enum' do
    expect(Spree::BankPayments::Reconcilers::Base::HEALTH_STATES).to include(reconciler.health)
  end
```

- [ ] **Step 6: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS, 288 + 5 examples, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add app/models/spree/bank_payments/reconcilers lib/spree/bank_payments/testing_support spec/models/spree/bank_payments/reconcilers
git commit -m "Give reconciler health three states instead of two

A boolean cannot separate a retryable provider outage from a dead OAuth
consent, and those need different humans on different timescales. Conflating
them means a store either silently stops reconciling or silently stops
accepting bank transfers, with nothing to say which.

The two defaults derive from each other so a provider can override either one,
which makes them mutually recursive by construction. The owner check breaks the
cycle and turns 'overrode neither' into a contract error rather than a
SystemStackError.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Persist reported health on `ReconcilerState`

**Files:**
- Create: `db/migrate/20260817000007_add_health_to_reconciler_states.rb`
- Modify: `app/models/spree/bank_payments/reconciler_state.rb`
- Test: `spec/models/spree/bank_payments/reconciler_state_spec.rb` (append)

**Interfaces:**
- Consumes: `HEALTH_STATES` from Task 1.
- Produces: `ReconcilerState#health_status` (string), `#health_reason` (string), `#health_reported_at` (datetime); `#record_health!(status:, reason:, logged:)`.

- [ ] **Step 1: Write the failing test**

Append to `spec/models/spree/bank_payments/reconciler_state_spec.rb`:

```ruby
  describe '#record_health!' do
    let(:payment_method) { create(:bank_transfer_gateway) }
    let(:state) { payment_method.reconciler_state }

    it 'stores the status and reason as strings' do
      state.record_health!(status: :consent_revoked, reason: :consent_revoked, logged: true)

      expect(state.reload.health_status).to eq('consent_revoked')
      expect(state.health_reason).to eq('consent_revoked')
    end

    # health_reported_at means "when we last LOGGED this", not "when we last
    # observed it" -- the hourly re-log window is measured from it. Bumping it
    # on every silent observation would push the next re-log out forever and a
    # sustained outage would be logged exactly once.
    it 'only advances health_reported_at when the report was logged' do
      state.record_health!(status: :transient, reason: :provider_error, logged: true)
      first = state.reload.health_reported_at

      state.record_health!(status: :transient, reason: :provider_error, logged: false)

      expect(state.reload.health_reported_at).to eq(first)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/models/spree/bank_payments/reconciler_state_spec.rb -e record_health`
Expected: FAIL — `NoMethodError: undefined method 'record_health!'`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260817000007_add_health_to_reconciler_states.rb`:

```ruby
class AddHealthToReconcilerStates < ActiveRecord::Migration[7.2]
  def change
    add_column :spree_bank_payments_reconciler_states, :health_status, :string
    add_column :spree_bank_payments_reconciler_states, :health_reason, :string
    add_column :spree_bank_payments_reconciler_states, :health_reported_at, :datetime
  end
end
```

- [ ] **Step 4: Implement the model method**

Append to `app/models/spree/bank_payments/reconciler_state.rb`, inside the class:

```ruby
      # @param status [Symbol] a member of Reconcilers::Base::HEALTH_STATES
      # @param reason [Symbol] a member of HealthReporter::REASONS
      # @param logged [Boolean] whether this report was actually emitted
      def record_health!(status:, reason:, logged:)
        attrs = { health_status: status.to_s, health_reason: reason.to_s }
        attrs[:health_reported_at] = Time.current if logged

        update!(attrs)
      end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rake test_app && bundle exec rspec spec/models/spree/bank_payments/reconciler_state_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate app/models/spree/bank_payments/reconciler_state.rb spec/models/spree/bank_payments/reconciler_state_spec.rb
git commit -m "Persist the last reported reconciler health

health_reported_at records when a status was last logged, not when it was last
observed. The hourly re-log window is measured from it, so bumping it on silent
observations would push the next re-log out indefinitely and a sustained outage
would be logged exactly once.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `HealthReporter`

**Files:**
- Create: `app/services/spree/bank_payments/health_reporter.rb`
- Test: `spec/services/spree/bank_payments/health_reporter_spec.rb` (create)

**Interfaces:**
- Consumes: `ReconcilerState#record_health!` from Task 2.
- Produces: `HealthReporter::REASONS`; `HealthReporter.call(payment_method:, status:, reason:) -> Boolean` (true when it logged).

> **Event names here were updated during the pre-merge review.** This plan was
> written against `bank_payments.reconciler.unhealthy` / `.recovered`; the
> whole-branch review renamed them to
> `bank_transfer.reconciler_health.unhealthy` / `.recovered` before merge, so
> that the `Spree::Events.subscribe('bank_transfer.*', …)` wildcard the README
> documents actually catches them. The names below — in both the `publish(…)`
> calls and the `event=` key inside the log lines, since alert rules key on the
> log — are what shipped.

- [ ] **Step 1: Write the failing test**

Create `spec/services/spree/bank_payments/health_reporter_spec.rb`:

```ruby
require 'spec_helper'

RSpec.describe Spree::BankPayments::HealthReporter do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:logger) { instance_spy(ActiveSupport::Logger) }

  before { allow(Rails).to receive(:logger).and_return(logger) }

  def report(status, reason)
    described_class.call(payment_method: payment_method, status: status, reason: reason)
  end

  it 'logs a transition into an unhealthy state at WARN' do
    expect(report(:transient, :provider_error)).to be(true)
    expect(logger).to have_received(:warn).with(/event=bank_transfer\.reconciler_health\.unhealthy/)
  end

  it 'logs a revoked consent at ERROR, because it needs a human not a retry' do
    report(:consent_revoked, :consent_revoked)

    expect(logger).to have_received(:error).with(/reason=consent_revoked/)
  end

  # A five-minute poll against a dead consent would otherwise write ~288
  # identical lines a day and bury the recovery line.
  it 'does not re-log an unchanged status within the hour' do
    report(:transient, :provider_error)
    expect(report(:transient, :provider_error)).to be(false)
  end

  it 're-logs once the hour has elapsed, so a window-based alert still fires' do
    report(:transient, :provider_error)
    payment_method.reconciler_state.update!(health_reported_at: 2.hours.ago)

    expect(report(:transient, :provider_error)).to be(true)
  end

  it 'logs recovery at INFO and publishes a recovered event' do
    report(:transient, :provider_error)
    allow(Spree::Events).to receive(:publish)

    expect(report(:ok, :ok)).to be(true)
    expect(logger).to have_received(:info).with(/event=bank_transfer\.reconciler_health\.recovered/)
    expect(Spree::Events).to have_received(:publish).with('bank_transfer.reconciler_health.recovered', hash_including(payment_method_id: payment_method.id))
  end

  it 'stays silent while healthy' do
    report(:ok, :ok)

    expect(report(:ok, :ok)).to be(false)
  end

  # The whole point of the enum. An exception message can carry a bearer token,
  # a signed URL, or a customer's name straight into Loki.
  it 'refuses a reason outside the published enum' do
    report(:transient, 'Bearer oa_prod_hunter2 rejected by upstream')

    expect(logger).to have_received(:warn).with(/reason=unknown/)
    expect(logger).not_to have_received(:warn).with(/hunter2/)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/services/spree/bank_payments/health_reporter_spec.rb`
Expected: FAIL — `NameError: uninitialized constant Spree::BankPayments::HealthReporter`.

- [ ] **Step 3: Implement**

Create `app/services/spree/bank_payments/health_reporter.rb`:

```ruby
module Spree
  module BankPayments
    # Owns the health log line and its event, for every provider.
    #
    # This lives in core rather than in each provider gem on purpose: health
    # already gates checkout and the expiry job, so if providers each logged
    # their own way, every new provider would reinvent it and every downstream
    # alert rule would need another clause.
    class HealthReporter
      RELOG_AFTER = 1.hour

      # A closed set. A provider hands us one of these symbols; anything else
      # becomes :unknown. Reasons are NEVER built from an exception message or
      # a response body -- that is how a bearer token reaches a log aggregator.
      #
      # Trimmed from nine values to four by the pre-merge review: the other five
      # (provider_unreachable, rate_limited, not_configured, stale_polling,
      # credentials_invalid) had no producer and no provider-facing hook to
      # become one. Widening a published enum later is non-breaking; narrowing
      # it is not, so shipping only what core can emit was the cheap choice
      # while nothing had shipped.
      REASONS = %i[ok provider_error consent_revoked unknown].freeze

      def self.call(payment_method:, status:, reason:)
        new(payment_method: payment_method, status: status, reason: reason).call
      end

      def initialize(payment_method:, status:, reason:)
        @payment_method = payment_method
        @status = status.to_sym
        @reason = REASONS.include?(reason.to_s.to_sym) ? reason.to_s.to_sym : :unknown
      end

      def call
        logged = should_log?
        emit if logged
        state.record_health!(status: status, reason: reason, logged: logged)
        logged
      end

      private

      attr_reader :payment_method, :status, :reason

      def state
        @state ||= payment_method.reconciler_state
      end

      def previous
        @previous ||= state.health_status.presence&.to_sym
      end

      def changed?
        previous != status
      end

      def due?
        state.health_reported_at.nil? || state.health_reported_at < RELOG_AFTER.ago
      end

      def should_log?
        return changed? if status == :ok

        changed? || due?
      end

      def emit
        status == :ok ? emit_recovered : emit_unhealthy
      end

      def emit_unhealthy
        severity = status == :consent_revoked ? :error : :warn

        Rails.logger.public_send(severity, <<~LINE.squish)
          [spree-bank_payments] reconciler unhealthy
          event=bank_transfer.reconciler_health.unhealthy
          reconciler=#{payment_method.preferred_reconciler}
          payment_method_id=#{payment_method.id}
          status=#{status}
          reason=#{reason}
          consecutive_failures=#{state.consecutive_failures}
          last_success_at=#{state.last_successful_run_at&.iso8601 || 'never'}
        LINE

        publish('bank_transfer.reconciler_health.unhealthy')
      end

      def emit_recovered
        Rails.logger.info(<<~LINE.squish)
          [spree-bank_payments] reconciler recovered
          event=bank_transfer.reconciler_health.recovered
          reconciler=#{payment_method.preferred_reconciler}
          payment_method_id=#{payment_method.id}
          previous_status=#{previous}
        LINE

        publish('bank_transfer.reconciler_health.recovered')
      end

      # Serializable primitives only: subscribers run async through ActiveJob
      # and an ActiveRecord object cannot survive the trip.
      def publish(event)
        Spree::Events.publish(event,
                              payment_method_id: payment_method.id,
                              reconciler: payment_method.preferred_reconciler.to_s,
                              status: status.to_s,
                              reason: reason.to_s,
                              consecutive_failures: state.consecutive_failures)
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/services/spree/bank_payments/health_reporter_spec.rb`
Expected: PASS, 8 examples.

- [ ] **Step 5: Commit**

```bash
git add app/services/spree/bank_payments/health_reporter.rb spec/services/spree/bank_payments/health_reporter_spec.rb
git commit -m "Report reconciler health transitions from core

Logs on transition and at most hourly thereafter: a five-minute poll against a
dead consent would otherwise write ~288 identical lines a day and bury the
recovery. Severity splits by actionability -- a 502 self-heals and is WARN, a
revoked consent stays broken until someone reconnects and is ERROR.

The reason enum is closed and unrecognised values collapse to :unknown, because
the obvious shortcut of passing an exception message through would put bearer
tokens in the log aggregator.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Wire `PollJob` to the reporter

**Files:**
- Modify: `app/jobs/spree/bank_payments/poll_job.rb:19-36`
- Test: `spec/jobs/spree/bank_payments/poll_job_spec.rb` (append)

**Interfaces:**
- Consumes: `HealthReporter.call` from Task 3; `Reconcilers::Base#health` from Task 1.

- [ ] **Step 1: Write the failing test**

Append to `spec/jobs/spree/bank_payments/poll_job_spec.rb`:

```ruby
  describe 'health reporting' do
    let!(:payment_method) { create(:bank_transfer_gateway) }

    it 'reports :ok after a successful poll' do
      allow(Spree::BankPayments::HealthReporter).to receive(:call)

      described_class.perform_now

      expect(Spree::BankPayments::HealthReporter).to have_received(:call).
        with(hash_including(status: :ok, reason: :ok))
    end

    # A provider that knows its consent is dead must be able to say so, rather
    # than having every failure flattened to "transient" and retried forever.
    it 'passes a reconciler-declared :consent_revoked straight through' do
      allow_any_instance_of(Spree::BankPayments::Reconcilers::Manual).
        to receive(:poll).and_raise(StandardError, 'nope')
      allow_any_instance_of(Spree::BankPayments::Reconcilers::Manual).
        to receive(:health).and_return(:consent_revoked)
      allow(Spree::BankPayments::HealthReporter).to receive(:call)

      described_class.perform_now

      expect(Spree::BankPayments::HealthReporter).to have_received(:call).
        with(hash_including(status: :consent_revoked))
    end

    it 'still polls the remaining payment methods when one reports unhealthy' do
      other = create(:bank_transfer_gateway)
      allow_any_instance_of(Spree::BankPayments::Reconcilers::Manual).
        to receive(:poll).and_raise(StandardError, 'nope')

      expect { described_class.perform_now }.not_to raise_error
      expect(other.reconciler_state.reload.consecutive_failures).to eq(1)
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/jobs/spree/bank_payments/poll_job_spec.rb -e "health reporting"`
Expected: FAIL — `HealthReporter` never received `:call`.

- [ ] **Step 3: Implement**

Replace `poll_one` in `app/jobs/spree/bank_payments/poll_job.rb`:

```ruby
      def poll_one(payment_method)
        state = payment_method.reconciler_state
        since = (state.last_successful_run_at || 7.days.ago) - OVERLAP

        payment_method.reconciler.poll(since: since).each do |data|
          IngestTransfer.new(payment_method: payment_method, transfer_data: data).call
        end

        state.record_success!
        HealthReporter.call(payment_method: payment_method, status: :ok, reason: :ok)
      rescue StandardError => e
        # Never re-raise: one misconfigured payment method must not stop the
        # others, and the recorded failure is what flips the health gate.
        # `state` itself may be nil (e.g. reconciler_state's find_or_create_by!
        # racing a concurrent first-ever call) -- guard it so a NoMethodError
        # here can't escape and wedge every payment method after this one.
        state&.record_failure!(e.message)
        Rails.error.report(e, source: 'spree_bank_payments.poll')
        report_failure(payment_method)
      end

      # Ask the reconciler what kind of failure this was. A provider that knows
      # its consent is dead says :consent_revoked; anything that raises while
      # answering is itself only transient evidence, so it degrades rather than
      # escaping and skipping the remaining payment methods.
      def report_failure(payment_method)
        status = payment_method.reconciler.health
        status = :transient unless Reconcilers::Base::HEALTH_STATES.include?(status)
        status = :transient if status == :ok

        reason = status == :consent_revoked ? :consent_revoked : :provider_error

        HealthReporter.call(payment_method: payment_method, status: status, reason: reason)
      rescue StandardError => e
        Rails.error.report(e, source: 'spree_bank_payments.health')
      end
```

> **Two pre-merge review changes to this method are not shown above**, so that
> this block stays readable as the Task 4 step it was. Both are in the shipped
> `poll_job.rb`:
>
> - The unused `error` parameter was dropped (already reflected above), since it
>   was the fossil of a reason-derivation feature the `REASONS` trim abandoned.
> - `payment_method.reconciler.health` was wrapped in its own rescue, and the
>   `HealthReporter.call` on both paths moved into a `report_health` helper with
>   its own rescue. Without the first, an unregistered reconciler key raises out
>   of `Reconcilers::Base.build` before `#health` is reached, the method-level
>   rescue swallows it, and **no health is reported at all** — no event, no log
>   line, no persisted `health_status`. Without the second, a reporter that
>   raised on the success path recorded a fully successful poll as a failure.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/jobs/spree/bank_payments/poll_job_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/jobs/spree/bank_payments/poll_job.rb spec/jobs/spree/bank_payments/poll_job_spec.rb
git commit -m "Report health from the poll job

A reconciler that knows its consent is dead can say so instead of having every
failure flattened to transient and retried forever. Asking it costs a call that
may itself raise, so that path degrades to :transient rather than escaping the
rescue and skipping every remaining payment method.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `Gateway#health` and withdrawing from checkout

**Files:**
- Modify: `app/models/spree/bank_payments/gateway.rb:103-118, 156-178`
- Test: `spec/models/spree/bank_payments/gateway_health_spec.rb` (append)

**Interfaces:**
- Consumes: `ReconcilerState#health_status` from Task 2.
- Produces: `Gateway#health -> Symbol`.

- [ ] **Step 1: Write the failing test**

Append to `spec/models/spree/bank_payments/gateway_health_spec.rb`:

```ruby
  describe '#health' do
    let(:payment_method) { create(:bank_transfer_gateway) }
    let(:order) { create(:order_with_line_items, currency: 'GBP') }

    before { create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true) }

    context 'with a non-Manual reconciler' do
      # A real anonymous subclass, not a double: instance_of?(Reconcilers::Manual)
      # must be false for it so the persisted branch in #health is actually
      # reached, which a bare instance_double of Reconcilers::Base would not
      # guarantee.
      let(:fake_reconciler) do
        Class.new(Spree::BankPayments::Reconcilers::Base) do
          def health = :ok
        end.new(payment_method: payment_method)
      end

      before { allow(payment_method).to receive(:reconciler).and_return(fake_reconciler) }

      # available_for_order? runs on every checkout render. A network call here
      # would put a bank's latency on the storefront's critical path, so this
      # reads only what the poll job persisted.
      it 'never asks the reconciler, so checkout cannot make a network call' do
        expect(fake_reconciler).not_to receive(:health)

        payment_method.health
      end

      it 'is :consent_revoked when that is what the poll job recorded' do
        payment_method.reconciler_state.update!(health_status: 'consent_revoked')

        expect(payment_method.health).to eq(:consent_revoked)
      end

      it 'withdraws the payment method from checkout when consent is revoked' do
        payment_method.reconciler_state.update!(health_status: 'consent_revoked')

        expect(payment_method.available_for_order?(order)).to be(false)
      end

      # A brief provider outage must not pull bank transfer off the storefront:
      # the transfers still arrive and reconcile once the provider returns.
      it 'keeps offering at checkout while merely transient' do
        payment_method.reconciler_state.update!(health_status: 'transient')

        expect(payment_method.available_for_order?(order)).to be(true)
      end
    end

    context 'with the Manual reconciler' do
      it 'is always :ok, which never talks to anything' do
        expect(payment_method.health).to eq(:ok)
      end

      # The regression test for switching a dead-consent gateway back to
      # Manual: an admin whose provider consent died switches the reconciler
      # to manual so they can reconcile by hand. The reconciler_state row
      # still carries the stale health_status from before the switch. The
      # Manual short-circuit must win immediately, not wait for the next
      # poll to overwrite it -- otherwise bank transfer stays withdrawn from
      # checkout for up to a full poll interval at exactly the moment the
      # admin was trying to turn it back on.
      it 'is :ok even with a persisted health_status of consent_revoked' do
        payment_method.reconciler_state.update!(health_status: 'consent_revoked')

        expect(payment_method.health).to eq(:ok)
      end
    end
  end
```

**Controller ruling.** An earlier draft of this step used the Manual-backed
factory (`create(:bank_transfer_gateway)`'s default reconciler) to assert
provider `#health` behaviour, while `Gateway#health` short-circuits to `:ok`
for `Reconcilers::Manual` before it ever reads persisted state. Those two
things directly contradict each other: the Manual short-circuit makes the
persisted-state assertions unreachable through the default factory. The
ruling was to keep the Manual short-circuit first in the implementation (an
admin switching a dead-consent gateway back to Manual must regain checkout
availability immediately, not wait out a stale `health_status`) and to test
the persisted-state branch against a real non-Manual reconciler subclass
instead, with a separate Manual-reconciler context covering the
short-circuit itself. That is what Step 1 above and the shipped code reflect.

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/models/spree/bank_payments/gateway_health_spec.rb -e "#health"`
Expected: FAIL — `NoMethodError: undefined method 'health'`.

- [ ] **Step 3: Implement**

In `app/models/spree/bank_payments/gateway.rb`, add after `reconciler_healthy?` (line 118):

```ruby
      # The persisted view of health, safe to call on the checkout hot path.
      #
      # Deliberately does NOT call `reconciler.health`: available_for_order? runs
      # on every checkout render, and a provider's live check is an HTTP request.
      # The poll job is what refreshes this.
      #
      # #reconciler_healthy? is left alone -- it gates the expiry job from a
      # background worker where a live check is fine, and changing it here would
      # alter behaviour this task has no reason to touch.
      def health
        return :ok if reconciler.instance_of?(Reconcilers::Manual)

        persisted = reconciler_state.health_status.presence&.to_sym
        return :consent_revoked if persisted == :consent_revoked

        reconciler_state.healthy?(preferred_poll_interval_minutes) ? :ok : :transient
      end
```

In `available_for_order?`, insert immediately after `return false unless super` (line 157):

```ruby
        # Nothing will ever reconcile against a dead consent, so quoting bank
        # details would take money we cannot match to an order. :transient is
        # deliberately not gated here.
        return false if health == :consent_revoked
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/models/spree/bank_payments/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/models/spree/bank_payments/gateway.rb spec/models/spree/bank_payments/gateway_health_spec.rb
git commit -m "Withdraw the payment method from checkout on a revoked consent

Nothing will ever reconcile against a dead consent, so continuing to quote bank
details takes money that cannot be matched to an order. A transient outage is
deliberately not gated: those transfers still arrive and reconcile once the
provider returns.

Gateway#health reads persisted state and never calls the reconciler, because
available_for_order? runs on every checkout render and a provider's live check
is an HTTP request.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `pooled` on accounts

**Files:**
- Create: `db/migrate/20260817000008_add_pooled_to_bank_accounts.rb`
- Modify: `app/models/spree/bank_payments/account_data.rb`
- Modify: `app/services/spree/bank_payments/sync_accounts.rb:82-100`
- Test: `spec/models/spree/bank_payments/account_data_spec.rb`, `spec/services/spree/bank_payments/sync_accounts_spec.rb` (append to both)

**Interfaces:**
- Produces: `AccountData#pooled` (Boolean, default `false`); `BankAccount#pooled`.

- [ ] **Step 1: Write the failing tests**

Append to `spec/models/spree/bank_payments/account_data_spec.rb`:

```ruby
  # Additive: every existing construction call omits it, and a provider that
  # has never heard of pooling must keep working unchanged.
  it 'defaults pooled to false when a provider does not report it' do
    data = described_class.new(provider_account_id: 'acc_1', currency: 'GBP', details: [{ 'label' => 'x' }])

    expect(data.pooled).to be(false)
  end

  it 'carries pooled when a provider does report it' do
    data = described_class.new(provider_account_id: 'acc_1', currency: 'GBP',
                               details: [{ 'label' => 'x' }], pooled: true)

    expect(data.pooled).to be(true)
  end
```

Append to `spec/services/spree/bank_payments/sync_accounts_spec.rb`:

`SyncAccounts.new` takes `payment_method:` only — it always asks
`payment_method.reconciler.sync_accounts` for the report, rather than
accepting one directly. Stub that method (the file's existing `stub_sync`
helper does this) instead of passing a `reported:` keyword:

```ruby
  describe 'pooled accounts' do
    def pooled_account_data(pooled:)
      Spree::BankPayments::AccountData.new(
        provider_account_id: 'acc_pooled', currency: 'GBP',
        details: [{ 'label' => 'UK', 'fields' => [{ 'label' => 'IBAN', 'value' => 'GB00X' }] }], pooled: pooled
      )
    end

    it 'records pooled on create' do
      stub_sync([pooled_account_data(pooled: true)])

      described_class.new(payment_method: gateway).apply!

      expect(gateway.bank_accounts.find_by(provider_account_id: 'acc_pooled').pooled).to be(true)
    end

    # A provider flipping an account to pooled is a safety-relevant change, so
    # it must not be pinned to whatever was true at first sync.
    it 'updates pooled on a later sync' do
      stub_sync([pooled_account_data(pooled: false)])
      described_class.new(payment_method: gateway).apply!

      stub_sync([pooled_account_data(pooled: true)])
      described_class.new(payment_method: gateway).apply!

      expect(gateway.bank_accounts.find_by(provider_account_id: 'acc_pooled').pooled).to be(true)
    end
  end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/models/spree/bank_payments/account_data_spec.rb spec/services/spree/bank_payments/sync_accounts_spec.rb`
Expected: FAIL — `unknown keyword: :pooled`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260817000008_add_pooled_to_bank_accounts.rb`:

```ruby
class AddPooledToBankAccounts < ActiveRecord::Migration[7.2]
  def change
    add_column :spree_bank_payments_bank_accounts, :pooled, :boolean, null: false, default: false
  end
end
```

- [ ] **Step 4: Implement**

Replace `app/models/spree/bank_payments/account_data.rb`:

```ruby
module Spree
  module BankPayments
    # One account as reported by a provider, in the gem's normalised shape.
    # The reconciler maps its provider's response into this -- the database and
    # views never see provider-specific schemas.
    #
    # `pooled` marks an account whose coordinates are shared with other
    # customers of the provider, so the payment reference is the only thing
    # separating two payers. Defaults to false: every provider written before
    # 5.3.0 omits it, and a dedicated account is the safe assumption.
    AccountData = Data.define(:provider_account_id, :currency, :details, :pooled) do
      def initialize(details: [], pooled: false, **rest)
        super(details: details, pooled: pooled, **rest)
      end
    end
  end
end
```

In `app/services/spree/bank_payments/sync_accounts.rb`, add `pooled: data.pooled` to the `create!` call (after `details: data.details,`) and to the `account.update!` call (after `details: data.details,`).

- [ ] **Step 5: Run tests to verify they pass**

Run: `bundle exec rake test_app && bundle exec rspec spec/models/spree/bank_payments/account_data_spec.rb spec/services/spree/bank_payments/sync_accounts_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate app/models/spree/bank_payments/account_data.rb app/services/spree/bank_payments/sync_accounts.rb spec
git commit -m "Carry a pooled flag from the provider to the account

A pooled account shares its coordinates with other customers of the provider,
so the payment reference is the only thing separating two payers. Additive and
defaulting to false, so a provider that has never heard of pooling keeps working
and a dedicated account stays the safe assumption.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Lock the auto-apply invariant for pooled accounts

**Files:**
- Test: `spec/services/spree/bank_payments/pooled_account_matching_spec.rb` (create)

**Interfaces:**
- Consumes: `BankAccount#pooled` from Task 6.

**Context the implementer needs:** `IngestTransfer#matching_session` already requires an exact normalized reference — it returns `nil` on a blank `reference_normalized` and looks sessions up by `external_id_normalized`. There is no amount-only path today, for any account. **This task adds no production code.** It exists so that a future change adding a fuzzy or amount-only fallback fails loudly instead of silently making pooled accounts unsafe. Do not "fix" the implementation to make these pass — they should pass immediately.

- [ ] **Step 1: Write the regression lock**

Create `spec/services/spree/bank_payments/pooled_account_matching_spec.rb`:

```ruby
require 'spec_helper'

# On a pooled account the coordinates are shared with other customers of the
# provider, so the reference is the ONLY thing separating two payers. Matching
# on amount and currency alone would credit the wrong order.
#
# The current matcher already demands an exact reference for every account, so
# these pass on the day they are written. That is the point: they are a lock,
# not a fix. If someone later adds a fuzzy or amount-only fallback, this file is
# what stops it reaching a pooled account.
RSpec.describe 'auto-apply against a pooled account' do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let!(:account) do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP',
                          offered: true, pooled: true, provider_account_id: 'acc_pool')
  end
  let(:order) { create(:completed_order_with_totals, currency: 'GBP') }
  let!(:session) { payment_method.create_payment_session(order: order) }

  def ingest(reference:)
    data = Spree::BankPayments::TransferData.new(
      provider: 'test', provider_transaction_id: SecureRandom.uuid,
      provider_account_id: 'acc_pool', amount: session.amount, currency: 'GBP',
      reference: reference, payer_name: 'Someone Else', occurred_at: Time.current, raw: {}
    )
    Spree::BankPayments::IngestTransfer.new(payment_method: payment_method, transfer_data: data).call
  end

  it 'applies when the reference matches exactly' do
    expect(ingest(reference: session.external_id)).to be_applied
  end

  it 'refuses a transfer with no reference, even though amount and currency agree' do
    expect(ingest(reference: '')).not_to be_applied
  end

  it 'refuses a near-miss reference, even though amount and currency agree' do
    expect(ingest(reference: "#{session.external_id}X")).not_to be_applied
  end
end
```

- [ ] **Step 2: Run it — it must pass immediately**

Run: `bundle exec rspec spec/services/spree/bank_payments/pooled_account_matching_spec.rb`
Expected: PASS, 3 examples. If any fail, the matcher is weaker than believed — stop and report rather than loosening the spec.

- [ ] **Step 3: Commit**

```bash
git add spec/services/spree/bank_payments/pooled_account_matching_spec.rb
git commit -m "Lock the exact-reference invariant for pooled accounts

Adds no production code: the matcher already demands an exact reference for
every account, so these pass the day they are written. They exist so that a
later fuzzy or amount-only fallback fails loudly here instead of silently
crediting the wrong payer on an account whose coordinates are shared.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Version, CHANGELOG and README

**Files:**
- Modify: `lib/spree/bank_payments/version.rb`
- Modify: `CHANGELOG.md`
- Modify: `README.md`

- [ ] **Step 1: Bump the version**

In `lib/spree/bank_payments/version.rb`, change `VERSION = '5.2.0'.freeze` to `VERSION = '5.3.0'.freeze`.

- [ ] **Step 2: Write the CHANGELOG entry**

Insert directly below the `# Changelog` header block in `CHANGELOG.md`:

```markdown
## 5.3.0

### Upgrading from 5.2.0

Adds columns, so this is not gem-bump-only:

```sh
bin/rails spree_bank_payments:install:migrations
bin/rails db:migrate
```

### Added

**Three-state reconciler health.** `Reconcilers::Base#health` returns `:ok`,
`:transient` or `:consent_revoked`. A boolean could not separate a retryable
provider outage from a dead authorisation, and the two need different responses:
`:transient` keeps offering at checkout, because those transfers still arrive
and reconcile once the provider returns, while `:consent_revoked` withdraws the
payment method, because nothing will ever reconcile against it.

**Backward compatible.** A reconciler written against 5.1.1 or 5.2.0, overriding
only `#healthy?`, works unmodified — `#health` derives from it. A reconciler
overriding only `#health` gets `#healthy?` derived in turn.

**Health transition logging, owned by core.** Logged on transition and at most
hourly thereafter, with a stable `event=` key so alert rules never depend on
prose. `:transient` logs WARN, `:consent_revoked` logs ERROR, recovery logs INFO.
`bank_transfer.reconciler_health.unhealthy` and `.recovered` are also published through
`Spree::Events`. (These carried a `bank_payments.reconciler.*` prefix when this
plan was written; renamed before merge so the documented `bank_transfer.*`
wildcard catches them. The shipped CHANGELOG says a little more than this
excerpt, including that they are distinct from the flat
`bank_transfer.reconciler_unhealthy` `ExpireSessionsJob` publishes.)

The `reason` is drawn from a closed enum and unrecognised values collapse to
`unknown`. It is never built from an exception message or a response body.

**`pooled` on bank accounts.** Carried from `AccountData` through `SyncAccounts`.
A pooled account shares its coordinates with other customers of the provider, so
the payment reference is the only thing separating two payers. Auto-apply has
always required an exact reference match; `spec/services/spree/bank_payments/pooled_account_matching_spec.rb`
now locks that invariant explicitly.
```

- [ ] **Step 3: Document the contract in the README**

In the reconciler-contract section of `README.md`, document `#health`, the three states, which of them withdraws from checkout, and that overriding either `#health` or `#healthy?` is sufficient. Add the LogQL example:

```logql
{namespace=~"your-ns-.*"} |= "bank_transfer.reconciler_health.unhealthy" | logfmt
```

noting that `reason="consent_revoked"` warrants an immediate page while anything else should only alert after roughly thirty minutes sustained.

- [ ] **Step 4: Run the full suite**

Run: `bundle exec rspec`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/spree/bank_payments/version.rb CHANGELOG.md README.md
git commit -m "Release 5.3.0

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review

**Spec coverage.** A1 three-state health → Tasks 1 and 5. A2 transition logging → Tasks 3 and 4. A3 `pooled` → Tasks 6 and 7. Release mechanics → Task 8.

**One deviation from the spec, deliberate.** The spec's A3 says the pooled rule is enforced by the matcher. Reading `IngestTransfer#matching_session`, that rule is already universal — auto-apply demands an exact normalized reference for every account, pooled or not, and no amount-only path exists. Task 7 therefore locks the invariant rather than adding a rule that would be a no-op. Reported to the author before this plan was written; `docs/revolut-provider-design.md` A3 should be amended to match.

**Type consistency.** `HEALTH_STATES` (Task 1) is consumed by the shared examples (Task 1), `PollJob#report_failure` (Task 4) and the reporter spec (Task 3). `record_health!(status:, reason:, logged:)` (Task 2) is called only by `HealthReporter#call` (Task 3). `HealthReporter.call(payment_method:, status:, reason:)` returns a Boolean, asserted in Task 3 and stubbed in Task 4. `AccountData#pooled` (Task 6) is read by `SyncAccounts` (Task 6) and exercised through `BankAccount#pooled` (Task 7).

**Ordering.** Tasks 1→2→3→4 are strictly sequential. Task 5 needs Task 2. Tasks 6 and 7 are independent of 1-5 and could run in parallel with them; 7 needs 6 only for the `pooled: true` factory attribute.
