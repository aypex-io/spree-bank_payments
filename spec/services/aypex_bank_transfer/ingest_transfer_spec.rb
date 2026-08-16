require 'spec_helper'

RSpec.describe AypexBankTransfer::IngestTransfer do
  # discount_percent: 0 -- the factory default is 3%, which (as of Task 9)
  # is genuinely applied on payment creation and would shift order.total
  # below the pinned 25.00 amount, making payment_state unreachably 'paid'.
  # This spec is about matching/application, not discount amount, so the
  # discount is switched off here rather than reworking the pinned totals.
  let(:payment_method) { create(:bank_transfer_gateway, preferred_discount_percent: 0) }
  # A bank-transfer order is checkout-complete before the customer ever
  # sees the transfer instructions (they render on the confirmation page),
  # so :completed_order_with_totals is the representative fixture, not
  # :order_with_line_items. line_items_price/shipment_cost are pinned so
  # order.total == the hardcoded session/transfer amount below (25.00) —
  # the factory defaults (10.00 item + 100 shipment = 110.00 total) would
  # make payment_state unreachably 'paid' for a 25.00 payment. That
  # mismatch is a fixture bug, not a matching/application bug, so it's
  # fixed here rather than weakening the `be_applied` /
  # `payment_state == 'paid'` assertions below.
  let(:order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 25.00, shipment_cost: 0) }
  let!(:session) do
    create(:bank_transfer_payment_session,
           order: order, payment_method: payment_method,
           external_id: 'TKF-7Q4X2', amount: 25.00, currency: 'GBP')
  end

  def transfer_data(overrides = {})
    AypexBankTransfer::TransferData.new(
      **{
        provider: 'test',
        provider_transaction_id: 'TX-1',
        amount: 25.00,
        currency: 'GBP',
        reference: 'TKF-7Q4X2',
        payer_name: 'Jane Doe',
        occurred_at: Time.current,
        raw: {}
      }.merge(overrides)
    )
  end

  def ingest(overrides = {})
    described_class.new(payment_method: payment_method, transfer_data: transfer_data(overrides)).call
  end

  describe 'exact match' do
    it 'applies the payment and completes the session' do
      transfer = ingest

      expect(transfer).to be_applied
      expect(transfer.payment_session).to eq(session)
      expect(transfer.payment_method_id).to eq(payment_method.id)
      expect(session.reload.status).to eq('completed')
      expect(order.reload.payment_state).to eq('paid')
    end

    it 'matches despite casing, spacing and punctuation' do
      expect(ingest(reference: ' tkf/7q4x2 ')).to be_applied
    end

    # C2. The customer abandoned the transfer, paid by card, then sent the
    # bank transfer anyway from the emailed instructions. It exact-matches
    # the still-open session; auto-applying would credit a second payment
    # and leave real money to refund. That is a human decision.
    it 'refuses to auto-apply when the order has already been paid another way' do
      create(:payment, order: order, amount: order.total, state: 'completed')
      order.update_with_updater!
      expect(order.reload.payment_state).to eq('paid')

      transfer = ingest

      expect(transfer.state).to eq('unmatched')
      expect(transfer.payment_session).to be_nil
      expect(session.reload.status).to eq('pending')
      expect(order.reload.payments.completed.count).to eq(1)
    end

    it 'matches despite Crockford-ambiguous glyphs' do
      # The session reference contains digits 0 and 1; the customer typed the
      # letters O and I. Folding both sides makes them the same reference.
      session.update!(external_id: 'TKF-01ABCD')

      expect(ingest(reference: 'TKF-OIABCD', provider_transaction_id: 'TX-9')).to be_applied
    end
  end

  describe 'idempotency' do
    it 'is a no-op when the same provider transaction arrives twice' do
      ingest
      expect { ingest }.not_to change(Spree::Payment, :count)
      expect(AypexBankTransfer::IncomingTransfer.count).to eq(1)
    end

    it 'does not re-enter application on replay' do
      ingest
      expect(AypexBankTransfer::ApplyTransfer).not_to receive(:call)
      ingest
    end
  end

  describe 'refuses to auto-apply' do
    it 'on underpayment' do
      expect(ingest(amount: 20.00, provider_transaction_id: 'TX-2')).to be_unmatched
    end

    it 'on overpayment' do
      expect(ingest(amount: 30.00, provider_transaction_id: 'TX-3')).to be_unmatched
    end

    it 'on currency mismatch' do
      expect(ingest(currency: 'EUR', provider_transaction_id: 'TX-4')).to be_unmatched
    end

    it 'when the reference matches nothing' do
      expect(ingest(reference: 'TKF-NOPE1', provider_transaction_id: 'TX-5')).to be_unmatched
    end

    it 'when the reference is blank' do
      expect(ingest(reference: nil, provider_transaction_id: 'TX-6')).to be_unmatched
    end

    it 'when the session is already expired' do
      session.expire!
      expect(ingest(provider_transaction_id: 'TX-7')).to be_unmatched
    end

    it 'when the session is already canceled' do
      session.cancel!
      expect(ingest(provider_transaction_id: 'TX-8')).to be_unmatched
    end
  end

  describe 'failure during application' do
    it 'leaves the transfer re-processable rather than half applied' do
      allow_any_instance_of(Spree::Payment).to receive(:complete!).and_raise(StandardError, 'boom')

      expect { ingest }.to raise_error(StandardError, 'boom')
      expect(AypexBankTransfer::IncomingTransfer.last).to be_unmatched
      expect(session.reload.status).to eq('pending')
      expect(Spree::Payment.count).to eq(0)
    end
  end
end
