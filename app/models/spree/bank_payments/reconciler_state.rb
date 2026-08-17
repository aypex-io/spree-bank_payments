module Spree
  module BankPayments
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

      # @param status [Symbol] a member of Reconcilers::Base::HEALTH_STATES
      # @param reason [Symbol] a member of HealthReporter::REASONS
      # @param logged [Boolean] whether this report was actually emitted
      def record_health!(status:, reason:, logged:)
        attrs = { health_status: status.to_s, health_reason: reason.to_s }
        attrs[:health_reported_at] = Time.current if logged

        update!(attrs)
      end
    end
  end
end
