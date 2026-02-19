# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength
Rails.application.routes.draw do
  # Handle favicon requests silently to prevent routing errors in tests
  get '/favicon.ico', to: proc { [204, {}, []] }

  # Test routes (only in test environment)
  get 'test/auth_status', to: 'test#auth_status' if Rails.env.test?
  post 'test/set_session', to: 'test#set_session' if Rails.env.test?

  root to: 'home#index'

  # Static pages
  get 'privacy', to: 'pages#privacy'
  get 'terms', to: 'pages#terms'
  get 'accessibility', to: 'pages#accessibility'
  get 'help', to: 'pages#help', as: :help
  get 'how_it_works', to: 'pages#how_it_works', as: :how_it_works
  get 'eligibility', to: 'pages#eligibility', as: :eligibility
  get 'apply', to: 'pages#apply', as: :apply
  get 'contact', to: 'pages#contact', as: :contact

  # Welcome/Onboarding
  get 'welcome', to: 'welcome#index', as: :welcome

  # Authentication
  get 'sign_in', to: 'sessions#new'
  post 'sign_in', to: 'sessions#create'
  delete 'sign_out', to: 'sessions#destroy'
  get 'sign_out', to: 'sessions#destroy' # Allow GET for browsers without JS or direct URL access
  get 'sessions', to: 'sessions#index'

  # Identity namespace for authentication-related actions
  namespace :identity do
    resources :password_resets, only: %i[edit update], param: :token
    resources :email_verifications, only: [:show], param: :token
  end

  # Registration
  get 'sign_up', to: 'registrations#new'
  post 'sign_up', to: 'registrations#create'
  resource :password, only: %i[new create edit update]
  resource :profile, only: %i[edit update], controller: 'users'

  # Two-Factor Authentication (consolidated approach)
  resource :two_factor_authentication, only: [] do
    get :setup
    get :verify
    post :verify_code

    # Primary verification routes
    get 'verify/:type', to: 'two_factor_authentications#verify_method', as: :verify_method
    post 'verify/:type', to: 'two_factor_authentications#process_verification', as: :process_verification
    get 'verification_options/:type', to: 'two_factor_authentications#verification_options', as: :verification_options
    post 'verify/sms/resend', to: 'two_factor_authentications#resend_sms_verification', as: :resend_sms_verification

    # Credential management routes (delegated to TwoFactorCredentialsController)
    get 'credentials/:type/new', to: 'two_factor_credentials#new_credential', as: :new_credential
    post 'credentials/:type', to: 'two_factor_credentials#create_credential', as: :create_credential
    delete 'credentials/:type/:id', to: 'two_factor_credentials#destroy_credential', as: :destroy_credential
    get 'credentials/:type/success', to: 'two_factor_credentials#credential_success', as: :credential_success

    # SMS specific routes
    get 'credentials/sms/:id/verify', to: 'two_factor_credentials#verify_sms_credential', as: :verify_sms_credential
    post 'credentials/sms/:id/confirm', to: 'two_factor_credentials#confirm_sms_credential', as: :confirm_sms_credential
    post 'credentials/sms/:id/resend', to: 'two_factor_credentials#resend_sms_code', as: :resend_sms_code

    # WebAuthn specific routes
    post 'credentials/webauthn/options', to: 'two_factor_credentials#webauthn_creation_options', as: :webauthn_creation_options
  end

  # Account Recovery
  get 'lost_security_key', to: 'account_recovery#new', as: :lost_security_key
  post 'request_security_key_reset', to: 'account_recovery#create', as: :request_security_key_reset
  get 'account_recovery/confirmation', to: 'account_recovery#confirmation', as: :account_recovery_confirmation

  get 'up', to: 'rails/health#show', as: :rails_health_check

  # Notifications
  resources :notifications, only: [:index] do
    member do
      post :mark_as_read
      post :check_email_status
    end
  end

  # Action Mailbox routes
  # First, mount the engine to provide all standard ActionMailbox functionality
  mount ActionMailbox::Engine => '/rails/action_mailbox'

  # Our custom namespace for specific functionality
  namespace :rails do
    namespace :action_mailbox do
      namespace :postmark do
        resources :inbound_emails, only: [:create]
      end
    end
  end

  namespace :admin do
    get 'dashboard', to: 'dashboards#index', as: :dashboard
    root to: 'dashboards#index'

    resources :guardian_relationships, only: %i[destroy]

    resources :recovery_requests, only: %i[index show] do
      member do
        post :approve
      end
    end

    resources :print_queue, only: %i[index show] do
      member do
        post :mark_as_printed
      end
      collection do
        get :download_batch
        post :mark_batch_as_printed
      end
    end

    resources :constituents, only: [] do
      collection do
        get :type_check
      end
    end

    resources :paper_applications, only: %i[new create] do
      collection do
        post :send_rejection_notification
        post :reject_for_income
        get :dependent_form
      end
    end

    resources :applications do
      collection do
        post :batch_approve
        post :batch_reject
        get  :search
        get  :filter
        get  :dashboard
        get  :refresh_pipeline_chart
        get  :charts
      end

      member do
        post :assign_voucher
        post :request_documents
        post :review_proof # if you're handling via standard POST or GET
        post :update_proof_status
        patch :approve
        patch :reject
        post :assign_evaluator
        post :assign_trainer
        post :schedule_training
        post :complete_training
        patch :update_proof_status
        patch :update_certification_status
        post :resend_medical_certification
        patch :upload_medical_certification
        post :send_document_signing_request
        post :queue_medical_certification_form
      end

      resources :notes, only: [:create], controller: 'application_notes'
      resources :scanned_proofs, only: %i[new create] # Added missing routes
    end

    # Application Analytics
    get 'application_analytics/pain_points', to: 'application_analytics#pain_points'

    resources :email_templates, only: %i[index show edit update] do
      member do
        get :new_test_email
        post :send_test
        patch :toggle_disabled
        patch :mark_synced
      end
      collection do
        patch :bulk_disable
        patch :bulk_enable
      end
    end

    resources :constituents_dashboard, only: %i[index show]

    resources :proof_reviews, only: %i[index show new create]
    resources :proofs, only: %i[new create] do
      post :resubmit, on: :collection
    end

    resources :policies, only: %i[index show edit update create] do
      collection do
        get :changes
        patch :bulk_update # Add route for bulk updates
      end
    end

    resources :users do
      collection do
        get :search
        get :evaluators
        get :vendors
        get :constituents
      end

      member do
        get :dependents
        get :last_application_values
        post :approve
        post :suspend
        post :reactivate
        post :assign_constituents
        post :remove_constituents
        post :update_availability
        post :deactivate
        post :reset_password
        post :remind_to_complete
        post :assign_evaluator
        patch :update_role
        patch :update_capabilities
        get :history
      end
    end

    resources :vendors do
      resources :w9_reviews, only: %i[index show new create]
    end

    resources :products do
      member do
        post :archive
        post :unarchive
      end

      collection do
        get :inventory_report
      end
    end

    resources :reports, only: %i[index show] do
      collection do
        get :equipment_distribution
        get :evaluation_metrics
        get :vendor_performance
      end
    end

    resources :vouchers do
      member do
        patch :cancel
      end
      collection do
        get :expired
        get :expiring_soon
      end
    end

    resources :invoices do
      member do
        patch :approve
        patch :cancel
      end
      collection do
        get :paid
        get :export_batch
      end
    end
  end
  # rubocop:enable Metrics/BlockLength

  namespace :evaluators do
    resource :dashboard, only: [:show], controller: :dashboards
    resources :evaluations do
      member do
        post :submit_report
        post :request_additional_info
        post :schedule
        post :reschedule
      end

      collection do
        # Status filters
        get :requested
        get :scheduled
        get :pending
        get :completed
        get :needs_followup

        # Scope+status filters (mine vs all)
        get 'filter(/:scope)(/:status)', to: 'evaluations#filter', as: :filtered
      end
    end
  end

  # Trainers routes
  namespace :trainers do
    resource :dashboard, only: [:show], controller: :dashboards

    resources :training_sessions, only: %i[index show] do
      collection do
        get :filter
        get :requested
        get :scheduled
        get :completed
        get :needs_followup
        get 'filter(/:scope)(/:status)', to: 'training_sessions#filter', as: :filtered # Add filter route
      end
      member do
        patch :update_status
        post :complete
        post :schedule
        post :reschedule
        post :cancel
      end
    end
  end

  namespace :vendor_portal do
    resource :dashboard, only: [:show], controller: :dashboard
    resource :profile, only: %i[edit update], controller: :profiles
    resources :redemptions, only: %i[new create] do
      collection do
        get :check_voucher
        get :verify
      end
    end
    resources :vouchers, only: %i[index show], param: :code do
      member do
        get :verify
        post :verify_dob
        get :redeem
        post :process_redemption
      end
    end
    resources :transactions, only: [:index] do
      get :report, on: :collection
    end
    resources :invoices, only: %i[index show]
  end

  namespace :admin do
    resources :feature_flags, only: %i[index update]
  end

  # New constituent_portal namespace (replacing constituent)
  namespace :constituent_portal do
    resource :dashboard, only: [:show]
    resources :dependents
    resources :applications, path: 'applications', except: [:destroy] do
      collection do
        patch :autosave_field
      end

      member do
        patch :autosave_field
        patch :upload_documents
        post :request_review
        get :verify
        patch :submit
        post :resubmit_proof
        post :update # Handle form submissions that POST to update path
        post :request_training
      end

      scope module: :proofs do
        get 'proofs/new/:proof_type', to: 'proofs#new', as: :new_proof
        post 'proofs/resubmit', to: 'proofs#resubmit'
        post 'proofs/direct_upload', to: 'proofs#direct_upload'
      end
    end

    resources :evaluations, only: %i[index show]
    resources :products, only: %i[index show]

    # Redirect old devices routes to products
    get '/devices', to: redirect('/constituent_portal/products')
    get '/devices/:id', to: redirect('/constituent_portal/products/%<id>s')
  end

  namespace :webhooks do
    resources :email_events, only: [:create]
    resources :medical_certifications, only: [:create]
    post 'twilio/fax_status', to: 'twilio#fax_status', as: :twilio_fax_status
    post 'docuseal/medical_certification', to: 'docuseal#medical_certification'
  end
end
