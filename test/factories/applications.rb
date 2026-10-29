# frozen_string_literal: true

require_relative '../support/document_scan_fixtures' if Rails.env.test?

FactoryBot.define do
  factory :application do
    user factory: %i[constituent with_disabilities], strategy: :create

    # The model can infer managing_guardian from a GuardianRelationship.

    status { :in_progress }
    income_proof_status { :not_reviewed }
    residency_proof_status { :not_reviewed }
    disability_certification_status { :not_requested }

    application_date { 4.years.ago }
    maryland_resident { true }
    self_certify_disability { true }
    certifying_professional_name { generate(:certifying_professional_name) }
    certifying_professional_phone { generate(:certifying_professional_phone) }
    certifying_professional_fax { generate(:certifying_professional_fax) }
    certifying_professional_email { generate(:certifying_professional_email) }
    household_size { 4 }
    annual_income  { 50_000 }

    transient do
      skip_proofs { false }
      use_mock_attachments { false }
    end

    # Application states
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
      id_proof_status { :approved }
    end

    trait :completed do
      status { :approved }
      income_proof_status { :approved }
      residency_proof_status { :approved }
      id_proof_status { :approved }
      disability_certification_status { :approved }
      terms_accepted { true }
      information_verified { true }
      disability_information_release_authorized { true }
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
      disability_information_release_authorized { true }
      total_rejections { 1 }
      needs_review_since { Time.current }
      last_activity_at { Time.current }
    end

    trait :archived do
      status { :archived }
      income_proof_status { :approved }
      residency_proof_status { :approved }
      id_proof_status { :approved }
      terms_accepted { true }
      information_verified { true }
      disability_information_release_authorized { true }
      application_date { 8.years.ago }
      last_activity_at { 8.years.ago }
    end

    # Use this trait for tests with multiple applications per applicant.
    # The dates exceed the default three-year waiting period.
    trait :old_enough_for_new_application do
      application_date { 4.years.ago }
      last_activity_at { 4.years.ago }
    end

    trait :with_rejected_proofs do
      status { :awaiting_proof }
      income_proof_status { :rejected }
      residency_proof_status { :rejected }
      needs_review_since { Time.current }
      last_activity_at { Time.current }

      # This trait represents rejected uploads from the constituent portal.
      after(:create) do |application|
        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.income_proof.blob, user: application.user,
                                                                     purpose: :proof, slot: 'income_proof',
                                                                     fixture: 'disability_certification_valid.pdf')
        end
        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.residency_proof.blob, user: application.user,
                                                                        purpose: :proof, slot: 'residency_proof',
                                                                        fixture: 'disability_certification_valid.pdf')
        end
      end
    end

    trait :paper_rejected_proofs do
      status { :awaiting_proof }

      # This trait represents paper proofs rejected without uploads.
      after(:create) do |application|
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

    # Attachment traits
    trait :with_income_proof do
      after(:create) do |application|
        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.income_proof.blob, user: application.user,
                                                                     purpose: :proof, slot: 'income_proof',
                                                                     fixture: 'disability_certification_valid.pdf')
        end
      end
    end

    trait :with_residency_proof do
      after(:create) do |application|
        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.residency_proof.blob, user: application.user,
                                                                        purpose: :proof, slot: 'residency_proof',
                                                                        fixture: 'disability_certification_valid.pdf')
        end
      end
    end

    trait :with_id_proof do
      after(:create) do |application|
        application.id_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'id_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.id_proof.blob, user: application.user,
                                                                 purpose: :proof, slot: 'id_proof',
                                                                 fixture: 'disability_certification_valid.pdf')
        end
      end
    end

    trait :with_disability_certification do
      after(:create) do |application|
        application.disability_certification.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'disability_certification.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.disability_certification.blob, user: application.user,
                                                                                 purpose: :certification, slot: 'disability_certification',
                                                                                 fixture: 'disability_certification_valid.pdf')
        end
      end
    end

    trait :with_all_proofs do
      with_income_proof
      with_residency_proof
      with_id_proof
      with_disability_certification
    end

    trait :with_disability_certification_requested do
      disability_certification_status { :requested }
    end

    trait :in_progress_with_pending_proofs do
      status { :in_progress }
      income_proof_status { :not_reviewed }
      residency_proof_status { :not_reviewed }
      needs_review_since { Time.current }

      after(:create) do |application|
        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.income_proof.blob, user: application.user,
                                                                     purpose: :proof, slot: 'income_proof',
                                                                     fixture: 'disability_certification_valid.pdf')
        end

        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.residency_proof.blob, user: application.user,
                                                                        purpose: :proof, slot: 'residency_proof',
                                                                        fixture: 'disability_certification_valid.pdf')
        end

        # Submission events make needs_proof_type_review? true before any review exists.
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
        application.income_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'income_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.income_proof.blob, user: application.user,
                                                                     purpose: :proof, slot: 'income_proof',
                                                                     fixture: 'disability_certification_valid.pdf')
        end
        application.residency_proof.attach(
          io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf'
        )
        if Rails.env.test?
          DocumentScanFixtures.clear!(application.residency_proof.blob, user: application.user,
                                                                        purpose: :proof, slot: 'residency_proof',
                                                                        fixture: 'disability_certification_valid.pdf')
        end
      end
    end

    trait :for_dependent do
      transient do
        guardian { create(:constituent, first_name: 'Guardian', last_name: 'User') }
        dependent_attrs { { first_name: 'Dependent', last_name: 'User' } }
        relationship_type { 'Parent' }
      end

      user factory: %i[constituent] # The after(:build) callback replaces this association with the dependent.

      after(:build) do |application, evaluator|
        dependent_user = create(:constituent, evaluator.dependent_attrs)
        application.user = dependent_user
        application.managing_guardian = evaluator.guardian

        unless GuardianRelationship.exists?(guardian_user: evaluator.guardian, dependent_user: dependent_user)
          create(:guardian_relationship, guardian_user: evaluator.guardian, dependent_user: dependent_user,
                                         relationship_type: evaluator.relationship_type)
        end
      end
    end

    trait :voucher_fulfillment do
      after(:create) do |app|
        app.update_columns(fulfillment_type: Application.fulfillment_types[:voucher])
      end
    end

    trait :income_not_required do
      after(:create) do |app|
        app.update_columns(income_proof_required: false)
      end
    end

    # Alias for :for_dependent.
    trait :submitted_by_guardian do
      for_dependent
    end

    # Alias for :for_dependent with relationship_type: 'Legal Guardian'.
    trait :submitted_by_legal_guardian do
      for_dependent { { relationship_type: 'Legal Guardian' } }
    end
  end
end
