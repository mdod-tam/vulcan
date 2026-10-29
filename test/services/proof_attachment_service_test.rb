# frozen_string_literal: true

require 'test_helper'

class ProofAttachmentServiceTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess
  include ProofResubmissionTestHelper

  setup do
    setup_active_storage_test

    @admin = create(:admin)
    @constituent = create(:constituent)

    @application = create(:application,
                          user: @constituent,
                          household_size: 2,
                          annual_income: 15_000)

    pdf_file_path = Rails.root.join('test/fixtures/files/income_proof.pdf')
    @raw_file_upload = ActionDispatch::Http::UploadedFile.new(
      tempfile: File.open(pdf_file_path),
      filename: 'income_proof.pdf',
      type: 'application/pdf'
    )
    @test_file_upload = scanned_upload(@raw_file_upload, user: @admin)
  end

  teardown do
    @raw_file_upload.tempfile.close if @raw_file_upload&.tempfile.respond_to?(:close)
  end

  test 'attach_proof successfully attaches a proof and updates status' do
    Event.delete_all
    AuditEventService.stubs(:recent_duplicate_exists?).returns(false)

    result = ProofAttachmentService.attach_proof({
                                                   application: @application,
                                                   proof_type: 'income',
                                                   blob_or_file: @test_file_upload,
                                                   status: :approved,
                                                   admin: @admin,
                                                   submission_method: :paper,
                                                   metadata: { ip_address: '127.0.0.1' }
                                                 })

    assert result[:success], 'Expected attach_proof to succeed'
    assert_not_nil result[:duration_ms], 'Expected duration to be tracked'

    @application.reload

    assert @application.income_proof.attached?, 'Expected income proof to be attached'
    assert @application.income_proof_status_approved?, 'Expected income proof status to be approved'

    event = Event.last
    assert_not_nil event, 'Expected an event to be created'
    assert_equal 'income_proof_attached', event.action
    assert_equal @application.id, event.auditable_id
    assert_equal 'Application', event.auditable_type
    assert_equal @admin.id, event.user_id
    assert_equal 'income', event.metadata['proof_type']
    assert_equal 'paper', event.metadata['submission_method']
    assert_equal 'approved', event.metadata['status']
    assert_not_nil event.metadata['blob_id'], 'Expected blob_id in metadata to not be nil'
  end

  test 'attach_proof records passed proof submission method instead of application submission channel' do
    Event.delete_all
    @application.update!(submission_method: :online)

    result = ProofAttachmentService.attach_proof({
                                                   application: @application,
                                                   proof_type: 'income',
                                                   blob_or_file: scanned_upload(@raw_file_upload, user: @constituent),
                                                   status: :not_reviewed,
                                                   admin: nil,
                                                   submission_method: :secure_form,
                                                   metadata: {}
                                                 })

    assert result[:success], 'Expected attach_proof to succeed'

    event = Event.where(action: 'income_proof_attached').order(:created_at).last
    assert_not_nil event, 'Expected an income_proof_attached event'
    assert_equal 'secure_form', event.metadata['submission_method']
  end

  test 'attach_proof handles errors gracefully' do
    Event.delete_all
    private_detail = 'Private Patient private-proof@example.test at 410-555-0199 token=private-proof-token'
    error = StandardError.new(private_detail)
    error.set_backtrace(["#{private_detail}:1:in failure"])
    @application.stubs(:income_proof).raises(error)
    previous_status = @application.income_proof_status
    messages = []
    capture_message = ->(message = nil, &block) { messages << (message || block&.call) }

    result = Rails.logger.stub(:error, capture_message) do
      Rails.logger.stub(:debug, capture_message) do
        ProofAttachmentService.attach_proof({
                                              application: @application,
                                              proof_type: 'income',
                                              blob_or_file: @test_file_upload,
                                              status: :approved,
                                              admin: @admin,
                                              submission_method: :paper,
                                              metadata: { ip_address: '127.0.0.1' }
                                            })
      end
    end

    assert_not result[:success], 'Expected attach_proof to fail'
    assert_same error, result[:error]
    assert_equal private_detail, result[:error].message
    assert_not_nil result[:duration_ms], 'Expected duration to be tracked'
    assert_equal previous_status, @application.reload.income_proof_status

    event = Event.last
    assert_equal 'income_proof_attachment_failed', event.action
    assert_equal @application.id, event.auditable_id
    assert_equal 'Application', event.auditable_type
    assert_equal @admin.id, event.user_id
    assert_equal 'StandardError', event.metadata['error_class']
    assert_equal 'paper', event.metadata['submission_method']
    assert_equal false, event.metadata['success']
    assert_equal 'income', event.metadata['proof_type']
    assert_not event.metadata.key?('error_message')
    assert_not event.metadata.key?('error_backtrace')
    assert_includes messages.join, 'StandardError'
    assert_includes messages.join, "application #{@application.id}"
    [messages.join, event.metadata.to_json].each do |diagnostics|
      %w[Private private-proof@example.test 410-555-0199 private-proof-token].each do |private_value|
        assert_not_includes diagnostics, private_value
      end
    end
  end

  test 'a refused upload is audited against the stored application without saving rolled-back changes' do
    stored_income = @application.annual_income
    refused = fixture_file_upload('invalid.exe', 'application/octet-stream')

    assert_difference -> { Event.where(action: 'income_proof_attachment_failed', auditable: @application).count }, 1 do
      ApplicationRecord.transaction do
        @application.annual_income = stored_income + 1
        result = ProofAttachmentService.attach_proof(application: @application, proof_type: :income, blob_or_file: refused,
                                                     admin: @admin, submission_method: :paper)
        assert_kind_of UploadedDocument::Refused, result[:error]
        raise ActiveRecord::Rollback
      end
    end
    assert_equal stored_income, @application.reload.annual_income
  end

  test 'a refused upload outside a caller transaction is audited immediately' do
    refused = fixture_file_upload('invalid.exe', 'application/octet-stream')

    assert_difference -> { Event.where(action: 'income_proof_attachment_failed', auditable: @application).count }, 1 do
      ProofAttachmentService.attach_proof(application: @application, proof_type: :income, blob_or_file: refused,
                                          admin: @admin, submission_method: :web)
    end
  end

  test 'reject_proof_without_attachment sets rejected status without attachment' do
    Event.delete_all

    result = without_auto_resubmission do
      ProofAttachmentService.reject_proof_without_attachment(
        application: @application,
        proof_type: 'income',
        admin: @admin,
        submission_method: :paper,
        reason: 'invalid_document',
        notes: 'Document does not meet requirements',
        metadata: { ip_address: '127.0.0.1' }
      )
    end

    assert result[:success], 'Expected reject_proof_without_attachment to succeed'
    assert_not_nil result[:duration_ms], 'Expected duration to be tracked'
    assert @application.income_proof_status_rejected?, 'Expected income proof status to be rejected'

    proof_review = @application.proof_reviews.last
    assert_equal 'income', proof_review.proof_type
    assert_equal 'rejected', proof_review.status
    assert_equal 'invalid_document', proof_review.rejection_reason

    # ProofReview owns the generic proof_rejected audit event.
    # A typed income_proof_rejected event would duplicate it.
    assert_empty Event.where(action: 'income_proof_rejected'), 'Did not expect a typed income_proof_rejected event'

    event = Event.where(action: 'proof_rejected').order(:created_at).last
    assert_not_nil event, 'Expected a generic proof_rejected audit event'
    assert_equal @application.id, event.auditable_id
    assert_equal 'Application', event.auditable_type
    assert_equal @admin.id, event.user_id
    assert_equal 'income', event.metadata['proof_type']
    assert_equal 'paper', event.metadata['submission_method']
  end

  test 'a paper rejection states the applicant address the way every other rejection does' do
    @constituent.update!(physical_address_1: '123 Main St', physical_address_2: 'Apt 4', city: 'Baltimore', state: 'MD', zip_code: '21201')

    reject_on_paper('residency', reason: 'address_mismatch')

    review = @application.proof_reviews.find_by!(proof_type: 'residency', status: 'rejected')
    assert_equal 'address_mismatch', review.rejection_reason_code
    assert_includes review.rejection_reason, '123 Main St Apt 4 Baltimore, MD 21201'
  end

  test 'a repeat paper rejection of the same proof updates its review and still counts as a rejection' do
    reject_on_paper('income', reason: 'First reason')
    first_review = @application.proof_reviews.find_by!(proof_type: 'income', status: 'rejected')

    reject_on_paper('income', reason: 'Second reason')

    reviews = @application.proof_reviews.where(proof_type: 'income', status: 'rejected')
    assert_equal [first_review.id], reviews.ids, 'a repeat decision keeps one row'
    assert_equal 'Second reason', first_review.reload.rejection_reason
    assert_equal 2, @application.reload.total_rejections, 'each rejection counts, first or repeat'
    assert_equal 2, Event.where(action: 'proof_rejected', auditable: @application).count, 'each rejection is audited'
  end

  test 'rejecting two different proofs in one intake records an audit event for each' do
    reject_on_paper('income', reason: 'Unreadable')
    reject_on_paper('residency', reason: 'Unreadable')

    events = Event.where(action: 'proof_rejected', auditable: @application).order(:id)
    proof_types = events.map { |event| event.metadata['proof_type'] }
    assert_equal %w[income residency], proof_types
  end

  test 'an attachment logs one outcome line naming the proof and its status' do
    log = StringIO.new
    blob = stored_pdf_blob(3.kilobytes)
    result = Rails.stub(:logger, ActiveSupport::Logger.new(log)) { attach_income(blob.signed_id) }

    assert result[:success], result[:error]&.message
    assert_equal 1, log.string.scan(/Proof income not_reviewed completed in \d+ms/).size
  end

  test 'a refused attachment returns its error and logs it in the outcome line' do
    log = StringIO.new
    refused = fixture_file_upload('invalid.exe', 'application/octet-stream')
    result = Rails.stub(:logger, ActiveSupport::Logger.new(log)) { attach_income(refused) }

    assert_not result[:success]
    assert_kind_of UploadedDocument::Refused, result[:error]
    assert_equal %i[duration_ms error success], result.keys.sort
    assert_equal 1, log.string.scan(/Proof income not_reviewed failed in \d+ms: UploadedDocument::Refused/).size
  end

  test 'a failure after the attachment succeeded reports the operation as failed' do
    NotificationService.stubs(:create_and_deliver!).raises(RuntimeError, 'notification write failed')

    result = attach_income(stored_pdf_blob(3.kilobytes).signed_id)

    assert_not result[:success], 'a step after the attachment failed, so the operation did not succeed'
    assert_equal 'notification write failed', result[:error].message
    assert_not @application.reload.income_proof.attached?, 'the transaction rolled the attachment back'
  end

  test 'a signed ID submission reports the stored blob size, not the token length' do
    blob = stored_pdf_blob(12.kilobytes)

    result = attach_income(blob.signed_id)

    assert result[:success], result[:error]&.message
    assert_equal blob.byte_size, result[:blob_size]
    event = Event.where(auditable: @application, action: 'income_proof_attached').order(:created_at).last
    assert_equal blob.byte_size, event.metadata.fetch('blob_size')
    assert_equal 'proof.pdf', event.metadata.fetch('filename')
  end

  test 'accepts a proof of exactly the size limit' do
    result = attach_income(stored_pdf_blob(ProofUploadFormats::PROOF_MAX_BYTES).signed_id)

    assert result[:success], result[:error]&.message
  end

  test 'refuses an oversized proof without changing the previous attachment or status' do
    previous = stored_pdf_blob(3.kilobytes)
    @application.income_proof.attach(previous)
    @application.update!(income_proof_status: :rejected)
    oversized = pdf_upload(ProofUploadFormats::PROOF_MAX_BYTES + 1)

    result = assert_no_difference('ActiveStorage::Blob.count') { attach_income(oversized) }

    assert_not result[:success]
    assert_instance_of UploadedDocument::Refused, result[:error]
    assert_equal :too_large, result[:error].reason
    @application.reload
    assert_equal previous, @application.income_proof.blob
    assert_predicate @application, :income_proof_status_rejected?
  end

  test 'refuses a signed ID when the caller accepts only uploads' do
    result = attach_income(stored_pdf_blob(3.kilobytes).signed_id, signed_ids: false)

    assert_not result[:success]
    assert_equal :unsupported, result[:error].reason
  end

  private

  def reject_on_paper(proof_type, reason:)
    without_auto_resubmission do
      ProofAttachmentService.reject_proof_without_attachment(
        application: @application, proof_type: proof_type, admin: @admin, submission_method: :paper, reason: reason
      )
    end
  end

  def attach_income(blob_or_file, **)
    ProofAttachmentService.attach_proof(
      application: @application, proof_type: :income, blob_or_file: blob_or_file,
      submission_method: :web, status: :not_reviewed, **
    )
  end

  def pdf_bytes(size)
    header = "%PDF-1.4\n"
    header + ('x' * (size - header.bytesize))
  end

  def stored_pdf_blob(size)
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(pdf_bytes(size)), filename: 'proof.pdf', content_type: 'application/pdf')
    mark_document_clean!(blob, user: @constituent)
  end

  def pdf_upload(size)
    tempfile = Tempfile.new(['proof', '.pdf'])
    tempfile.binmode
    tempfile.write(pdf_bytes(size))
    tempfile.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: tempfile, filename: 'proof.pdf', type: 'application/pdf')
  end
end
