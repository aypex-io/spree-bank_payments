Spree::Core::Engine.add_routes do
  namespace :api, defaults: { format: 'json' } do
    namespace :v3 do
      namespace :admin do
        namespace :bank_payments do
          resources :transfers, only: %i[index show create] do
            member do
              get :suggestions
              post :apply
              post :ignore
            end
          end

          resources :payment_methods, only: :index do
            resources :accounts, only: %i[index create update destroy] do
              collection do
                get :sync_plan
                post :sync
              end
            end
            resource :health, only: :show, controller: 'health'
          end

          resources :orders, only: :show
        end
      end
    end
  end
end
