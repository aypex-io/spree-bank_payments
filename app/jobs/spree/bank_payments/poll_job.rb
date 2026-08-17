module Spree
  module BankPayments
    class PollJob < ActiveJob::Base
      queue_as :default

      # Deliberate overlap with the previous run. Ingestion is idempotent, so
      # re-reading recent transfers costs nothing and closes the gap when a
      # provider exhausts its webhook retries.
      OVERLAP = 2.hours

      def perform
        Spree::BankPayments::Gateway.find_each do |payment_method|
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
        report_health(payment_method, :ok, :ok)
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
      # Deliberately takes no exception: the reason is drawn from a closed enum
      # and is never derived from what was raised, because an exception message
      # can carry a bearer token straight into a log aggregator.
      def report_failure(payment_method)
        status = payment_method.reconciler.health
        status = :transient unless Reconcilers::Base::HEALTH_STATES.include?(status)
        status = :transient if status == :ok

        reason = status == :consent_revoked ? :consent_revoked : :provider_error

        report_health(payment_method, status, reason)
      rescue StandardError => e
        Rails.error.report(e, source: 'spree_bank_payments.health')
      end

      # Reporting health is bookkeeping about the poll, not part of it. On the
      # success path the call sits inside poll_one's rescue region, so a
      # reporter that raised -- a logger blowing up, an event subscriber
      # exploding -- would have recorded a failure for a poll that fully
      # succeeded, and then reported health a second time from report_failure.
      #
      # An `else` clause on poll_one would move the call out of the rescue
      # region, but then the exception escapes poll_one entirely and aborts the
      # find_each over every remaining payment method. Its own rescue is what
      # contains it, mirroring what report_failure already does.
      def report_health(payment_method, status, reason)
        HealthReporter.call(payment_method: payment_method, status: status, reason: reason)
      rescue StandardError => e
        Rails.error.report(e, source: 'spree_bank_payments.health')
      end
    end
  end
end
