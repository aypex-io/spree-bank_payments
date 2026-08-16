module Spree
  module BankTransfer
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
      # Wrapped in Spree::Events.disable_lifecycle, not the wider .disable:
      # PaymentSession publishes lifecycle events (`publishes_lifecycle_events`),
      # so a plain `update!` here would also fire a `payment_session.updated`
      # event on every reminder — pure bookkeeping noise unrelated to the
      # `bank_transfer.reminder_due` event this job already published above for
      # the same session. `.disable` would suppress ALL events raised from
      # anywhere during the block (including another thread's explicit
      # `publish_event` calls that happen to run inside it); `.disable_lifecycle`
      # only turns off the automatic *.created/*.updated/*.deleted callback path
      # (`should_publish_events?` checks `lifecycle_enabled?`), leaving explicit
      # `Spree::Events.publish` calls unaffected — exactly the narrower
      # suppression this bookkeeping write needs.
      def mark_reminded(session)
        Spree::Events.disable_lifecycle do
          session.update!(external_data: session.external_data.to_h.merge('last_reminder_on' => Date.current.to_s))
        end
      end
    end
  end
end
