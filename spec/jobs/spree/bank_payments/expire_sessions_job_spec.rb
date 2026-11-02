require 'spec_helper'

RSpec.describe Spree::BankPayments::ExpireSessionsJob do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let!(:session) do
    create(:bank_transfer_payment_session, order: order, payment_method: payment_method, expires_at: 1.hour.ago)
  end

  before { capture_published_events }

  def healthy!(healthy = true)
    allow_any_instance_of(Spree::BankPayments::Gateway).to receive(:reconciler_healthy?).and_return(healthy)
  end

  context 'when the reconciler is healthy' do
    before { healthy! }

    it 'cancels an unpaid placed order after the deadline' do
      described_class.perform_now

      expect(order.reload.status).to eq('canceled')
    end

    it 'expires the session' do
      described_class.perform_now

      expect(session.reload.status).to eq('expired')
    end

    it 'tells the buyer' do
      described_class.perform_now

      expect(published('bank_transfer.expired').size).to eq(1)
    end

    it 'leaves sessions that have not yet expired alone' do
      session.update!(expires_at: 1.day.from_now)

      described_class.perform_now

      expect(order.reload.status).to eq('placed')
    end
  end

  # Cancelling hands the order's stock back to the shelf.
  context 'with an order placed through checkout' do
    let(:gateway) { create(:bank_transfer_gateway) }
    let(:cart) { stock!(bank_transfer_cart(gateway: gateway, price: 100), quantity: 10) }
    let(:stock_item) { Spree::StockItem.find_by!(variant_id: cart.line_items.first.variant_id) }

    before { healthy! }

    it 'releases the stock of the cancelled order' do
      _, placed_session = place_with_bank_transfer(cart, gateway: gateway)
      placed_session.update_columns(expires_at: 1.hour.ago)

      described_class.perform_now

      expect(stock_item.reload.count_on_hand).to eq(10)
    end

    # The order carries the pending payment checkout left: Spree's cancel
    # voids it through the gateway.
    it 'voids the pending payment' do
      order, placed_session = place_with_bank_transfer(cart, gateway: gateway)
      placed_session.update_columns(expires_at: 1.hour.ago)

      described_class.perform_now

      expect(order.payments.reload.map(&:status)).to eq(%w[void])
    end

    it 'expires the session and tells the buyer' do
      _, placed_session = place_with_bank_transfer(cart, gateway: gateway)
      placed_session.update_columns(expires_at: 1.hour.ago)

      described_class.perform_now

      told = published('bank_transfer.expired').count { |payload| payload['payment_session_id'] == placed_session.prefixed_id }

      expect([placed_session.reload.status, told]).to eq(['expired', 1])
    end
  end

  # The buyer picked bank transfer and left. There is no order to cancel and
  # nobody to tell.
  context 'with a session whose cart was never placed' do
    let!(:session) do
      create(:bank_transfer_payment_session, payment_method: payment_method, expires_at: 1.hour.ago)
    end

    before { healthy! }

    it 'expires the session' do
      described_class.perform_now

      expect(session.reload.status).to eq('expired')
    end

    it 'publishes no expired event' do
      described_class.perform_now

      expect(published('bank_transfer.expired')).to be_empty
    end
  end

  # C2. The buyer abandoned the transfer and paid another way. Cancelling
  # would refund nothing and restock an order that has been paid in full.
  context 'when the order has already been paid another way' do
    let(:order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 25.00) }

    before do
      healthy!
      create(:payment, order: order, amount: order.total, status: 'completed')
      Spree.order_update_statuses_service.call(order: order.reload)
    end

    it 'leaves the paid order alone' do
      described_class.perform_now

      expect(order.reload.status).to eq('placed')
    end

    it 'closes the superseded session as canceled rather than expiring it' do
      described_class.perform_now

      expect(session.reload.status).to eq('canceled')
    end

    it 'publishes that the session was superseded' do
      described_class.perform_now

      expect(published('bank_transfer.session_superseded').size).to eq(1)
    end

    it 'publishes no expired event' do
      described_class.perform_now

      expect(published('bank_transfer.expired')).to be_empty
    end
  end

  context 'when the order was paid and then partly refunded' do
    let(:order) { create(:completed_order_with_totals, currency: 'GBP', line_items_price: 25.00) }

    before do
      healthy!
      payment = create(:payment, order: order, amount: order.total, status: 'completed')
      create(:refund, payment: payment, amount: 5)
      Spree.order_update_statuses_service.call(order: order.reload)
    end

    it 'leaves the order alone' do
      described_class.perform_now

      expect(order.reload.status).to eq('placed')
    end
  end

  # An exception for one session (a void the gateway rejects, say) must not
  # stop the run for every later session on the same gateway.
  context 'when closing one session raises' do
    let(:other_order) { create(:completed_order_with_totals) }
    let!(:other_session) do
      create(:bank_transfer_payment_session, order: other_order, payment_method: payment_method, expires_at: 1.hour.ago)
    end

    before do
      healthy!
      allow(Rails.error).to receive(:report)
      allow(Spree.order_cancel_workflow).to receive(:call).and_wrap_original do |original, **options|
        raise Spree::Core::GatewayError, 'void refused' if options[:order] == order

        original.call(**options)
      end
    end

    it 'still cancels the next order' do
      described_class.perform_now

      expect(other_order.reload.status).to eq('canceled')
    end

    it 'reports the session that failed' do
      described_class.perform_now

      expect(published('bank_transfer.expiry_failed').map { |payload| payload['payment_session_id'] }).
        to include(session.prefixed_id)
    end
  end

  context 'when the reconciler is unhealthy' do
    before { healthy!(false) }

    # THE critical case. A blind reconciler must never cancel: the buyer may
    # well have paid and we simply cannot see it.
    it 'cancels nothing' do
      described_class.perform_now

      expect(order.reload.status).to eq('placed')
    end

    it 'leaves the session open' do
      described_class.perform_now

      expect(session.reload.status).to eq('pending')
    end

    it 'publishes an unhealthy event instead' do
      described_class.perform_now

      expect(published('bank_transfer.reconciler_unhealthy').first['payment_method_id']).to eq(payment_method.prefixed_id)
    end
  end

  # Spree can refuse a cancel (a host's before_cancel hook, say). The session
  # stays open, staff are told, and the run carries on.
  context 'when Spree refuses a cancellation' do
    let(:other_order) { create(:completed_order_with_totals) }
    let!(:other_session) do
      create(:bank_transfer_payment_session, order: other_order, payment_method: payment_method, expires_at: 1.hour.ago)
    end

    before do
      healthy!
      refused = Spree::ServiceModule::Result.new(false, order, Spree::ServiceModule::ResultError.new('Refused by policy'))
      allow(Spree.order_cancel_workflow).to receive(:call).and_wrap_original do |original, **options|
        options[:order] == order ? refused : original.call(**options)
      end
    end

    it 'leaves the refused order placed' do
      described_class.perform_now

      expect(order.reload.status).to eq('placed')
    end

    it 'leaves its session open' do
      described_class.perform_now

      expect(session.reload.status).to eq('pending')
    end

    it 'reports the refusal' do
      described_class.perform_now

      expect(published('bank_transfer.expiry_failed').first['error']).to eq('Refused by policy')
    end

    it 'still cancels the next order' do
      described_class.perform_now

      expect(other_order.reload.status).to eq('canceled')
    end
  end

  context 'when one payment method raises' do
    let(:other_payment_method) { create(:bank_transfer_gateway) }
    let(:other_order) { create(:completed_order_with_totals) }
    let!(:other_session) do
      create(:bank_transfer_payment_session, order: other_order, payment_method: other_payment_method, expires_at: 1.hour.ago)
    end

    before do
      failing_id = payment_method.id
      allow_any_instance_of(Spree::BankPayments::Gateway).to receive(:reconciler_healthy?) do |instance|
        raise ArgumentError, 'unknown reconciler' if instance.id == failing_id

        true
      end
      allow(Rails.error).to receive(:report)
    end

    it 'publishes an alert for the failing payment method' do
      described_class.perform_now

      expect(published('bank_transfer.expiry_failed').first['payment_method_id']).to eq(payment_method.prefixed_id)
    end

    it 'still processes the healthy one' do
      described_class.perform_now

      expect(other_order.reload.status).to eq('canceled')
    end
  end
end
