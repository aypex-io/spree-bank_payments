module Spree
  module Admin
    class BankAccountsController < Spree::Admin::BaseController
      before_action :load_payment_method
      before_action :load_bank_account, only: %i[edit update destroy toggle_offered]

      def index
        @bank_accounts = @payment_method.bank_accounts.order(:currency, :id)
      end

      def new
        @bank_account = @payment_method.bank_accounts.new
      end

      def create
        @bank_account = @payment_method.bank_accounts.new(bank_account_params)

        if @bank_account.save
          redirect_to_index 'Bank account created.'
        else
          render :new
        end
      rescue JSON::ParserError
        @bank_account = @payment_method.bank_accounts.new(raw_bank_account_params.except(:details))
        @bank_account.errors.add(:details, 'must contain valid JSON')
        render :new
      end

      def edit; end

      def update
        # Synced accounts are the provider's record, not ours -- editing their
        # currency or details here would silently diverge from the account
        # actually watched. Checked against the *raw*, unparsed params so a
        # malformed `details` payload can't slip past this guard by raising
        # JSON::ParserError before it runs (see the JSON.parse call in
        # #bank_account_params).
        if @bank_account.synced? && synced_field_present?
          flash[:error] = 'Synced accounts cannot be edited. Re-sync to refresh them.'
          return redirect_to_index
        end

        if @bank_account.update(bank_account_params)
          redirect_to_index 'Bank account updated.'
        else
          render :edit
        end
      rescue JSON::ParserError
        @bank_account.errors.add(:details, 'must contain valid JSON')
        render :edit
      end

      def destroy
        if @bank_account.synced?
          flash[:error] = 'Synced accounts cannot be deleted. Deactivate instead.'
        else
          @bank_account.destroy
        end

        redirect_to_index
      end

      def toggle_offered
        Spree::BankPayments::BankAccount.transaction do
          @payment_method.bank_accounts.
            for_currency(@bank_account.currency).offered.
            where.not(id: @bank_account.id).
            update_all(offered: false)

          @bank_account.update!(offered: !@bank_account.offered?)
        end

        redirect_to_index
      end

      # Never builds and holds a plan across the request: `apply!` with no
      # argument derives and validates the plan itself, including the abort
      # guard against a provider auth failure returning `[]` (which `plan`
      # would otherwise read as "every account disappeared" and deactivate
      # all of them). Passing a pre-built plan here would bypass that guard
      # entirely -- see SyncAccounts#apply! and #plan.
      #
      # Rescues only EmptyResponseError -- the one operational failure
      # SyncAccounts itself distinguishes from a programming error. A bare
      # `rescue StandardError` here would also swallow a NoMethodError or
      # similar bug and report it to the admin as an unremarkable "Sync
      # failed", hiding it instead of surfacing it as the 500 it should be.
      def sync
        Spree::BankPayments::SyncAccounts.new(payment_method: @payment_method).apply!
        redirect_to_index 'Accounts synced.'
      rescue Spree::BankPayments::SyncAccounts::EmptyResponseError => e
        flash[:error] = "Sync failed: #{e.message}. No accounts were changed."
        redirect_to_index
      end

      private

      def load_payment_method
        @payment_method = Spree::BankPayments::Gateway.find(params[:payment_method_id])
      end

      def load_bank_account
        @bank_account = @payment_method.bank_accounts.find(params[:id])
      end

      def redirect_to_index(notice = nil)
        flash[:success] = notice if notice
        redirect_to spree.admin_payment_method_bank_accounts_path(@payment_method)
      end

      # `active` is deliberately NOT permitted. It is sync's field, not the
      # admin's: it records whether the provider still reports the account,
      # and the form offers no control for it. Permitting it meant a
      # hand-crafted PUT could set `active: false` on the offered account,
      # which withdraws that currency from checkout entirely
      # (Gateway#offered_account_for scopes by `active`) until the next sync
      # flips it back. The admin's lever is `offered` (toggle_offered).
      def raw_bank_account_params
        params.require(:bank_account).permit(:currency, :offered, :details)
      end

      def synced_field_present?
        raw = raw_bank_account_params
        raw.key?(:currency) || raw.key?(:details)
      end

      def bank_account_params
        permitted = raw_bank_account_params
        permitted[:details] = JSON.parse(permitted[:details]) if permitted[:details].is_a?(String)
        permitted
      end
    end
  end
end
