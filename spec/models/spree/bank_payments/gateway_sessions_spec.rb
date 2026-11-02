require 'spec_helper'

RSpec.describe Spree::BankPayments::Gateway, 'payment sessions' do
  # No discount here: the discount's own specs cover what it does to amounts.
  let(:gateway) { create(:bank_transfer_gateway).tap { |g| g.update!(preferred_discount_percent: 0) } }
  let(:cart) { bank_transfer_cart(gateway: gateway, price: 100) }

  describe '#create_payment_session' do
    let(:session) { gateway.create_payment_session(order: cart) }

    it 'creates a pending session owned by the cart' do
      expect(session.cart).to eq(cart)
    end

    it 'leaves the session without an order until the cart is placed' do
      expect(session.order).to be_nil
    end

    it 'quotes the amount due at checkout' do
      expect(session.amount).to eq(BigDecimal('100.00'))
    end

    it 'stores the quote where the storefront can read it' do
      expect(session.external_data['bank_transfer']['reference']).to eq(session.reference)
    end

    it 'ignores a client-supplied quote' do
      tampered = gateway.create_payment_session(order: cart, external_data: { 'bank_transfer' => { 'amount' => '1.00' } })

      expect(tampered.external_data['bank_transfer']['amount']).to eq('100.00')
    end

    it 'keeps other client-supplied data' do
      with_data = gateway.create_payment_session(order: cart, external_data: { 'checkout_step' => 'payment' })

      expect(with_data.external_data['checkout_step']).to eq('payment')
    end

    it "cancels the cart's earlier open session when the buyer re-selects" do
      first = gateway.create_payment_session(order: cart)
      gateway.create_payment_session(order: cart)

      expect(first.reload.status).to eq('canceled')
    end

    # Instructions go out on order.placed: before that there is no order and
    # no address to send them to.
    it 'publishes no instructions' do
      allow(Spree::Events).to receive(:publish).and_call_original

      session

      expect(Spree::Events).not_to have_received(:publish).with('bank_transfer.instructions_ready', anything, anything)
    end
  end

  describe '#complete_payment_session' do
    let(:session) { gateway.create_payment_session(order: cart) }

    before { gateway.complete_payment_session(payment_session: session) }

    it 'leaves a pending payment carrying the reference' do
      expect(cart.payments.last).to have_attributes(status: 'pending', response_code: session.reference)
    end

    it 'stays open so a transfer can still match it' do
      expect(Spree::PaymentSessions::BankTransfer.open).to include(session)
    end

    it 'is placed by Carts::Complete with the payment still pending' do
      result = Spree.carts_complete_workflow.call(cart: cart)

      expect(result.value.payment_status).to eq('authorized')
    end

    it 'moves onto the placed order' do
      order = Spree.carts_complete_workflow.call(cart: cart).value

      expect(session.reload.order).to eq(order)
    end
  end

  # A released or expired session's reference matches nothing any more: an
  # order paid through it would never be reconciled, reminded or expired.
  describe 'a session that is no longer open' do
    let!(:session) { gateway.create_payment_session(order: cart) }

    before { Spree::BankPayments::ReleaseSelection.call(purchase: cart) }

    it 'refuses to complete it' do
      expect { gateway.complete_payment_session(payment_session: session.reload) }.
        to raise_error(Spree::Core::GatewayError)
    end

    it 'creates no payment for it' do
      begin
        gateway.complete_payment_session(payment_session: session.reload)
      rescue Spree::Core::GatewayError
        nil
      end

      expect(cart.payments.where(response_code: session.reference)).to be_empty
    end

    it 'refuses to requote it' do
      expect { gateway.update_payment_session(payment_session: session.reload) }.
        to raise_error(Spree::Core::GatewayError)
    end
  end

  describe '#cancel_payment_session' do
    it 'cancels a session nobody completed' do
      session = gateway.create_payment_session(order: cart)

      expect(gateway.cancel_payment_session(payment_session: session)).to be(true)
    end

    # A completed session carries the order's payment: Spree must never
    # retire it as unused.
    it 'keeps a session that carries a payment' do
      session = gateway.create_payment_session(order: cart)
      gateway.complete_payment_session(payment_session: session)

      expect(gateway.cancel_payment_session(payment_session: session)).to be(false)
    end
  end
end
