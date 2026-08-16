class CreateSpreeBankTransferTables < ActiveRecord::Migration[8.1]
  def change
    create_table :spree_bank_transfer_incoming_transfers do |t|
      t.string   :provider, null: false
      t.string   :provider_transaction_id, null: false
      t.decimal  :amount, precision: 10, scale: 2, null: false
      t.string   :currency, null: false
      t.string   :reference_raw
      t.string   :reference_normalized
      t.string   :payer_name
      t.datetime :occurred_at, null: false
      t.string   :state, null: false, default: 'unmatched'
      t.bigint   :payment_session_id
      t.bigint   :applied_by_id
      t.datetime :applied_at
      t.string   :ignored_reason
      t.jsonb    :raw_payload, null: false, default: {}
      t.timestamps
    end

    add_index :spree_bank_transfer_incoming_transfers,
              %i[provider provider_transaction_id],
              unique: true, name: 'index_bt_transfers_on_provider_and_txn_id'
    add_index :spree_bank_transfer_incoming_transfers,
              :reference_normalized, name: 'index_bt_transfers_on_reference_normalized'
    add_index :spree_bank_transfer_incoming_transfers, :state,
              name: 'index_bt_transfers_on_state'
    add_index :spree_bank_transfer_incoming_transfers, :payment_session_id,
              name: 'index_bt_transfers_on_payment_session_id'

    create_table :spree_bank_transfer_reconciler_states do |t|
      t.bigint   :payment_method_id, null: false
      t.datetime :last_successful_run_at
      t.text     :last_error
      t.integer  :consecutive_failures, null: false, default: 0
      t.timestamps
    end

    add_index :spree_bank_transfer_reconciler_states, :payment_method_id,
              unique: true, name: 'index_bt_reconciler_states_on_payment_method_id'
  end
end
