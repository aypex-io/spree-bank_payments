require 'spec_helper'

RSpec.feature 'Bank transfer configuration guide', type: :feature do
  stub_authorization!

  let!(:payment_method) { create(:bank_transfer_gateway) }

  scenario 'shows the webhook URL and reconciler health' do
    visit spree.edit_admin_payment_method_path(payment_method)

    expect(page).to have_content('/api/v3/webhooks/payments/')
    expect(page).to have_content('Reconciler')
  end
end
