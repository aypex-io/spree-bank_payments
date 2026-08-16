require 'spec_helper'

# I4. The queue was reachable only by typing the URL: nothing registered a
# navigation entry anywhere.
RSpec.describe 'admin navigation registration' do
  subject(:item) { Spree.admin.navigation.sidebar.find(:bank_transfers) }

  it 'registers a sidebar entry for the bank transfer queue' do
    expect(item).to be_present
    expect(item.label).to eq('Bank transfers')
    expect(item.url).to eq(:admin_bank_transfers_path)
  end

  it 'resolves to the queue route' do
    expect(Spree::Core::Engine.routes.url_helpers.public_send(item.url)).
      to eq(Spree::Core::Engine.routes.url_helpers.admin_bank_transfers_path)
  end
end
