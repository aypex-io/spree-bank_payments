module Spree
  module Admin
    class BankTransfersController < Spree::Admin::BaseController
      include Pagy::Method

      # Synthetic provider for transfers an admin typed in by hand. Keeps
      # them distinguishable from anything a real reconciler delivered, and
      # gives the (provider, provider_transaction_id) uniqueness index its
      # own namespace so a hand-entered row can never collide with a
      # provider-issued transaction id.
      MANUAL_PROVIDER = 'manual'.freeze

      before_action :load_transfer, only: %i[apply ignore]
      before_action :load_recordable_payment_methods, only: %i[new create]

      def index
        @pagy, @transfers = pagy(
          Spree::BankPayments::IncomingTransfer.unmatched.order(occurred_at: :desc)
        )

        @suggestions = @transfers.each_with_object({}) do |transfer, acc|
          acc[transfer.id] = Spree::BankPayments::SuggestMatches.new(transfer: transfer).call
        end

        # Set only by #apply's mismatch refusal (see I3). Identifies the one
        # transfer/session pair the admin has already been shown the numbers
        # for and may now confirm.
        @confirm_transfer_id = params[:confirm_transfer_id].presence&.to_i
        @confirm_payment_session_id = params[:confirm_payment_session_id].presence&.to_i
      end

      # "Record a received transfer". The Manual reconciler -- the default,
      # and the only one this gem ships -- returns [] from #poll and nil from
      # #parse_webhook, so nothing else can ever create an IncomingTransfer.
      # Without this form a store on the shipped configuration takes a
      # customer's money and has no action available to record it, and
      # ExpireSessionsJob cancels the order a few days later.
      def new
        @transfer_form = blank_transfer_form
      end

      # Deliberately builds a TransferData and hands it to IngestTransfer
      # rather than writing an IncomingTransfer directly: matching lives in
      # exactly one place, so a hand-recorded transfer behaves identically to
      # a provider-delivered one -- exact match auto-applies, anything else
      # lands in the queue for a human.
      def create
        @transfer_form = transfer_form_params

        error = transfer_form_error(@transfer_form)
        if error
          flash.now[:error] = error
          return render :new, status: :unprocessable_entity
        end

        payment_method = @payment_methods.detect { |pm| pm.id.to_s == @transfer_form[:payment_method_id].to_s }
        transaction_id = manual_transaction_id(payment_method, @transfer_form)

        # The idempotency guard is IngestTransfer's find_or_create_by! on
        # (provider, provider_transaction_id). A hand-typed transfer has no
        # provider-issued id to key on, so we derive a deterministic one from
        # the submitted facts: an admin who double-submits the form (double
        # click, browser back-and-resubmit) reproduces the same digest, hits
        # the existing row, and applies nothing a second time. The trade is
        # that two genuinely distinct but byte-identical transfers on the
        # same day collapse into one -- rare, and far safer than the
        # alternative of crediting an order twice.
        already_recorded = Spree::BankPayments::IncomingTransfer.exists?(
          provider: MANUAL_PROVIDER, provider_transaction_id: transaction_id
        )

        transfer = Spree::BankPayments::IngestTransfer.new(
          payment_method: payment_method,
          transfer_data: Spree::BankPayments::TransferData.new(
            provider: MANUAL_PROVIDER,
            provider_transaction_id: transaction_id,
            amount: BigDecimal(@transfer_form[:amount].to_s),
            currency: @transfer_form[:currency].to_s.strip.upcase,
            reference: @transfer_form[:reference].to_s.strip,
            payer_name: @transfer_form[:payer_name].to_s.strip.presence,
            occurred_at: parse_occurred_at(@transfer_form[:occurred_at]),
            raw: {
              'source' => 'admin_manual_entry',
              'recorded_by_id' => try_spree_current_user&.id
            }
          )
        ).call

        flash[:success] =
          if already_recorded
            'That transfer was already recorded — nothing was applied a second time.'
          elsif transfer.applied?
            "Transfer recorded and applied to order #{transfer.payment_session&.order&.number}."
          else
            'Transfer recorded. It is waiting in the queue below for a match.'
          end

        redirect_to spree.admin_bank_transfers_path
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

        # I3: the refusal now hands back the pair that needs confirming, and
        # the queue renders a distinct, explicitly-labelled confirm button
        # only for that pair. Confirmation is therefore a genuine second
        # step -- a deliberate act after seeing the numbers -- rather than
        # something the view pre-granted before the admin looked at anything.
        if money_mismatch?(payment_session) && !confirmed_mismatch?
          flash[:error] = "Amount/currency mismatch: the transfer is #{@transfer.money}, " \
                           "the session expects #{payment_session.money}. " \
                           'Confirm to apply anyway.'
          return redirect_to spree.admin_bank_transfers_path(
            confirm_transfer_id: @transfer.id,
            confirm_payment_session_id: payment_session.id
          )
        end

        Spree::BankPayments::ApplyTransfer.call(
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
        @transfer = Spree::BankPayments::IncomingTransfer.find(params[:id])
      end

      # Same store guard as the apply path: an admin must not be able to
      # record a transfer against another store's gateway.
      def load_recordable_payment_methods
        @payment_methods = Spree::BankPayments::Gateway.where(store_id: current_store.id).order(:name).to_a
      end

      def blank_transfer_form
        {
          payment_method_id: @payment_methods.first&.id,
          amount: nil,
          currency: current_store.default_currency,
          payer_name: nil,
          reference: nil,
          occurred_at: Time.zone.today.to_s
        }
      end

      def transfer_form_params
        params.
          fetch(:bank_transfer, {}).
          permit(:payment_method_id, :amount, :currency, :payer_name, :reference, :occurred_at).
          to_h.
          symbolize_keys
      end

      def transfer_form_error(form)
        return 'No bank-transfer payment method is configured for this store.' if @payment_methods.empty?

        unless @payment_methods.any? { |pm| pm.id.to_s == form[:payment_method_id].to_s }
          return 'Choose which bank-transfer payment method received this money.'
        end

        amount = begin
          BigDecimal(form[:amount].to_s)
        rescue ArgumentError, TypeError
          nil
        end
        return 'Enter the amount that arrived, as a number.' if amount.nil?
        return 'The amount that arrived must be greater than zero.' unless amount.positive?

        return 'Enter the currency the money arrived in.' if form[:currency].to_s.strip.blank?
        return 'Enter the date the money was received.' if parse_occurred_at(form[:occurred_at]).nil?

        nil
      end

      def parse_occurred_at(value)
        return nil if value.to_s.strip.blank?

        Time.zone.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      # Deterministic, so a resubmitted form is a no-op rather than a second
      # credit. Reference is normalised the same way IncomingTransfer
      # normalises it, and payer name is case/whitespace folded, so trivial
      # retyping differences still collapse onto the same transfer.
      def manual_transaction_id(payment_method, form)
        digest = Digest::SHA256.hexdigest(
          [
            payment_method.id,
            BigDecimal(form[:amount].to_s).to_s('F'),
            form[:currency].to_s.strip.upcase,
            Spree::BankPayments::IncomingTransfer.normalize_reference(form[:reference]),
            form[:payer_name].to_s.strip.downcase,
            parse_occurred_at(form[:occurred_at]).to_date.iso8601
          ].join('|')
        )

        "#{MANUAL_PROVIDER}-#{digest[0, 32]}"
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
