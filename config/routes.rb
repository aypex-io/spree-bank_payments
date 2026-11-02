Spree::Core::Engine.add_routes do
  namespace :api, defaults: { format: 'json' } do
    namespace :v3 do
      namespace :admin do
        namespace :bank_payments do
        end
      end
    end
  end
end
