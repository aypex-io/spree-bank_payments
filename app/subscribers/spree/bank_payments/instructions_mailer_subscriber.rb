module Spree
  module BankPayments
    # The default mailer: emails the buyer when instructions are ready, when a
    # reminder is due, and when the order is cancelled for want of the
    # transfer (the cancellation itself sends no email). Stores that tell buyers some other way (a
    # storefront sending its own email from webhooks, say) set
    # Spree::BankPayments::Config.disable_default_mailer, which is read on
    # every event so an initializer can set it at any point in boot. A store
    # that turns off customer emails in its settings gets none of these
    # either.
    #
    # Synchronous: deliver_later already moves the sending off the request.
    class InstructionsMailerSubscriber < Spree::Subscriber
      subscribes_to 'bank_transfer.instructions_ready', 'bank_transfer.reminder_due', 'bank_transfer.expired',
                    async: false

      on 'bank_transfer.instructions_ready', :send_instructions
      on 'bank_transfer.reminder_due', :send_reminder
      on 'bank_transfer.expired', :send_expired

      def send_instructions(event)
        deliver_email(:instructions, event)
      end

      def send_reminder(event)
        deliver_email(:reminder, event)
      end

      def send_expired(event)
        deliver_email(:expired, event)
      end

      private

      # Also honours the store's own switch for customer emails, which every
      # one of Spree's customer emails checks.
      def deliver_email(email, event)
        return if Spree::BankPayments::Config.disable_default_mailer
        return unless (event.store || Spree::Store.default).prefers_send_consumer_transactional_emails?

        Spree::BankPayments::InstructionsMailer.public_send(email, event.payload['payment_session_id']).deliver_later
      end
    end
  end
end
