module Spree
  module BankPayments
    # The default mailer: emails the buyer when instructions are ready, when a
    # reminder is due, and when the order is cancelled for want of the
    # transfer (the cancellation itself sends no email). Stores that tell buyers some other way (a
    # storefront sending its own email from webhooks, say) set
    # Spree::BankPayments::Config.disable_default_mailer, which is read on
    # every event so an initializer can set it at any point in boot.
    #
    # Synchronous: deliver_later already moves the sending off the request.
    class InstructionsMailerSubscriber < Spree::Subscriber
      subscribes_to 'bank_transfer.instructions_ready', 'bank_transfer.reminder_due', 'bank_transfer.expired',
                    async: false

      on 'bank_transfer.instructions_ready', :send_instructions
      on 'bank_transfer.reminder_due', :send_reminder
      on 'bank_transfer.expired', :send_expired

      def send_instructions(event)
        return if Spree::BankPayments::Config.disable_default_mailer

        Spree::BankPayments::InstructionsMailer.instructions(event.payload['payment_session_id']).deliver_later
      end

      def send_reminder(event)
        return if Spree::BankPayments::Config.disable_default_mailer

        Spree::BankPayments::InstructionsMailer.reminder(event.payload['payment_session_id']).deliver_later
      end

      def send_expired(event)
        return if Spree::BankPayments::Config.disable_default_mailer

        Spree::BankPayments::InstructionsMailer.expired(event.payload['payment_session_id']).deliver_later
      end
    end
  end
end
