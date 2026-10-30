# frozen_string_literal: true

Rails.application.routes.draw do
  draw :active_storage
  resources :document_scans, only: %i[index create show destroy]
  get 'document_attachments/:attachment_id', to: 'attachment_downloads#attachment', as: :document_attachment
  resource :session_activity, only: %i[show create]

  # Browsers request this icon even when tests do not provide one.
  get '/favicon.ico', to: proc { [204, {}, []] }
  post 'csp_reports', to: 'csp_reports#create', format: false

  get 'test/auth_status', to: 'test#auth_status' if Rails.env.test?
  post 'test/set_session', to: 'test#set_session' if Rails.env.test?

  root to: 'home#index'

  # Static pages
  get 'privacy', to: 'pages#privacy'
  get 'terms', to: 'pages#terms'
  get 'vendors/:vendor_id/w9_documents/:id', to: 'w9_documents#show', as: :vendor_w9_document
  get 'accessibility', to: 'pages#accessibility'
  get 'help', to: 'pages#help', as: :help
  get 'how_it_works', to: 'pages#how_it_works', as: :how_it_works
  get 'eligibility', to: 'pages#eligibility', as: :eligibility
  get 'apply', to: 'pages#apply', as: :apply
  get 'contact', to: 'pages#contact', as: :contact
  get 'disability_certification_form', to: 'disability_certification_forms#show', as: :disability_certification_form
  # Public secure forms: the form, its success page, and a request for a new link once it expires.
  %w[certification provider_info w9 proof].each do |kind|
    get "secure_#{kind}_form/success", to: "secure_#{kind}_forms#success", as: :"secure_#{kind}_form_success"
    resource :"secure_#{kind}_form", only: %i[show update]
    resource :"secure_#{kind}_form_resend", only: %i[new create], controller: "secure_#{kind}_form_resends"
    get "secure_#{kind}_form_resend/sent", to: "secure_#{kind}_form_resends#sent", as: :"secure_#{kind}_form_resend_sent"
  end

  # Welcome/Onboarding
  get 'welcome', to: 'welcome#index', as: :welcome

  # Authentication
  get 'sign_in', to: 'sessions#new'
  post 'sign_in', to: 'sessions#create'
  delete 'sign_out', to: 'sessions#destroy'
  get 'sign_out', to: 'sessions#destroy' # Retain direct sign-out links.
  get 'sessions', to: 'sessions#index'

  # Registration
  get 'sign_up', to: 'registrations#new'
  post 'sign_up', to: 'registrations#create'
  resource :password, only: %i[new create edit update]
  resource :profile, only: %i[edit update], controller: 'users'

  # Two-Factor Authentication
  resource :two_factor_authentication, only: [] do
    get :setup
    get :verify
    post :verify_code

    get 'verify/:type', to: 'two_factor_authentications#verify_method', as: :verify_method
    post 'verify/:type', to: 'two_factor_authentications#process_verification', as: :process_verification
    get 'verification_options/:type', to: 'two_factor_authentications#verification_options', as: :verification_options
    post 'verify/sms/select', to: 'two_factor_authentications#select_sms_verification', as: :select_sms_verification
    post 'verify/sms/resend', to: 'two_factor_authentications#resend_sms_verification', as: :resend_sms_verification

    # Credential management routes (delegated to TwoFactorCredentialsController)
    get 'credentials/:type/new', to: 'two_factor_credentials#new_credential', as: :new_credential
    post 'credentials/:type', to: 'two_factor_credentials#create_credential', as: :create_credential
    delete 'credentials/:type/:id', to: 'two_factor_credentials#destroy_credential', as: :destroy_credential
    get 'credentials/:type/success', to: 'two_factor_credentials#credential_success', as: :credential_success

    get 'credentials/sms/verify', to: 'two_factor_credentials#verify_pending_sms_credential', as: :verify_pending_sms_credential
    post 'credentials/sms/confirm', to: 'two_factor_credentials#confirm_pending_sms_credential', as: :confirm_pending_sms_credential
    post 'credentials/sms/resend', to: 'two_factor_credentials#resend_pending_sms_code', as: :resend_pending_sms_code

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

  namespace :admin do
    resource :dashboard, only: [:show], controller: :dashboards
    root to: 'dashboards#show'

    resources :feature_flags, only: %i[index update]

    resources :guardian_relationships, only: %i[destroy]

    resources :recovery_requests, only: %i[index show] do
      member do
        post :approve
      end
    end

    resources :duplicate_reviews, only: %i[index show] do
      member do
        post :resolve
        post :merge
      end
      collection do
        post :clear_flag
        post :review_pair
      end
    end

    resources :print_queue, only: %i[index show] do
      member do
        post :release
        post :mark_as_printed
      end
      collection do
        match :download_batch, via: %i[get post]
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
        get :dependent_form
        get :recipient_preference
      end
    end

    resources :applications do
      resource :equipment_needs, only: %i[edit update]

      collection do
        post :batch_approve
        post :batch_reject
        get  :charts
      end

      member do
        post :review_proof
        patch :approve
        patch :reject
        patch :update_proof_status
        patch :update_certification_status
        patch :upload_disability_certification

        post :assign_voucher, to: 'application_vouchers#assign_voucher'

        post :assign_evaluator, to: 'application_evaluations#assign_evaluator'
        post :reassign_evaluator, to: 'application_evaluations#reassign_evaluator'
        post :request_evaluation, to: 'application_evaluations#request_evaluation'

        post :assign_trainer, to: 'application_trainers#assign_trainer'
        post :reassign_trainer, to: 'application_trainers#reassign_trainer'
        post :unassign_trainer, to: 'application_trainers#unassign_trainer'

        post :resend_disability_certification, to: 'application_certification_forms#resend_disability_certification'
        post :send_document_signing_request, to: 'application_certification_forms#send_document_signing_request'
        post :queue_disability_certification_form, to: 'application_certification_forms#queue_disability_certification_form'
      end

      resources :notes, only: %i[create update], controller: 'application_notes'
      resources :secure_request_forms,
                only: [:create],
                controller: 'application_secure_request_forms' do
        resource :revocation,
                 only: [:create],
                 controller: 'application_secure_request_form_revocations'
      end
      resources :secure_request_form_batch_revocations,
                only: [:create],
                controller: 'application_secure_request_form_batch_revocations'
      resource :proof_resubmission_request,
               only: [:create],
               controller: 'application_proof_resubmission_requests'
      resource :certification_upload_request,
               only: [:create],
               controller: 'application_certification_upload_requests'
      resources :certifying_professional_secure_request_forms,
                only: [],
                controller: 'application_certifying_professional_secure_request_forms' do
        resource :revocation,
                 only: [:create],
                 controller: 'application_certifying_professional_secure_request_form_revocations'
      end
    end

    resources :equipment, only: [:index]
    resources :equipment_items, only: %i[edit update]
    resources :purchase_orders, only: %i[index show new create] do
      resource :correction, only: %i[edit update], controller: 'purchase_order_corrections'
    end

    get 'application_analytics/pain_points', to: 'application_analytics#pain_points'

    resource :email_delivery_control, only: :update

    resources :email_templates, only: %i[index show edit update] do
      member do
        get :new_test_email
        get :preview_document
        post :send_test
        patch :toggle_disabled
        patch :mark_synced
        patch :preview
        post :create_counterpart
      end
      collection do
        patch :bulk_disable
        patch :bulk_enable
      end
    end

    resources :rejection_reasons, only: %i[index edit update] do
      member do
        patch :mark_synced
      end
    end

    resources :constituents_dashboard, only: %i[index show]

    resources :policies, only: %i[index show edit update create] do
      collection do
        get :changes
        patch :bulk_update
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
        get :adult_application_context
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
        delete :mfa_tokens, action: :destroy_mfa_tokens
        patch :update_role
        patch :update_capabilities
        get :history
      end
    end

    resources :vendors do
      resources :w9_reviews, only: %i[index show new create]
      resources :vendor_secure_request_forms,
                only: [:create],
                controller: 'vendor_secure_request_forms' do
        resource :revocation,
                 only: [:create],
                 controller: 'vendor_secure_request_form_revocations'
      end
    end

    resources :products do
      resources :product_resources, only: %i[new create edit update destroy]
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

    resources :invoices, only: %i[index show] do
      member do
        patch :approve
        patch :record_payment
        patch :withdraw
        post :correction_note
      end
      # "Invoice now" and retrying a failed vendor run the scheduled generation for one vendor.
      post :generate, on: :collection
    end
    resources :voucher_transactions, only: [] do
      resource :billing_hold, only: %i[create destroy]
    end
  end
  namespace :evaluators do
    resource :dashboard, only: [:show], controller: :dashboards
    resources :evaluations, only: %i[index show update] do
      member do
        get :application_details
        post :submit_report
        post :save_working_notes
        post :schedule
        post :reschedule
        post :cancel
        post :no_show
      end

      collection do
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

  namespace :trainers do
    resource :dashboard, only: [:show], controller: :dashboards

    resources :training_sessions, only: %i[index show] do
      resource :follow_up, only: :create, controller: 'training_sessions/follow_ups'

      collection do
        get :filter
        get :requested
        get :scheduled
        get :completed
        get :needs_followup
        get 'filter(/:scope)(/:status)', to: 'training_sessions#filter', as: :filtered
      end
      member do
        post :no_show
        post :complete
        post :schedule
        post :schedule_additional
        post :reschedule
        post :cancel
      end
    end
  end

  namespace :vendor_portal do
    resource :dashboard, only: [:show], controller: :dashboard
    resource :profile, only: %i[edit update], controller: :profiles
    resources :vouchers, only: %i[index show], param: :code do
      member do
        get :verify
        post :verify_dob
        get :redeem
        post :process_redemption
      end
    end
    resources :transactions, only: %i[index show update] do
      get :report, on: :collection
      resources :shipments, only: %i[create update]
    end
    resources :invoices, only: %i[index show]
  end

  namespace :constituent_portal do
    resource :dashboard, only: [:show]
    resources :dependents
    resources :applications, path: 'applications', except: [:destroy] do
      collection do
        patch :autosave_field
      end

      member do
        patch :autosave_field
        post :resubmit_proof
        post :update # Accept POST from application forms.
        post :request_training
      end

      scope module: :proofs do
        get 'proofs/new/:proof_type', to: 'proofs#new', as: :new_proof
        post 'proofs/resubmit', to: 'proofs#resubmit'
      end
    end

    resources :evaluations, only: %i[index show]
    resources :training_sessions, only: %i[index show]
    resources :products, only: %i[index show]

    get '/devices', to: redirect('/constituent_portal/products')
    get '/devices/:id', to: redirect('/constituent_portal/products/%{id}')
  end

  namespace :webhooks do
    resources :email_events, only: [:create]
    post 'twilio/fax_status', to: 'twilio#fax_status', as: :twilio_fax_status
    post 'docuseal/disability_certification', to: 'docuseal#disability_certification'
  end
end
