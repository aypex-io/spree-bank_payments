class AddPaymentMethodIdToSpreeBankTransferIncomingTransfers < ActiveRecord::Migration[8.1]
  def change
    add_column :spree_bank_transfer_incoming_transfers, :payment_method_id, :bigint

    add_index :spree_bank_transfer_incoming_transfers, :payment_method_id,
              name: 'index_bt_transfers_on_payment_method_id'
  end
end
