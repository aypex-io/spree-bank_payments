require 'spec_helper'

RSpec.describe 'spree/checkout/payment/_spree_bank_transfer', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) } # 3% in the factory

  it 'advertises the saving as a discount, never a fee' do
    render partial: 'spree/checkout/payment/spree_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).to include('save 3%')
    expect(rendered.downcase).not_to include('surcharge')
    expect(rendered.downcase).not_to include('fee')
  end

  # formatted_discount_percent (Gateway) exists specifically so this view
  # never truncates a fractional discount -- percent.to_i would silently
  # round 2.5% down to "2%" in customer-facing copy. Render the partial
  # itself with a fractional percent so a future edit that reintroduces
  # `.to_i` here fails a view spec, not just apply_discount_spec.rb.
  it 'renders a fractional discount percent without truncation' do
    payment_method.update!(preferred_discount_percent: 2.5)

    render partial: 'spree/checkout/payment/spree_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).to include('save 2.5%')
    expect(rendered).not_to include('save 2%')
  end

  it 'states the payment window' do
    render partial: 'spree/checkout/payment/spree_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).to include('3 days')
  end

  it 'omits the discount line when no discount is configured' do
    payment_method.update!(preferred_discount_percent: 0)

    render partial: 'spree/checkout/payment/spree_bank_transfer',
           locals: { payment_method: payment_method }

    expect(rendered).not_to include('save')
  end
end
