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

        AypexBankTransfer::ApplyTransfer.call(
          transfer: @transfer,
          payment_session: payment_session,
          applied_by: try_spree_current_user
        )

        flash[:success] = 'Payment applied.'
        redirect_to spree.admin_bank_transfers_path
      end

      def ignore
        @transfer.update!(state: 'ignored', ignored_reason: params[:reason])

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
    end
  end
end
