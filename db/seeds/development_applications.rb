# frozen_string_literal: true

module Seeds
  # Builds development examples through the same proof and lifecycle writers as intake.
  class DevelopmentApplications
    PROFILES = [
      { first_name: 'Maya', last_name: 'Brooks', age: 19, stage: :draft, disabilities: %w[hearing] },
      { first_name: 'Lucia', last_name: 'Rivera', age: 34, stage: :submitted, disabilities: %w[speech], locale: 'es' },
      { first_name: 'Walter', last_name: 'Chen', age: 78, stage: :partial_review, disabilities: %w[hearing vision], phone_type: :videophone },
      { first_name: 'Denise', last_name: 'Carter', age: 62, stage: :missing_proofs, disabilities: %w[mobility], submission_method: :paper },
      { first_name: 'Omar', last_name: 'Hassan', age: 45, stage: :rejected_proof, disabilities: %w[hearing] },
      { first_name: 'Rosa', last_name: 'Martinez', age: 71, stage: :reminder_sent, disabilities: %w[vision], locale: 'es', submission_method: :paper },
      { first_name: 'Priya', last_name: 'Shah', age: 29, stage: :awaiting_dcf, disabilities: %w[vision] },
      { first_name: 'James', last_name: 'Wilson', age: 56, stage: :certification_received, disabilities: %w[mobility speech], submission_method: :email },
      { first_name: 'Elena', last_name: 'Garcia', age: 48, stage: :certification_rejected, disabilities: %w[cognition], locale: 'es' },
      { first_name: 'Samuel', last_name: 'Reed', age: 67, stage: :approved, disabilities: %w[hearing], phone_type: :videophone },
      { first_name: 'Aisha', last_name: 'Johnson', age: 39, stage: :training_requested, disabilities: %w[vision mobility] },
      { first_name: 'Daniel', last_name: 'Kim', age: 23, stage: :evaluation_requested, disabilities: %w[speech cognition], phone_type: :text },
      { first_name: 'Grace', last_name: 'Thompson', age: 52, stage: :rejected, disabilities: %w[hearing], submission_method: :phone },
      { first_name: 'Henry', last_name: 'Davis', age: 83, stage: :archived, disabilities: %w[vision hearing] },
      { first_name: 'Sofia', last_name: 'Perez', age: 12, stage: :awaiting_dcf, disabilities: %w[speech], locale: 'es', guardian: 'Isabel' },
      { first_name: 'Noah', last_name: 'Williams', age: 27, stage: :approved, disabilities: %w[cognition mobility], guardian: 'Patricia' }
    ].freeze
    LOCATIONS = [%w[Baltimore 21201], %w[Frederick 21701], %w[Rockville 20850], %w[Salisbury 21801]].freeze

    def initialize(admin:)
      @admin = admin
    end

    def call
      PROFILES.each_with_index.map do |profile, index|
        applicant = create_applicant(profile, index)
        guardian = create_guardian(applicant, profile) if profile[:guardian]
        application = create_application(applicant, guardian, profile, index)
        advance_application(application, profile.fetch(:stage))
        application.reload
      end
    end

    private

    def create_applicant(profile, index)
      city, zip_code = LOCATIONS[index % LOCATIONS.size]
      disabilities = Users::Constituent::DISABILITY_TYPES.to_h do |type|
        ["#{type}_disability", profile.fetch(:disabilities).include?(type)]
      end
      FactoryBot.create(:constituent, **disabilities.symbolize_keys,
                        first_name: profile.fetch(:first_name), last_name: profile.fetch(:last_name),
                        email: "#{profile.fetch(:first_name).downcase}.#{profile.fetch(:last_name).downcase}@example.com",
                        phone: format('202-555-01%02d', index), phone_type: profile.fetch(:phone_type, :voice),
                        date_of_birth: profile.fetch(:age).years.ago.to_date, locale: profile.fetch(:locale, 'en'),
                        physical_address_1: "#{100 + index} Example Lane", city: city, zip_code: zip_code)
    end

    def create_guardian(applicant, profile)
      guardian = FactoryBot.create(:constituent,
                                   first_name: profile.fetch(:guardian), last_name: applicant.last_name,
                                   email: "#{profile.fetch(:guardian).downcase}.#{applicant.last_name.downcase}@example.com",
                                   date_of_birth: 49.years.ago.to_date, locale: applicant.locale,
                                   physical_address_1: applicant.physical_address_1, city: applicant.city, zip_code: applicant.zip_code)
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: applicant,
                                   relationship_type: profile.fetch(:age) < 18 ? 'Parent' : 'Legal Guardian')
      applicant.update!(dependent_email: guardian.email, dependent_phone: guardian.phone)
      guardian
    end

    def create_application(applicant, guardian, profile, index)
      Application.create!(user: applicant, managing_guardian: guardian, status: :draft,
                          application_date: profile[:stage] == :archived ? 4.years.ago.to_date : (index + 1).days.ago.to_date,
                          submission_method: profile.fetch(:submission_method, :online),
                          maryland_resident: true, self_certify_disability: true,
                          terms_accepted: true, information_verified: true, medical_release_authorized: true,
                          medical_provider_name: 'Dr. Morgan Lee', medical_provider_email: 'provider@example.com',
                          medical_provider_phone: '202-555-0199', household_size: (index % 5) + 1,
                          annual_income: 12_000 + (index * 1_500))
    end

    def advance_application(application, stage)
      return if stage == :draft

      proof_types(application).each { |type| attach_proof(application, type) } unless stage.in?(%i[missing_proofs reminder_sent])
      application.submit!(actor: application.managing_guardian || application.user)

      case stage
      when :partial_review
        review_proofs(application, proof_types(application) - [:id])
      when :rejected_proof
        review_proofs(application, proof_types(application) - [:id])
        Applications::ProofReviewer.new(application, @admin).review(
          proof_type: :id, status: :rejected, rejection_reason: 'The photo ID is unreadable. Please upload a clearer copy.'
        )
        transition(application, :awaiting_proof, 'Waiting for a clearer photo ID')
      when :missing_proofs, :reminder_sent
        transition(application, :awaiting_proof, 'Paper intake awaiting supporting documents')
        transition(application, :reminder_sent, 'Reminder to supply outstanding documents') if stage == :reminder_sent
      when :rejected
        transition(application, :rejected, 'Applicant does not meet program eligibility requirements')
      when :submitted
        # Uploaded proofs remain in the review queue.
      else
        complete_proof_review(application, stage)
      end
    end

    def complete_proof_review(application, stage)
      review_proofs(application, proof_types(application))
      return if stage == :awaiting_dcf

      status = stage.in?(%i[certification_received certification_rejected]) ? :received : :approved
      blob = stage_clean_scan('medical_certification.pdf', purpose: :certification,
                                                           slot: 'medical_certification', owner: @admin)
      MedicalCertificationAttachmentService.attach_certification(
        application: application, blob_or_file: blob, status: status, admin: @admin
      )

      case stage
      when :certification_rejected
        MedicalCertificationAttachmentService.reject_certification(
          application: application, admin: @admin, reason: 'Provider signature is missing.'
        )
      when :archived
        transition(application, :archived, 'Historical application outside the service window')
      when :training_requested
        result = Applications::TrainingRequestService.new(application: application, current_user: application.user).call
        raise "Development training request failed: #{result.message}" unless result.success?
      when :evaluation_requested
        application.request_evaluation!(actor: @admin)
      end
    end

    def proof_types(application)
      application.income_proof_required? ? %i[income residency id] : %i[residency id]
    end

    def attach_proof(application, type)
      submission_method = { 'paper' => :paper, 'email' => :email }.fetch(application.submission_method, :web)
      blob = stage_clean_scan("#{type}_proof.pdf", purpose: :proof, slot: "#{type}_proof", owner: application.user)
      result = ProofAttachmentService.attach_proof(application: application, proof_type: type, blob_or_file: blob,
                                                   submission_method: submission_method, scan_owner: application.user,
                                                   admin: @admin)
      raise result[:error] unless result[:success]
    end

    def review_proofs(application, types)
      types.each do |type|
        Applications::ProofReviewer.new(application, @admin).review(proof_type: type, status: :approved)
      end
    end

    def with_document(filename)
      Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open do |file|
        yield ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: 'application/pdf')
      end
    end

    # The scan gate refuses unstaged uploads. Stage each document through DocumentScan and clear it
    # as trusted fixture content. Ownership must match the attachment service's scan owner: the
    # applicant owns proof scans, staff own certification uploads, which also keeps each owner far
    # below DocumentScan's daily staging limit.
    def stage_clean_scan(filename, purpose:, slot:, owner:)
      with_document(filename) do |upload|
        scan = DocumentScan.stage!(input: upload, purpose: purpose, slot: slot, user: owner)
        scan.update!(status: :clean, completed_at: Time.current)
        scan.blob
      end
    end

    def transition(application, status, notes)
      application.transition_status!(status, actor: @admin, notes: notes, metadata: { trigger: 'development_seed' })
    end
  end
end
