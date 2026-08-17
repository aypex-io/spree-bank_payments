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
      # Deliberately only the four values core can actually produce. Widening a
      # published enum later is non-breaking; narrowing it is not, and every
      # value here is a promise to alert rules that key on reason=. Nothing
      # hands a provider a way to supply its own reason yet, so a richer
      # vocabulary would be advertising states no code path can reach.
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
        previous.present? && previous != status
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
