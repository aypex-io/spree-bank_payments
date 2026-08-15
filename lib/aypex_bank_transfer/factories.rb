FactoryBot.define do
  factory :bank_transfer_incoming_transfer, class: 'AypexBankTransfer::IncomingTransfer' do
    provider { 'test' }
    sequence(:provider_transaction_id) { |n| "TX-#{n}" }
    amount { 25.00 }
    currency { 'GBP' }
    reference_raw { 'TKF-7Q4X2' }
    payer_name { 'Jane Doe' }
    occurred_at { Time.current }
    state { 'unmatched' }
  end
end
