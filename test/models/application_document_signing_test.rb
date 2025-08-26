# frozen_string_literal: true

require 'test_helper'

class ApplicationDocumentSigningTest < ActiveSupport::TestCase
  setup do
    @application = create(:application, :in_progress)
  end

  test 'document_signing_status enum values are correct' do
    assert_equal 0, Application.document_signing_statuses[:not_sent]
    assert_equal 1, Application.document_signing_statuses[:sent]
    assert_equal 2, Application.document_signing_statuses[:opened]
    assert_equal 3, Application.document_signing_statuses[:signed]
    assert_equal 4, Application.document_signing_statuses[:declined]
  end

  test 'document_signing_status defaults to not_sent' do
    assert_equal 'not_sent', @application.document_signing_status
    assert @application.document_signing_status_not_sent?
  end

  test 'document_signing_status can be updated to sent' do
    @application.update!(document_signing_status: :sent)
    assert_equal 'sent', @application.document_signing_status
    assert @application.document_signing_status_sent?
  end

  test 'document_signing_status can be updated to opened' do
    @application.update!(document_signing_status: :opened)
    assert_equal 'opened', @application.document_signing_status
    assert @application.document_signing_status_opened?
  end

  test 'document_signing_status can be updated to signed' do
    @application.update!(document_signing_status: :signed)
    assert_equal 'signed', @application.document_signing_status
    assert @application.document_signing_status_signed?
  end

  test 'document_signing_status can be updated to declined' do
    @application.update!(document_signing_status: :declined)
    assert_equal 'declined', @application.document_signing_status
    assert @application.document_signing_status_declined?
  end

  test 'document_signing_request_count defaults to zero' do
    assert_equal 0, @application.document_signing_request_count
  end

  test 'document_signing_request_count can be incremented' do
    @application.update!(document_signing_request_count: 1)
    assert_equal 1, @application.document_signing_request_count
  end

  test 'document_signing_audit_url is encrypted' do
    url = 'https://api.docuseal.com/audit/12345'
    @application.update!(document_signing_audit_url: url)
    
    # The encrypted value should be different from the plain text
    encrypted_value = @application.read_attribute_before_type_cast(:document_signing_audit_url)
    assert_not_equal url, encrypted_value
    
    # But decryption should return the original value
    assert_equal url, @application.document_signing_audit_url
  end

  test 'document_signing_document_url is encrypted' do
    url = 'https://api.docuseal.com/document/67890'
    @application.update!(document_signing_document_url: url)
    
    # The encrypted value should be different from the plain text
    encrypted_value = @application.read_attribute_before_type_cast(:document_signing_document_url)
    assert_not_equal url, encrypted_value
    
    # But decryption should return the original value
    assert_equal url, @application.document_signing_document_url
  end

  test 'digitally_signed_needs_review scope includes signed applications' do
    signed_app = create(:application, :in_progress, document_signing_status: :signed)
    other_app = create(:application, :in_progress, document_signing_status: :sent)
    
    results = Application.digitally_signed_needs_review
    assert_includes results, signed_app
    assert_not_includes results, other_app
  end

  test 'digitally_signed_needs_review scope excludes already processed applications' do
    # Should exclude approved applications
    approved_app = create(:application, :in_progress, 
                         document_signing_status: :signed, 
                         medical_certification_status: :approved)
    
    # Should exclude rejected applications  
    rejected_app = create(:application, :in_progress,
                         document_signing_status: :signed,
                         medical_certification_status: :rejected)
    
    # Should include received applications
    received_app = create(:application, :in_progress,
                         document_signing_status: :signed,
                         medical_certification_status: :received)
    
    results = Application.digitally_signed_needs_review
    assert_not_includes results, approved_app
    assert_not_includes results, rejected_app
    assert_includes results, received_app
  end

  test 'digitally_signed_needs_review scope excludes rejected and archived applications' do
    # Should exclude rejected status applications
    rejected_app = create(:application, status: :rejected, document_signing_status: :signed)
    
    # Should exclude archived status applications  
    archived_app = create(:application, status: :archived, document_signing_status: :signed)
    
    # Should include in_progress applications
    active_app = create(:application, :in_progress, document_signing_status: :signed)
    
    results = Application.digitally_signed_needs_review
    assert_not_includes results, rejected_app
    assert_not_includes results, archived_app
    assert_includes results, active_app
  end

  test 'filter_by_type includes digitally_signed_needs_review' do
    signed_app = create(:application, :in_progress, document_signing_status: :signed)
    other_app = create(:application, :in_progress, document_signing_status: :sent)
    
    results = Application.filter_by_type('digitally_signed_needs_review')
    assert_includes results, signed_app
    assert_not_includes results, other_app
  end

  test 'can store DocuSeal service metadata' do
    @application.update!(
      document_signing_service: 'docuseal',
      document_signing_submission_id: 'sub_123456',
      document_signing_submitter_id: 'submitter_789',
      document_signing_requested_at: 1.hour.ago,
      document_signing_signed_at: 30.minutes.ago
    )

    assert_equal 'docuseal', @application.document_signing_service
    assert_equal 'sub_123456', @application.document_signing_submission_id
    assert_equal 'submitter_789', @application.document_signing_submitter_id
    assert_not_nil @application.document_signing_requested_at
    assert_not_nil @application.document_signing_signed_at
  end

  test 'validates document_signing_status transitions' do
    # Should allow valid transitions
    @application.update!(document_signing_status: :sent)
    @application.update!(document_signing_status: :opened)
    @application.update!(document_signing_status: :signed)

    # Should allow decline from any status
    @application.update!(document_signing_status: :sent)
    @application.update!(document_signing_status: :declined)

    # All transitions should be successful
    assert_equal 'declined', @application.document_signing_status
  end
end
