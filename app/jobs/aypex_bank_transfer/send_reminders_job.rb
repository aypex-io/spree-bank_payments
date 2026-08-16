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

    # Merge onto the existing hash rather than replacing it outright — other
    # code may have already stashed keys in external_data (e.g. the reconciler
    # or ingest pipeline), and clobbering the column here would silently drop
    # them.
    #
    # Wrapped in Spree::Events.disable: PaymentSession publishes lifecycle
    # events (`publishes_lifecycle_events`), so a plain `update!` here would
    # also fire a `payment_session.updated` event on every reminder — pure
    # bookkeeping noise unrelated to the `bank_transfer.reminder_due` event
    # this job already published above for the same session.
    def mark_reminded(session)
      Spree::Events.disable do
        session.update!(external_data: session.external_data.to_h.merge('last_reminder_on' => Date.current.to_s))
      end
    end
  end
end
