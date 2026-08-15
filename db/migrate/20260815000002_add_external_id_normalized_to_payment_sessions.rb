class AddExternalIdNormalizedToPaymentSessions < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:spree_payment_sessions, :external_id_normalized)
      add_column :spree_payment_sessions, :external_id_normalized, :string
    end

    # Partial unique index: bank transfer references must be globally unique per
    # payment method, forever, so a late payment quoting an old reference
    # resolves to exactly one session. Scoped to our STI type so other payment
    # session subclasses are unaffected.
    unless index_exists?(:spree_payment_sessions, %i[payment_method_id external_id_normalized],
                          name: 'index_payment_sessions_on_bank_transfer_reference')
      add_index :spree_payment_sessions,
                %i[payment_method_id external_id_normalized],
                unique: true,
                where: "type = 'Spree::PaymentSessions::BankTransfer'",
                name: 'index_payment_sessions_on_bank_transfer_reference'
    end
  end
end
