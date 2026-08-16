require 'spec_helper'

RSpec.describe 'spree_bank_transfer/_order_instructions', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let(:payment_session) { payment_method.create_payment_session(order: order) }

  it 'shows the reference prominently' do
    render partial: 'spree_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include(payment_session.reference)
  end

  # The copy button is the single most impactful affordance for match rates,
  # and it is hand-rolled inline JS with no build step behind it -- nothing
  # else would catch it silently disappearing or losing its labels.
  context 'the copy-to-clipboard affordance' do
    before do
      render partial: 'spree_bank_transfer/order_instructions',
             locals: { payment_session: payment_session }
    end

    it 'renders a copy button carrying both labels' do
      expect(rendered).to include('bank-transfer-reference__copy')
      expect(rendered).to include('data-copy-label')
      expect(rendered).to include('data-copy-done-label')
    end

    it 'wires the clipboard write inline, with no framework dependency' do
      expect(rendered).to include('onclick')
      expect(rendered).to include('navigator.clipboard')
      expect(rendered).not_to include('data-controller')
    end

    it 'leaves the reference itself as selectable text so it works without JS' do
      expect(rendered).to include("<code class=\"bank-transfer-reference__code\">#{payment_session.reference}</code>")
    end
  end

  it 'shows the bank details' do
    render partial: 'spree_bank_transfer/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include('GB00TEST00000000000000')
  end
end
