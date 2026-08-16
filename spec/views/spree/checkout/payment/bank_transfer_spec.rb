require 'spec_helper'

RSpec.describe 'spree/checkout/payment/_aypex_bank_transfer', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) } # 3% in the factory

  it 'advertises the saving as a discount, never a fee' do
    render partial: 'spree/checkout/payment/aypex_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).to include('save 3%')
    expect(rendered.downcase).not_to include('surcharge')
  end

  it 'states the payment window' do
    render partial: 'spree/checkout/payment/aypex_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).to include('3 days')
  end

  it 'omits the discount line when no discount is configured' do
    payment_method.update!(preferred_discount_percent: 0)

    render partial: 'spree/checkout/payment/aypex_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).not_to include('save')
  end
end
