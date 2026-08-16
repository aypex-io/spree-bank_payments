module Spree
  module Admin
    class BankTransfersController < Spree::Admin::BaseController
      include Pagy::Method

      before_action :load_transfer, only: %i[apply ignore]

      def index
        @pagy, @transfers = pagy(
          AypexBankTransfer::IncomingTransfer.unmatched.order(occurred_at: :desc)
        )

        @suggestions = @transfers.each_with_object({}) do |transfer, acc|
          acc[transfer.id] = AypexBankTransfer::SuggestMatches.new(transfer: transfer).call
        end
      end

      def apply
        if @transfer.applied?
          flash[:error] = 'That transfer has already been applied.'
          return redirect_to spree.admin_bank_transfers_path
        end

        payment_session = find_bank_transfer_payment_session(params[:payment_session_id])

        if payment_session.nil?
          flash[:error] = 'That payment session could not be found.'
          return redirect_to spree.admin_bank_transfers_path
        end

        if gateway_mismatch?(payment_session)
          flash[:error] = 'That transfer was received on a different bank-transfer gateway ' \
                           'and cannot be applied to this session.'
          return redirect_to spree.admin_bank_transfers_path
        end

        if money_mismatch?(payment_session) && !confirmed_mismatch?
          flash[:error] = "Amount/currency mismatch: the transfer is #{@transfer.money}, " \
                           "the session expects #{payment_session.money}. " \
                           'Confirm to apply anyway.'
          return redirect_to spree.admin_bank_transfers_path
        end

        AypexBankTransfer::ApplyTransfer.call(
          transfer: @transfer,
          payment_session: payment_session,
          applied_by: try_spree_current_user
        )

        flash[:success] = 'Payment applied.'
        redirect_to spree.admin_bank_transfers_path
      end

      def ignore
        if @transfer.applied?
          flash[:error] = 'That transfer has already been applied and cannot be ignored.'
          return redirect_to spree.admin_bank_transfers_path
        end

        reason = params[:reason].to_s.strip
        if reason.blank?
          flash[:error] = 'A reason is required to ignore a transfer.'
          return redirect_to spree.admin_bank_transfers_path
        end

        @transfer.update!(state: 'ignored', ignored_reason: reason)

        flash[:success] = 'Transfer ignored.'
        redirect_to spree.admin_bank_transfers_path
      end

      private

      def load_transfer
        @transfer = AypexBankTransfer::IncomingTransfer.find(params[:id])
      end

      # Scoped to the concrete bank-transfer STI subtype and to orders in the
      # current store, so a `payment_session_id` for another payment method
      # (credit card, PayPal, ...) or another store cannot be handed to
      # ApplyTransfer -- that would complete an arbitrary payment/session
      # pair with real money moving behind it.
      def find_bank_transfer_payment_session(id)
        ::Spree::PaymentSessions::BankTransfer.
          joins(:order).
          where(spree_orders: { store_id: current_store.id }).
          find_by(id: id)
      end

      # The auto-apply path (IngestTransfer) guards on payment_method_id at
      # the query level, since it starts from a known gateway. The admin
      # path starts from a payment_session_id typed by a human, so it has
      # to check the reverse direction explicitly: a transfer received on
      # one bank-transfer gateway (e.g. a different `provider`) must not be
      # applicable to a session belonging to another gateway in the same
      # store. A transfer with no known payment_method (legacy/manual data)
      # can't be checked and is allowed through -- that's an existing gap,
      # not a new one.
      def gateway_mismatch?(payment_session)
        @transfer.payment_method_id.present? &&
          @transfer.payment_method_id != payment_session.payment_method_id
      end

      # A human is allowed to hand-match a transfer to a session for a
      # different amount/currency (typos happen, partial payments happen)
      # but never silently -- ApplyTransfer now credits the payment with
      # the transfer's own amount, so a confirmed mismatch produces a real
      # balance_due/credit_owed rather than a false 'paid', but the admin
      # still has to see and confirm the mismatch before it happens.
      # Currency codes are compared case-insensitively so 'gbp' vs 'GBP'
      # (same currency, different casing) doesn't force a spurious
      # confirmation on an otherwise exact match.
      def money_mismatch?(payment_session)
        @transfer.amount != payment_session.amount ||
          @transfer.currency.to_s.casecmp(payment_session.currency.to_s) != 0
      end

      def confirmed_mismatch?
        ActiveModel::Type::Boolean.new.cast(params[:confirm_mismatch])
      end
    end
  end
end
