require 'spec_helper'

RSpec.describe Spree::BankPayments::ApplyTransfer do
  let(:gateway) { create(:bank_transfer_gateway) } # 3% in the factory
  # A 100.00 cart placed through checkout with bank transfer: the order owes
  # 97.00, and its payment is pending under the session's reference.
  let(:placed) { place_with_bank_transfer(bank_transfer_cart(gateway: gateway, price: 100), gateway: gateway) }
  let(:order) { placed.first }
  let(:session) { placed.last }

  def transfer_for(amount)
    create(:bank_transfer_incoming_transfer,
           payment_method_id: gateway.id, amount: amount, currency: session.currency,
           reference_raw: session.reference, provider_transaction_id: SecureRandom.uuid)
  end

  def apply(transfer, applied_by: nil)
    described_class.call(transfer: transfer, payment_session: session, applied_by: applied_by)
  end

  describe 'an exact match' do
    let!(:transfer) { apply(transfer_for(session.amount)) }

    it 'pays the order' do
      expect(order.reload.payment_status).to eq('paid')
    end

    it 'records the capture' do
      expect(order.payments.reload.last.captured_amount).to eq(BigDecimal('97.00'))
    end

    it 'completes the session' do
      expect(session.reload.status).to eq('completed')
    end

    it 'marks the transfer applied to the session' do
      expect(transfer.reload.payment_session).to eq(session)
    end

    it 'settles the payment taken at checkout rather than creating another' do
      expect(order.payments.count).to eq(1)
    end
  end

  # Staff can apply a transfer whose amount differs from the quote. Crediting
  # the quote would mark the order paid for money that never arrived.
  it 're-stamps the payment to what arrived when staff apply a short transfer' do
    apply(transfer_for(BigDecimal('90.00')), applied_by: create(:admin_user))

    expect(order.reload.payment_status).to eq('partially_paid')
  end

  it 'records who applied it' do
    admin = create(:admin_user)
    transfer = apply(transfer_for(session.amount), applied_by: admin)

    expect(transfer.reload.applied_by_id).to eq(admin.id)
  end

  it 'records nobody on the automatic path' do
    transfer = apply(transfer_for(session.amount))

    expect(transfer.reload.applied_by_id).to be_nil
  end

  # A second request for a transfer already applied (a double click, or two
  # staff at once) is refused, so the caller can say so, not report success.
  it 'refuses a transfer that is already applied' do
    transfer = apply(transfer_for(session.amount))

    expect { apply(transfer) }.to raise_error(described_class::AlreadyApplied)
  end

  it 'captures nothing more when applied again' do
    transfer = apply(transfer_for(session.amount))

    expect do
      apply(transfer)
    rescue described_class::AlreadyApplied
      nil
    end.not_to change(Spree::Payment, :count)
  end

  # The caller's copy can be stale: another request applied the transfer
  # after this one loaded it. The transfer is re-read under its own lock.
  it 'refuses a stale copy of a transfer another request has applied' do
    transfer = transfer_for(session.amount)
    stale = Spree::BankPayments::IncomingTransfer.find(transfer.id)
    apply(transfer)

    expect { apply(stale) }.to raise_error(described_class::AlreadyApplied)
  end

  # A session whose cart never completed has no order to pay.
  it 'refuses a session whose cart was never placed' do
    cart = bank_transfer_cart(gateway: gateway, price: 100)
    unplaced = gateway.create_payment_session(order: cart)
    transfer = transfer_for(unplaced.amount)

    expect { described_class.call(transfer: transfer, payment_session: unplaced) }.
      to raise_error(described_class::Refused)
  end

  # The lock serializes two transfers racing for one session (or a staff
  # apply after the automatic one). The loser must not be marked applied
  # with nothing captured: that would lose real money from the books.
  describe 'under the lock' do
    it 'refuses a second transfer for a session already paid' do
      apply(transfer_for(session.amount))

      expect { apply(transfer_for(session.amount)) }.to raise_error(described_class::Refused)
    end

    it 'leaves the second transfer unmatched' do
      apply(transfer_for(session.amount))
      second = transfer_for(session.amount)

      begin
        apply(second)
      rescue described_class::Refused
        nil
      end

      expect(second.reload.state).to eq('unmatched')
    end

    it 'refuses an order that was cancelled' do
      Spree.order_cancel_workflow.call(order: order)

      expect { apply(transfer_for(session.amount)) }.to raise_error(described_class::Refused)
    end
  end

  # Staff cannot mark a bank transfer order paid from the dashboard: money
  # moves only when a transfer is applied.
  describe 'capturing outside a transfer' do
    let(:payment) { order.payments.last }

    # What Spree's back office asks (Payment#can_capture?, from 6.0.1).
    it 'offers staff no capture' do
      expect(gateway.can_capture?(payment)).to be(false)
    end

    it "refuses Spree's capture workflow" do
      expect(Spree.payment_capture_workflow.call(payment: payment)).not_to be_success
    end
  end
end
