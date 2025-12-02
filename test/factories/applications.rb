# frozen_string_literal: true

FactoryBot.define do
  factory :application do
    # Required associations
    user factory: %i[constituent with_disabilities], strategy: :create

    # Make managing_guardian truly optional by not specifying it by default
    # It will be nil unless explicitly set in the test

    # Base status fields with default values
    status { :in_progress }
    income_proof_status { :not_reviewed }
    residency_proof_status { :not_reviewed }
    medical_certification_status { :not_requested }

    # Other required fields
    application_date { 4.years.ago }
    maryland_resident { true }
    self_certify_disability { true }
    medical_provider_name { generate(:medical_provider_name) }
    medical_provider_phone { generate(:medical_provider_phone) }
    medical_provider_fax { generate(:medical_provider_fax) }
    medical_provider_email { generate(:medical_provider_email) }
    household_size { 4 }
    annual_income  { 50_000 }

    transient do
      skip_proofs { false }
      use_mock_attachments { false } # Whether to use mock_attached_file instead of real attachments
    end

    # Simple traits for different application states
    trait :draft do
      status { :draft }
    end

    trait :in_progress do
      status { :in_progress }
    end

    trait :approved do
      status { :approved }
      income_proof_status { :approved }
      residency_proof_status { :approved }
    end

    trait :completed do
      status { :approved }
      income_proof_status { :approved }
      residency_proof_status { :approved }
      medical_certification_status { :approved }
      terms_accepted { true }
      information_verified { true }
      medical_release_authorized { true }
      income_verified_at { Time.current }
      last_activity_at { Time.current }
      income_verified_by factory: %i[admin]
    end

    trait :rejected do
      status { :rejected }
      income_proof_status { :rejected }
      residency_proof_status { :rejected }
      terms_accepted { true }
      information_verified { true }
      medical_release_authorized { true }
      total_rejections { 1 }
      needs_review_since { Time.current }
      last_activity_at { Time.current }
    end

    trait :archived do
      status { :archived }
      income_proof_status { :approved }
      residency_proof_status { :approved }
      terms_accepted { true }
      information_verified { true }
      medical_release_authorized { true }
      application_date { 8.years.ago }
      last_activity_at { 8.years.ago }
    end

    # Trait for applications that are old enough to allow new applications
    # Use this when tests need to create multiple applications for the same user
    trait :old_enough_for_new_application do
      application_date { 4.years.ago } # Older than the 3-year waiting period
      last_activity_at { 4.years.ago }
    end

    trait :with_rejected_proofs do
      status { :needs_information }
      income_proof_status { :rejected }
      residency_proof_status { :rejected }
      needs_review_since { Time.current }
      last_activity_at { Time.current }

      # This trait represents the constituent portal scenario where
      # proofs were uploaded and then rejected by admin review
      after(:create) do |application|
        # Attach sample proofs to represent the uploaded-then-rejected scenario
        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
      end
    end

    trait :paper_rejected_proofs do
      status { :needs_information }

      # This trait represents the paper application scenario where
      # admin rejected proofs without uploading them (paper workflow)
      after(:create) do |application|
        # Use update_columns to bypass validations for this specific paper scenario
        application.update_columns(
          income_proof_status: Application.income_proof_statuses[:rejected],
          residency_proof_status: Application.residency_proof_statuses[:rejected],
          needs_review_since: nil
        )
      end
    end

    trait :with_approved_proofs do
      income_proof_status { :approved }
      residency_proof_status { :approved }
    end

    # Clean attachment traits using real files
    trait :with_income_proof do
      after(:create) do |application|
        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
      end
    end

    trait :with_residency_proof do
      after(:create) do |application|
        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
      end
    end

    trait :with_medical_certification do
      after(:create) do |application|
        application.medical_certification.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'medical_certification.pdf',
          content_type: 'application/pdf'
        )
      end
    end

    trait :with_all_proofs do
      with_income_proof
      with_residency_proof
      with_medical_certification
    end

    # Trait for testing medical certification upload workflow
    trait :with_medical_certification_requested do
      medical_certification_status { :requested }
    end

    trait :in_progress_with_pending_proofs do
      status { :in_progress }
      income_proof_status { :not_reviewed }
      residency_proof_status { :not_reviewed }
      needs_review_since { Time.current }

      after(:create) do |application|
        # Attach proofs that need review

        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )

        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )

        # Create audit events for proof submissions so needs_proof_type_review? returns true
        Event.create!(
          user: application.user,
          action: 'income_proof_submitted',
          auditable: application,
          metadata: {
            application_id: application.id,
            proof_type: 'income',
            submission_method: 'web'
          },
          created_at: 1.hour.ago
        )

        Event.create!(
          user: application.user,
          action: 'residency_proof_submitted',
          auditable: application,
          metadata: {
            application_id: application.id,
            proof_type: 'residency',
            submission_method: 'web'
          },
          created_at: 1.hour.ago
        )
      end
    end

    trait :in_progress_with_rejected_proofs do
      status { :in_progress }
      income_proof_status { :rejected }
      residency_proof_status { :rejected }
      needs_review_since { Time.current }
      last_activity_at { Time.current }

      after(:create) do |application|
        # Attach proofs that were rejected
        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
      end
    end

    # This trait creates an application for a dependent, managed by a guardian.
    trait :for_dependent do
      transient do
        guardian { create(:constituent, first_name: 'Guardian', last_name: 'User') }
        dependent_attrs { { first_name: 'Dependent', last_name: 'User' } } # Pass attributes for the dependent
        relationship_type { 'Parent' }
      end

      # The main `user` of the application is the dependent.
      user factory: %i[constituent] # This will be overridden by the dependent created below

      after(:build) do |application, evaluator|
        # Ensure dependent is created using transient attributes
        dependent_user = create(:constituent, evaluator.dependent_attrs)
        application.user = dependent_user # Explicitly set the application's user to the dependent
        application.managing_guardian = evaluator.guardian

        # Create the relationship if it doesn't exist
        unless GuardianRelationship.exists?(guardian_user: evaluator.guardian, dependent_user: dependent_user)
          create(:guardian_relationship, guardian_user: evaluator.guardian, dependent_user: dependent_user,
                                         relationship_type: evaluator.relationship_type)
        end
      end
    end

    # DEPRECATED: Use :for_dependent trait for more clarity.
    trait :submitted_by_guardian do
      for_dependent # Delegates to the new :for_dependent trait
    end

    # DEPRECATED: Use :for_dependent trait with relationship_type: 'Legal Guardian'.
    trait :submitted_by_legal_guardian do
      for_dependent { { relationship_type: 'Legal Guardian' } } # Delegates with specific relationship
    end
  end
end
