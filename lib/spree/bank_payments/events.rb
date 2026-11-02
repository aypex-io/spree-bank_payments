module Spree
  module BankPayments
    # The events this gem publishes, declared on the model whose record each
    # one is about. Spree 6 raises in development and test when a record
    # publishes a name nobody declared, and in production it still delivers
    # an undeclared event to every webhook endpoint subscribed to `*`.
    CUSTOMER_FACING_EVENTS = %w[
      bank_transfer.instructions_ready
      bank_transfer.reminder_due
      bank_transfer.expired
      bank_transfer.session_superseded
    ].freeze

    # Their payloads carry reconciler error text and internal state, so no
    # webhook endpoint may receive them, not even one subscribed to `*`.
    OPERATIONAL_EVENTS = %w[
      bank_transfer.reconciler_unhealthy
      bank_transfer.expiry_failed
      bank_transfer.reconciler_health.unhealthy
      bank_transfer.reconciler_health.recovered
    ].freeze

    # Called from `to_prepare`: both classes autoload from app/models, and a
    # reloaded class must declare again. The catalog keys declarations by
    # class name, so repeating them replaces rather than duplicates.
    def self.declare_events!
      CUSTOMER_FACING_EVENTS.each do |name|
        Spree::PaymentSessions::BankTransfer.publishes_event(name)
      end

      OPERATIONAL_EVENTS.each do |name|
        Spree::BankPayments::Gateway.publishes_event(name, webhook: false)
      end
    end
  end
end
