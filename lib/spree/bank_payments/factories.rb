FactoryBot.define do
  factory :bank_transfer_incoming_transfer, class: 'Spree::BankPayments::IncomingTransfer' do
    provider { 'test' }
    sequence(:provider_transaction_id) { |n| "TX-#{n}" }
    amount { 25.00 }
    currency { 'GBP' }
    reference_raw { 'ACME-7Q4X2' }
    payer_name { 'Jane Doe' }
    occurred_at { Time.current }
    state { 'unmatched' }
  end

  factory :bank_transfer_gateway, class: 'Spree::BankPayments::Gateway' do
    name { 'Bank Transfer' }
    store { Spree::Store.find_by(default: true) || association(:store) }
    preferences do
      {
        reconciler: 'manual',
        reference_prefix: 'ACME-',
        expiry_days: 3,
        discount_percent: 3,
        poll_interval_minutes: 15,
        account_name: 'Example Store Ltd',
        account_iban: 'GB00TEST00000000000000',
        account_bic: 'REVOGB21'
      }
    end
  end

  # Owned by a cart unless the spec passes an order: during checkout the
  # session belongs to the cart, and Spree moves it onto the order when the
  # cart completes. A session has exactly one owner.
  factory :bank_transfer_payment_session, class: 'Spree::PaymentSessions::BankTransfer' do
    order { nil }
    cart { order.nil? ? association(:cart, currency: currency) : nil }
    association :payment_method, factory: :bank_transfer_gateway
    amount { 25.00 }
    currency { 'GBP' }
    status { 'pending' }
    sequence(:external_id) { |n| "ACME-TEST#{n.to_s.rjust(2, '0')}" }
    expires_at { 3.days.from_now }
  end

  factory :bank_payments_bank_account, class: 'Spree::BankPayments::BankAccount' do
    association :payment_method, factory: :bank_transfer_gateway
    currency { 'GBP' }
    offered { true }
    active { true }
    details do
      [
        {
          'label' => 'UK payments',
          'schemes' => %w[faster bacs chaps],
          'beneficiary_name' => 'Example Store Ltd',
          'fields' => [
            { 'label' => 'Sort code', 'value' => '04-00-75' },
            { 'label' => 'Account number', 'value' => '12345678' }
          ]
        },
        {
          'label' => 'International',
          'schemes' => %w[swift],
          'beneficiary_name' => 'Example Store Ltd',
          'fields' => [
            { 'label' => 'IBAN', 'value' => 'GB00REVO00000000000000' },
            { 'label' => 'BIC', 'value' => 'REVOGB21' }
          ]
        }
      ]
    end
  end
end
