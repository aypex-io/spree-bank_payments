Spree::Core::Engine.add_routes do
  namespace :admin do
    # `new`/`create` are the ingress for the default (Manual) reconciler,
    # which has nothing to poll and no webhook to receive -- without them a
    # store running the shipped configuration has no way at all to record a
    # transfer it has actually received. See BankTransfersController#create.
    resources :bank_transfers, only: [:index, :new, :create] do
      member do
        put :apply
        put :ignore
      end
    end
  end
end
