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
        payment = payment_session.find_or_create_payment!
        payment_session.complete! unless payment_session.completed?
        payment.complete! unless payment.completed?

        # Spree::Payment only recalculates payment_state on save when the
        # order itself is already checkout-complete. A bank transfer can
        # land before that (or well after), so we recompute and persist it
        # explicitly rather than relying on that implicit, gated callback.
        order = payment_session.order
        order.updater.update_payment_total
        order.updater.update_payment_state
        order.persist_totals

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
