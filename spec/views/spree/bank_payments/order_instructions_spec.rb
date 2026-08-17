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

  # C2. The whole point of recording bank_account_id on the session -- and of
  # soft-deleting rather than deleting accounts -- is that switching accounts
  # strands nothing. That was true in the database and false on the only layer
  # a customer ever sees: this partial read `bank_details_for(currency)`, i.e.
  # whatever is offered *now*. Quote a customer against account A, switch to
  # B, and the confirmation page starts showing B's coordinates against a
  # reference generated for A -- the customer pays the wrong account.
  context 'after the admin switches the offered account for the session currency' do
    let!(:original) do
      create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    end

    it 'still shows the account the session was quoted against, not the new one' do
      session = payment_session
      expect(session.bank_account).to eq(original)

      original.update!(offered: false)
      create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true,
             details: [{ 'label' => 'Replacement bank',
                         'fields' => [{ 'label' => 'IBAN', 'value' => 'GB99NEWACCOUNT0000000' }] }])

      render partial: 'spree/bank_payments/order_instructions',
             locals: { payment_session: session.reload }

      expect(rendered).to include('04-00-75')
      expect(rendered).to include('GB00REVO00000000000000')
      expect(rendered).not_to include('GB99NEWACCOUNT0000000')
    end

    # Worse than the switch: with nothing offered for the currency, the old
    # code rendered a reference, an amount, a deadline -- and no coordinates
    # at all.
    it 'still shows coordinates when the currency stops being offered entirely' do
      session = payment_session
      original.update!(offered: false)

      render partial: 'spree/bank_payments/order_instructions',
             locals: { payment_session: session.reload }

      expect(rendered).to include('04-00-75')
    end

    # Deleting an account from the admin is a soft delete precisely so the
    # quote survives; the `with_deleted` association scope is what keeps that
    # promise, and this is the only test that renders through it.
    it 'still shows coordinates after the quoted account is deleted from the admin' do
      session = payment_session
      original.destroy

      render partial: 'spree/bank_payments/order_instructions',
             locals: { payment_session: session.reload }

      expect(rendered).to include('04-00-75')
    end
  end

  # Legacy sessions (created before 5.2.0) and any reconciler that never
  # linked an account have no bank_account_id. They must fall back to the
  # currently offered account rather than render an empty block.
  it 'falls back to the offered account when the session records none' do
    create(:bank_payments_bank_account, payment_method: payment_method, currency: 'GBP', offered: true)
    session = payment_session
    session.update_column(:bank_account_id, nil)

    render partial: 'spree/bank_payments/order_instructions',
           locals: { payment_session: session.reload }

    expect(rendered).to include('04-00-75')
  end
end
