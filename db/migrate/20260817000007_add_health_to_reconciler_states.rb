class AddHealthToReconcilerStates < ActiveRecord::Migration[7.2]
  def change
    add_column :spree_bank_payments_reconciler_states, :health_status, :string
    add_column :spree_bank_payments_reconciler_states, :health_reason, :string
    add_column :spree_bank_payments_reconciler_states, :health_reported_at, :datetime
  end
end
