module Spree
  module BankPayments
    # The default mailer: what the buyer is told about a bank transfer. The
    # instructions when the order is placed, a reminder as the deadline nears,
    # and word that the order was cancelled when the deadline passed unpaid.
    #
    # Every deadline is shown in the store's time zone, as a date and a time:
    # the session expires at an instant, and a buyer reading a UTC date, or a
    # count of days, can be told the wrong day.
    class InstructionsMailer < Spree::BaseMailer
      helper_method :deadline

      # @param payment_session_id [String] the session's prefixed id, as event
      #   payloads carry it
      def instructions(payment_session_id)
        buyer_mail(:instructions, payment_session_id)
      end

      # @param payment_session_id [String] the session's prefixed id
      def reminder(payment_session_id)
        buyer_mail(:reminder, payment_session_id) { { deadline: deadline(:date) } }
      end

      # Sent once the order has been cancelled for want of the transfer. It
      # carries no bank details: the order is gone, and a transfer made now
      # matches nothing.
      #
      # @param payment_session_id [String] the session's prefixed id
      def expired(payment_session_id)
        buyer_mail(:expired, payment_session_id)
      end

      def current_store
        @current_store ||= @order&.store
      end

      private

      # @param kind [Symbol] :date for the date alone, as subjects show it
      # @return [String] the session's deadline in the store's time zone
      def deadline(kind = :time)
        I18n.l(@deadline, format: I18n.t("spree.bank_payments.mailer.deadline_#{kind}_format"))
      end

      # The subject's interpolations, beyond the store and the order number,
      # come from the block, evaluated in the store's locale.
      def buyer_mail(action, payment_session_id)
        @session = ::Spree::PaymentSessions::BankTransfer.find_by_prefix_id!(payment_session_id)
        @order = @session.order
        @detail_sets = @session.bank_detail_sets
        @deadline = @session.expires_at.in_time_zone(store_time_zone)

        with_store_locale(@order.store) do
          subject = I18n.t("spree.bank_payments.mailer.#{action}.subject",
                           store: @order.store.name, number: @order.number, **(block_given? ? yield : {}))
          mail(to: @order.email, subject: subject)
        end
      end

      def store_time_zone
        ActiveSupport::TimeZone[@order.store.preferred_timezone.to_s] || Time.zone
      end
    end
  end
end
