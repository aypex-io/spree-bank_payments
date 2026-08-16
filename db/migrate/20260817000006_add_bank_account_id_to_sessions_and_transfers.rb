class AddBankAccountIdToSessionsAndTransfers < ActiveRecord::Migration[8.1]
  def change
    add_column :spree_bank_payments_incoming_transfers, :bank_account_id, :bigint
    add_index  :spree_bank_payments_incoming_transfers, :bank_account_id,
               name: 'index_bp_transfers_on_bank_account_id'

    # Same precedent as external_id_normalized: a nullable column on a Spree
    # core table, indexed only for this gem's STI type.
    add_column :spree_payment_sessions, :bank_account_id, :bigint
    add_index  :spree_payment_sessions, :bank_account_id,
               where: "type = 'Spree::PaymentSessions::BankTransfer'",
               name: 'index_payment_sessions_on_bank_account_id'
  end
end
