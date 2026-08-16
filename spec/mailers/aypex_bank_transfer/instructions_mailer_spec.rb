require 'spec_helper'

RSpec.describe AypexBankTransfer::InstructionsMailer, type: :mailer do
  let(:payment_method) { create(:bank_transfer_gateway) }
  let(:order) { create(:completed_order_with_totals) }
  let(:session) do
    create(:bank_transfer_payment_session, order: order, payment_method: payment_method)
  end

  describe '#instructions' do
    subject(:mail) { described_class.instructions(session.id) }

    it 'sends to the order email' do
      expect(mail.to).to eq([order.email])
    end

    it 'renders the reference subject' do
      expect(mail.subject).to eq(Spree.t('bank_transfer.reference'))
    end

    it 'includes the payment reference in the body' do
      expect(mail.body.encoded).to include(session.reference)
    end

    it 'includes the bank account details in the body' do
      expect(mail.body.encoded).to include(payment_method.preferred_account_name)
      expect(mail.body.encoded).to include(payment_method.preferred_account_iban)
    end
  end

  describe '#reminder' do
    subject(:mail) { described_class.reminder(session.id) }

    it 'sends to the order email' do
      expect(mail.to).to eq([order.email])
    end

    it 'renders the pay-within subject' do
      expect(mail.subject).to eq(Spree.t('bank_transfer.pay_within', days: 2))
    end

    it 'includes the payment reference in the body' do
      expect(mail.body.encoded).to include(session.reference)
    end
  end
end
