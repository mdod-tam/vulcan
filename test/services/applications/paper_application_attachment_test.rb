# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperApplicationAttachmentTest < ActiveSupport::TestCase
    include PaperIdentityConfirmationHelper

    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @admin = create(:admin)
      @timestamp = Time.current.to_f.to_s.gsub('.', '')

      # Set Current context to skip proof validations in tests
      Current.paper_context = true
      @income_proof = fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf')
      @residency_proof = fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
    end

    test 'can attach proofs using ActiveStorage::Blob signed_id' do
      income_blob, residency_blob = create_blobs
      params = direct_upload_params(income_blob.signed_id, residency_blob.signed_id)
      set_income_policy

      assert income_blob.persisted?, 'Income blob not persisted'
      assert residency_blob.persisted?, 'Residency blob not persisted'
      assert_not_nil income_blob.signed_id, 'Income blob missing signed_id'
      assert_not_nil residency_blob.signed_id, 'Residency blob missing signed_id'

      ProofAttachmentService.expects(:attach_proof).with(
        has_entries(
          proof_type: :income,
          status: :approved,
          submission_method: :paper
        )
      ).returns({ success: true })

      ProofAttachmentService.expects(:attach_proof).with(
        has_entries(
          proof_type: :residency,
          status: :approved,
          submission_method: :paper
        )
      ).returns({ success: true })

      service = PaperApplicationService.new(params: confirmed_paper_params(params, admin: @admin), admin: @admin)
      assert service.create, "Paper application creation failed with errors: #{service.errors.join(', ')}"
    end

    test 'a signed GlobalID is not accepted as an Active Storage upload reference' do
      income_blob, residency_blob = create_blobs
      params = direct_upload_params(income_blob.to_signed_global_id.to_s, residency_blob.to_signed_global_id.to_s)
      set_income_policy
      service = PaperApplicationService.new(params: confirmed_paper_params(params, admin: @admin), admin: @admin)

      assert_no_difference ['User.count', 'Application.count', 'Event.count', 'ActiveStorage::Attachment.count'] do
        assert_not service.create
      end
      assert_match(/no longer available/, service.errors.join(' '))
    end

    test 'an oversized direct upload is refused with the proof size limit before anything is created' do
      header = "%PDF-1.4\n"
      oversized = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(header + ('x' * (ProofUploadFormats::PROOF_MAX_BYTES + 1 - header.bytesize))),
        filename: 'income_proof.pdf', content_type: 'application/pdf'
      )
      _income_blob, residency_blob = create_blobs
      params = direct_upload_params(oversized.signed_id, residency_blob.signed_id)
      set_income_policy
      service = PaperApplicationService.new(params: confirmed_paper_params(params, admin: @admin), admin: @admin)

      assert_no_difference ['User.count', 'Application.count', 'Event.count', 'ActiveStorage::Attachment.count'] do
        assert_not service.create
      end
      assert_includes service.errors.join(' '),
                      "Income proof: #{I18n.t('documents.refused.too_large', max_size: 5)}"
    end

    test 'a new certification file with disallowed content is refused before anything is created' do
      income_blob, residency_blob = create_blobs
      disguised = Tempfile.new(['certification', '.pdf'])
      disguised.binmode
      disguised.write("MZ\x90\x00#{'x' * 4096}")
      disguised.rewind
      params = direct_upload_params(income_blob.signed_id, residency_blob.signed_id).merge(
        disability_certification_action: 'accept',
        disability_certification: ActionDispatch::Http::UploadedFile.new(tempfile: disguised, filename: 'certification.pdf',
                                                                         type: 'application/pdf')
      )
      set_income_policy
      service = PaperApplicationService.new(params: confirmed_paper_params(params, admin: @admin), admin: @admin)

      assert_no_difference ['User.count', 'Application.count', 'Event.count', 'ActiveStorage::Attachment.count'] do
        assert_not service.create
      end
      assert_includes service.errors.join(' '), I18n.t('documents.refused.invalid_type')
    ensure
      disguised&.close!
    end

    private

    def create_blobs
      income_blob = scanned_upload(@income_proof, user: @admin, purpose: :proof, slot: 'income_proof')
      residency_blob = scanned_upload(@residency_proof, user: @admin, purpose: :proof, slot: 'residency_proof')
      [income_blob, residency_blob]
    end

    def direct_upload_params(income_blob_signed_id, residency_blob_signed_id)
      {
        constituent: {
          first_name: 'Jane',
          last_name: 'Doe', date_of_birth: '01/15/1980',
          email: "jane.doe.#{@timestamp}@example.com",
          phone: "301555#{@timestamp[-4..]}",
          physical_address_1: '123 Main St',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          cognition_disability: '1'
        },
        application: {
          household_size: 1,
          annual_income: '18000',
          maryland_resident: true,
          self_certify_disability: true,
          medical_provider_name: 'Dr. Smith',
          medical_provider_phone: '301-555-1313',
          medical_provider_email: 'dr.smith@example.com'
        },
        income_proof_action: 'accept',
        income_proof: income_blob_signed_id,
        residency_proof_action: 'accept',
        residency_proof: residency_blob_signed_id
      }
    end

    def set_income_policy
      { 'fpl_1_person' => 20_000, 'fpl_modifier_percentage' => 200 }.each do |key, value|
        policy = Policy.find_or_initialize_by(key: key)
        policy.updated_by = @admin
        policy.update!(value: value)
      end
    end

    teardown do
      Current.reset
      @income_proof.tempfile.close
      @residency_proof.tempfile.close
    end
  end
end
