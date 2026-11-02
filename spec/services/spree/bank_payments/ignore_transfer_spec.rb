require 'spec_helper'

RSpec.describe Spree::BankPayments::IgnoreTransfer do
  let(:gateway) { create(:bank_transfer_gateway) }
  let(:session) { place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway).last }
  let(:transfer) do
    create(:bank_transfer_incoming_transfer,
           payment_method_id: gateway.id, amount: session.amount, currency: session.currency,
           reference_raw: 'MISTYPED')
  end

  it 'takes the transfer out of the queue with the reason' do
    described_class.call(transfer: transfer, reason: 'Refunded to the payer')

    expect(transfer.reload.slice(:state, :ignored_reason)).
      to eq('state' => 'ignored', 'ignored_reason' => 'Refunded to the payer')
  end

  it 'refuses without a reason' do
    expect { described_class.call(transfer: transfer, reason: ' ') }.to raise_error(ActiveModel::ValidationError)
  end

  # Ignore and apply racing: the apply committed after this request loaded
  # the transfer. The transfer is re-read under its lock, never marked
  # ignored with a captured payment behind it.
  describe 'a transfer another request has applied' do
    let(:stale) { Spree::BankPayments::IncomingTransfer.find(transfer.id) }

    before do
      stale
      Spree::BankPayments::ApplyTransfer.call(transfer: transfer, payment_session: session)
    end

    it 'is refused' do
      expect { described_class.call(transfer: stale, reason: 'Duplicate') }.
        to raise_error(described_class::AlreadyApplied)
    end

    it 'stays applied' do
      begin
        described_class.call(transfer: stale, reason: 'Duplicate')
      rescue described_class::AlreadyApplied
        nil
      end

      expect(transfer.reload.state).to eq('applied')
    end
  end
end
