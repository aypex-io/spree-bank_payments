FactoryBot.define do
  factory :bank_transfer_incoming_transfer, class: 'Spree::BankPayments::IncomingTransfer' do
    provider { 'test' }
    sequence(:provider_transaction_id) { |n| "TX-#{n}" }
    amount { 25.00 }
    currency { 'GBP' }
    reference_raw { 'TKF-7Q4X2' }
    payer_name { 'Jane Doe' }
    occurred_at { Time.current }
    state { 'unmatched' }
  end

  factory :bank_transfer_gateway, class: 'Spree::BankPayments::Gateway' do
    name { 'Bank Transfer' }
    preferences do
      {
        reconciler: 'manual',
        reference_prefix: 'TKF-',
        expiry_days: 3,
        discount_percent: 3,
        poll_interval_minutes: 15,
        account_name: 'Example Store Ltd',
        account_iban: 'GB00TEST00000000000000',
        account_bic: 'REVOGB21'
      }
    end
  end

  factory :bank_transfer_payment_session, class: 'Spree::PaymentSessions::BankTransfer' do
    association :order, factory: :order
    association :payment_method, factory: :bank_transfer_gateway
    amount { 25.00 }
    currency { 'GBP' }
    status { 'pending' }
    sequence(:external_id) { |n| "TKF-TEST#{n.to_s.rjust(2, '0')}" }
    expires_at { 3.days.from_now }
  end
end
