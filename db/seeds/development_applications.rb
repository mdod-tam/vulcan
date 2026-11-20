# frozen_string_literal: true

require 'active_support/testing/time_helpers'

module Seeds
  # Builds development examples through the same proof and lifecycle writers as intake.
  class DevelopmentApplications
    include ActiveSupport::Testing::TimeHelpers

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
      { first_name: 'Noah', last_name: 'Williams', age: 27, stage: :approved, disabilities: %w[cognition mobility], guardian: 'Patricia' },
      { first_name: 'Leah', last_name: 'Patel', age: 42, stage: :evaluation_scheduling, disabilities: %w[hearing vision], program_group: 'deafblind' },
      { first_name: 'Julian', last_name: 'Torres', age: 58, stage: :evaluation_scheduled, disabilities: %w[hearing], program_group: 'hard_of_hearing' },
      { first_name: 'Ethan', last_name: 'Cole', age: 31, stage: :needs_fulfillment, disabilities: %w[vision], program_group: 'low_vision_blind' },
      { first_name: 'Fatima', last_name: 'Ali', age: 44, stage: :awaiting_bid_award, disabilities: %w[speech], program_group: 'speech' },
      { first_name: 'Theo', last_name: 'Martin', age: 26, stage: :ready_to_send_po, disabilities: %w[mobility], program_group: 'mobility' },
      { first_name: 'Nadia', last_name: 'Bennett', age: 63, stage: :awaiting_shipment, disabilities: %w[hearing], program_group: 'deaf' },
      { first_name: 'Mateo', last_name: 'Santos', age: 37, stage: :shipment_recorded,
        disabilities: %w[hearing vision], program_group: 'deafblind', locale: 'es', icc: true },
      { first_name: 'Chloe', last_name: 'Davis', age: 22, stage: :training_scheduling, disabilities: %w[vision], program_group: 'low_vision_blind' },
      { first_name: 'Isaac', last_name: 'Green', age: 49, stage: :training_scheduled, disabilities: %w[hearing], program_group: 'hard_of_hearing' },
      { first_name: 'Amara', last_name: 'Owens', age: 54, stage: :training_completed, disabilities: %w[mobility], program_group: 'mobility' },
      { first_name: 'Nora', last_name: 'Ellis', age: 41, stage: :training_completed, disabilities: %w[hearing vision], program_group: 'deafblind', icc: true }
    ].freeze
    MERGE_EXAMPLES = [
      { email: 'user2@example.com', stage: :approved, disabilities: %w[hearing] },
      { email: 'jane.doe@example.com', stage: :archived, disabilities: %w[hearing] }
    ].freeze
    BASE_GROUP_IDENTITIES = {
      'user@example.com' => 'Test User',
      'user2@example.com' => 'Jane Doe',
      'jane.doe@example.com' => 'Jane Doe',
      'john.doe@example.com' => 'John Doe',
      'steven.cooper@example.com' => 'Steven Cooper',
      'alice.doe@example.com' => 'Alice Doe'
    }.freeze
    LOCATIONS = [%w[Baltimore 21201], %w[Frederick 21701], %w[Rockville 20850], %w[Salisbury 21801]].freeze

    def initialize(admin:)
      @admin = admin
      @now = Time.current
    end

    def call
      raise 'Development application fixtures can only run in development' unless Rails.env.development?

      Equipment::Mutation.authorize!(@admin)

      require_relative '../../test/support/document_scan_fixtures'
      require_relative 'development_equipment_workflows'

      without_external_delivery do
        examples = create_examples + create_merge_examples
        record_missing_program_groups
        examples
      end
    end

    private

    def without_external_delivery
      adapter = ActiveJob::Base.queue_adapter
      delivery_method = ActionMailer::Base.delivery_method
      perform_deliveries = ActionMailer::Base.perform_deliveries
      twilio = Rails.application.config.twilio
      ActiveJob::Base.queue_adapter = :test
      ActionMailer::Base.delivery_method = :test
      ActionMailer::Base.perform_deliveries = false
      Rails.application.config.twilio = {}
      yield
    ensure
      ActiveJob::Base.queue_adapter = adapter
      ActionMailer::Base.delivery_method = delivery_method
      ActionMailer::Base.perform_deliveries = perform_deliveries
      Rails.application.config.twilio = twilio
    end

    def create_examples
      PROFILES.each_with_index.filter_map do |profile, index|
        contacts = [applicant_email(profile)]
        contacts << "#{profile[:guardian].downcase}.#{profile[:last_name].downcase}@example.com" if profile[:guardian]
        if User.exists?(email: contacts)
          Rails.logger.info("Development example skipped: #{applicant_email(profile)} already exists.")
          next
        end
        ApplicationRecord.transaction do
          started_at = @now - (profile[:icc] ? 42 : 35 + index).days
          application = travel_to(started_at, with_usec: true) do
            applicant = create_applicant(profile, index)
            guardian = create_guardian(applicant, profile) if profile[:guardian]
            create_application(applicant, guardian, profile, index)
          end
          advance_application(application, profile.fetch(:stage), started_at)
          if application.equipment_fulfillment?
            icc = profile[:icc] && Icanconnect::Setting.active?(on: started_at)
            DevelopmentEquipmentWorkflows.new(admin: @admin, now: @now).call(
              application, profile.fetch(:stage), started_at: started_at, icc: icc
            )
          end
          application.reload
        end
      end
    end

    # Only these two deliberately duplicated seed identities are reused for merge practice.
    def create_merge_examples
      MERGE_EXAMPLES.each_with_index.filter_map do |profile, index|
        applicant = User.find_by_email(profile.fetch(:email))
        next unless applicant&.full_name == 'Jane Doe' && applicant.applications.empty?

        ApplicationRecord.transaction do
          started_at = @now - (40 + index).days
          application = travel_to(started_at, with_usec: true) { create_application(applicant, nil, profile, index) }
          advance_application(application, profile.fetch(:stage), started_at)
          application.reload
        end
      end
    end

    def applicant_email(profile)
      "#{profile.fetch(:first_name).downcase}.#{profile.fetch(:last_name).downcase}@example.com"
    end

    def create_applicant(profile, index)
      city, zip_code = LOCATIONS[index % LOCATIONS.size]
      disabilities = Users::Constituent::DISABILITY_TYPES.to_h do |type|
        ["#{type}_disability", profile.fetch(:disabilities).include?(type)]
      end
      FactoryBot.create(:constituent, **disabilities.symbolize_keys,
                        first_name: profile.fetch(:first_name), last_name: profile.fetch(:last_name),
                        email: applicant_email(profile),
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
                          application_date: profile[:stage] == :archived ? 4.years.ago.to_date : Time.current,
                          submission_method: profile.fetch(:submission_method, :online),
                          program_disability_groups: program_groups(profile),
                          maryland_resident: true, self_certify_disability: true,
                          terms_accepted: true, information_verified: true, disability_information_release_authorized: true,
                          certifying_professional_name: 'Dr. Morgan Lee', certifying_professional_email: 'provider@example.com',
                          certifying_professional_phone: '202-555-0199', household_size: (index % 5) + 1,
                          annual_income: 12_000 + (index * 1_500))
    end

    def program_groups(profile)
      return [profile[:program_group]] if profile[:program_group]

      disabilities = profile.fetch(:disabilities)
      return ['deafblind'] if disabilities.include?('hearing') && disabilities.include?('vision')

      { 'hearing' => 'deaf', 'vision' => 'low_vision_blind', 'speech' => 'speech', 'mobility' => 'mobility' }
        .filter_map { |disability, group| group if disabilities.include?(disability) }
    end

    def record_missing_program_groups
      profiles = PROFILES.index_by { |profile| applicant_email(profile) }
      identities = profiles.transform_values { |profile| "#{profile.fetch(:first_name)} #{profile.fetch(:last_name)}" }.merge(BASE_GROUP_IDENTITIES)
      identities.each do |email, name|
        applicant = User.find_by_email(email)
        next unless applicant.is_a?(Users::Constituent) && applicant.full_name == name

        profile = profiles.fetch(email) do
          { disabilities: Users::Constituent::DISABILITY_TYPES.select { |type| applicant.public_send("#{type}_disability?") } }
        end
        groups = program_groups(profile)
        next if groups.empty?

        applicant.applications.where(program_disability_groups: []).find_each do |application|
          application.with_lock do
            next if application.program_disability_groups.any?

            application.update!(program_disability_groups: groups)
            Equipment::Mutation.audit!(application, actor: @admin, action: 'equipment_profile_updated',
                                                    changes: application.previous_changes.except('updated_at'),
                                                    reason: 'Filled missing disability groups in development seed data.')
          end
        end
      end
    end

    def advance_application(application, stage, started_at)
      return if stage == :draft

      travel_to(started_at + 1.day, with_usec: true) do
        types = stage.in?(%i[missing_proofs reminder_sent]) ? [:id] : proof_types(application)
        types.each { |type| attach_proof(application, type) }
        application.submit!(actor: application.managing_guardian || application.user)
      end

      travel_to(started_at + 3.days, with_usec: true) do
        review_stage(application, stage)
      end
      complete_certification(application, stage, started_at) unless stage.in?(%i[partial_review rejected_proof missing_proofs reminder_sent rejected submitted
                                                                                 awaiting_dcf])
    end

    def review_stage(application, stage)
      case stage
      when :partial_review
        review_proofs(application, proof_types(application) - [:id])
      when :rejected_proof
        rejected_type = application.income_proof_required? ? :income : :residency
        review_proofs(application, proof_types(application) - [rejected_type])
        Applications::ProofReviewer.new(application, @admin).review(
          **proof_decision_identity(application, rejected_type, :rejected),
          proof_type: rejected_type, status: :rejected,
          rejection_reason: "The #{rejected_type} document is unreadable. Please upload a clearer copy."
        )
        transition(application, :awaiting_proof, "Waiting for a clearer #{rejected_type} document")
      when :missing_proofs, :reminder_sent
        transition(application, :awaiting_proof, 'Paper intake awaiting supporting documents')
        transition(application, :reminder_sent, 'Reminder to supply outstanding documents') if stage == :reminder_sent
      when :rejected
        transition(application, :rejected, 'Applicant does not meet program eligibility requirements')
      when :submitted
        # Uploaded proofs remain in the review queue.
      else
        review_proofs(application, proof_types(application))
      end
    end

    def complete_certification(application, stage, started_at)
      travel_to(started_at + 5.days, with_usec: true) do
        status = stage.in?(%i[certification_received certification_rejected]) ? :received : :approved
        blob = fixture_document('disability_certification.pdf', purpose: :certification, slot: 'disability_certification', owner: @admin)
        DisabilityCertificationAttachmentService.attach_certification(application: application, blob_or_file: blob, status: status, admin: @admin)
        if stage == :certification_rejected
          DisabilityCertificationAttachmentService.reject_certification(
            **proof_decision_identity(application, :disability_certification, :rejected),
            application: application, admin: @admin, reason: 'Provider signature is missing.'
          )
        elsif stage == :archived
          transition(application, :archived, 'Historical application outside the service window')
        end
      end
      travel_to(started_at + 7.days, with_usec: true) do
        if stage == :training_requested
          result = Applications::TrainingRequestService.new(application: application, current_user: application.user).call
          raise "Development training request failed: #{result.message}" unless result.success?
        elsif stage == :evaluation_requested
          application.request_evaluation!(actor: @admin)
        end
      end
    end

    def proof_types(application)
      application.income_proof_required? ? %i[income residency id] : %i[residency id]
    end

    def attach_proof(application, type)
      submission_method = { 'paper' => :paper, 'email' => :email }.fetch(application.submission_method, :web)
      blob = fixture_document("#{type}_proof.pdf", purpose: :proof, slot: "#{type}_proof", owner: application.user)
      result = ProofAttachmentService.attach_proof(application: application, proof_type: type, blob_or_file: blob,
                                                   submission_method: submission_method, scan_owner: application.user,
                                                   admin: @admin)
      raise result[:error] unless result[:success]
    end

    def review_proofs(application, types)
      types.each do |type|
        Applications::ProofReviewer.new(application, @admin).review(
          **proof_decision_identity(application, type, :approved), proof_type: type, status: :approved
        )
      end
    end

    def proof_decision_identity(application, type, status)
      { decision_key: "development:#{type}:#{status}", reviewed_blob_id: application.document_attachment_for(type).blob&.id }
    end

    def with_document(filename)
      Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open do |file|
        yield ActionDispatch::Http::UploadedFile.new(tempfile: file, filename: filename, type: 'application/pdf')
      end
    end

    # Repository fixtures are synthetic examples, not user uploads or paid scans.
    def fixture_document(filename, purpose:, slot:, owner:)
      with_document(filename) do |upload|
        blob = ActiveStorage::Blob.create_and_upload!(io: upload.tempfile, filename: filename, content_type: 'application/pdf')
        DocumentScanFixtures.clear!(blob, user: owner, purpose: purpose, slot: slot, fixture: 'disability_certification_valid.pdf')
      end
    end

    def transition(application, status, notes)
      application.transition_status!(status, actor: @admin, notes: notes, metadata: { trigger: 'development_seed' })
    end
  end
end
