module AypexBankTransfer
  # The single place money actually moves. IngestTransfer calls this with no
  # `applied_by` for automatic application; the admin hand-match queue
  # (Task 13) calls it with the acting admin user. One transaction, one path
  # — no second implementation of "what applying a transfer means".
  class ApplyTransfer
    def self.call(...)
      new(...).call
    end

    def initialize(transfer:, payment_session:, applied_by: nil)
      @transfer = transfer
      @payment_session = payment_session
      @applied_by = applied_by
    end

    def call
      ActiveRecord::Base.transaction do
        # Payment completes before the session. Spree::PaymentSession uses
        # publishes_lifecycle_events, which publishes synchronously inside
        # this transaction — completing the session first would let a
        # "session completed" event (plausibly a customer receipt) escape
        # before we know the payment itself will actually complete. If
        # payment.complete! raises, the DB rolls back but that event
        # cannot be recalled.
        payment = payment_session.find_or_create_payment!
        payment.complete! unless payment.completed?
        payment_session.complete! unless payment_session.completed?

        attrs = { state: 'applied', payment_session: payment_session }
        if applied_by
          attrs[:applied_by_id] = applied_by.id
          attrs[:applied_at] = Time.current
        end

        transfer.update!(attrs)
      end

      transfer
    end

    private

    attr_reader :transfer, :payment_session, :applied_by
  end
end
