require 'spec_helper'

RSpec.describe 'spree/bank_payments/_order_instructions', type: :view do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals, currency: 'GBP') }
  let(:payment_session) { payment_method.create_payment_session(order: order) }

  it 'shows the reference prominently' do
    render partial: 'spree/bank_payments/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include(payment_session.reference)
  end

  # The copy button is the single most impactful affordance for match rates,
  # and it is hand-rolled inline JS with no build step behind it -- nothing
  # else would catch it silently disappearing or losing its labels.
  context 'the copy-to-clipboard affordance' do
    before do
      render partial: 'spree/bank_payments/order_instructions',
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

  it 'renders every detail set, labelled' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)

    render partial: 'spree/bank_payments/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include('UK payments')
    expect(rendered).to include('International')
    expect(rendered).to include('04-00-75')
    expect(rendered).to include('GB00REVO00000000000000')
  end

  # This is the proof that the jsonb label/value design actually works: bank
  # coordinates are not standardised across countries, so a market this view
  # has never heard of must render correctly with no migration or view
  # change. If this passed only because the view happens to iterate a hash
  # the same way, that would defeat the point -- it must pass because the
  # partial renders DetailSet#fields generically.
  it 'renders coordinate labels the view has never seen' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true,
           details: [{ 'label' => 'Local', 'fields' => [{ 'label' => 'Elixir number', 'value' => '99887766' }] }])

    render partial: 'spree/bank_payments/order_instructions',
           locals: { payment_session: payment_session }

    expect(rendered).to include('Elixir number')
    expect(rendered).to include('99887766')
  end
end
