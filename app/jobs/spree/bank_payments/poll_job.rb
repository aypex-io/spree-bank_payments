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
      rescue StandardError => e
        # Never re-raise: one misconfigured payment method must not stop the
        # others, and the recorded failure is what flips the health gate.
        # `state` itself may be nil (e.g. reconciler_state's find_or_create_by!
        # racing a concurrent first-ever call) -- guard it so a NoMethodError
        # here can't escape and wedge every payment method after this one.
        state&.record_failure!(e.message)
        Rails.error.report(e, source: 'spree_bank_payments.poll')
      end
    end
  end
end
