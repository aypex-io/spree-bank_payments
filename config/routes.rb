Spree::Core::Engine.add_routes do
  namespace :admin do
    resources :bank_transfers, only: [:index] do
      member do
        put :apply
        put :ignore
      end
    end
  end
end
