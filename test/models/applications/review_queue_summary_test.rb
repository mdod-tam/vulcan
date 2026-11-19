# frozen_string_literal: true

require 'test_helper'

module Applications
  class ReviewQueueSummaryTest < ActiveSupport::TestCase
    setup do
      @now = Time.current.change(usec: 0)
      @admin = create(:admin)
    end

    test 'pending document receipt dates determine the oldest application and its document labels' do
      before = summaries.fetch(:proofs).count
      application = create(:application, :with_id_proof, :with_residency_proof, :with_income_proof)
      receipt = @now - 10_000.days
      application.id_proof.attachment.update!(created_at: receipt)
      application.residency_proof.attachment.update!(created_at: receipt + 2.days)
      application.income_proof.attachment.update!(created_at: receipt + 4.days)
      application.update!(needs_review_since: @now - 1.hour)
      create(:application, :in_progress)

      summary = summaries.fetch(:proofs)

      assert_equal before + 1, summary.count
      assert_equal application, summary.oldest.application
      assert_equal %w[ID Residency Income], summary.oldest.documents
      assert_equal receipt, summary.oldest.entered_at
      assert_equal 10_000, summary.oldest.days

      application.id_proof.attach(io: file_fixture('disability_certification_valid.pdf').open,
                                  filename: 'replacement-id.pdf', content_type: 'application/pdf')

      replaced = summaries.fetch(:proofs)
      assert_equal receipt + 2.days, replaced.oldest.entered_at
      assert_equal 9_998, replaced.oldest.days
    end

    test 'pending scan and blocked documents still age in the pending review cohort' do
      application = create(:application, :with_id_proof)
      application.id_proof.attachment.update!(created_at: @now - 10_000.days)
      scan = DocumentScan.find_by!(blob_id: application.id_proof.blob.id)

      %i[pending blocked].each do |status|
        scan.update!(status:)
        summary = summaries.fetch(:proofs)

        assert_equal application, summary.oldest.application
        assert_equal 10_000, summary.oldest.days
        assert_equal ['ID'], summary.oldest.documents
      end
    end

    test 'approved applications contribute only required pending income updates' do
      before = summaries.fetch(:proofs).count
      application = create(:application, :approved, :with_id_proof, :with_income_proof)
      application.update!(income_proof_status: :not_reviewed, id_proof_status: :not_reviewed)
      application.income_proof.attachment.update!(created_at: @now - 10_000.days)
      application.id_proof.attachment.update!(created_at: @now - 11_000.days)

      summary = summaries.fetch(:proofs)

      assert_equal before + 1, summary.count
      assert_equal application, summary.oldest.application
      assert_equal ['Income'], summary.oldest.documents
      assert_equal 10_000, summary.oldest.days

      application.update!(income_proof_required: false)
      assert_equal before, summaries.fetch(:proofs).count
    end

    test 'certifications count received and signed records once while missing receipt dates stay unknown' do
      before = summaries.fetch(:certifications)
      received = create(:application, :with_disability_certification, disability_certification_status: :received)
      received.disability_certification.attachment.update!(created_at: @now - 10_000.days)
      signed = create(:application, document_signing_status: :signed, disability_certification_status: :requested)
      overlap = create(:application, :with_disability_certification,
                       disability_certification_status: :received, document_signing_status: :signed)
      create(:application, :archived, disability_certification_status: :received, document_signing_status: :signed)
      decided = create(:application, :with_disability_certification,
                       disability_certification_status: :approved, document_signing_status: :signed)

      summary = summaries.fetch(:certifications)

      assert_equal before.count + 3, summary.count
      assert_equal before.unknown_dates + 1, summary.unknown_dates
      assert_equal received, summary.oldest.application
      assert_equal ['Certification'], summary.oldest.documents
      assert_equal 10_000, summary.oldest.days
      assert_equal [received.id, signed.id, overlap.id].sort,
                   Application.certifications_needing_review.where(id: [received.id, signed.id, overlap.id, decided.id]).ids.sort
    end

    test 'approval averages use actual matching document receipts and separate proofs from certifications' do
      assert_equal 0, summaries.fetch(:proofs).approval_sample_count
      assert_nil summaries.fetch(:proofs).average_approval_days
      first = create(:application, :with_income_proof)
      approve_document(first, :income, received_at: @now - 8.days, reviewed_at: @now - 6.days)
      second = create(:application, :with_id_proof)
      approve_document(second, :id, received_at: @now - 9.days, reviewed_at: @now - 4.days)
      certification = create(:application, :with_disability_certification)
      approve_document(certification, :disability_certification, received_at: @now - 7.days, reviewed_at: @now - 1.day)
      create(:application, :with_disability_certification, disability_certification_status: :approved, submission_method: :paper)

      result = summaries

      assert_equal 2, result.fetch(:proofs).approval_sample_count
      assert_equal 3.5, result.fetch(:proofs).average_approval_days
      assert_equal 1, result.fetch(:certifications).approval_sample_count
      assert_equal 6.0, result.fetch(:certifications).average_approval_days
    end

    test 'replaced receipts mismatched document names and invalid approval intervals are omitted' do
      application = create(:application, :with_income_proof)
      approve_document(application, :income, received_at: @now - 8.days, reviewed_at: @now - 6.days)
      old_blob = application.income_proof.blob
      application.income_proof.attach(io: file_fixture('disability_certification_valid.pdf').open,
                                      filename: 'replacement-income.pdf', content_type: 'application/pdf')
      application.residency_proof.attach(old_blob)
      other = create(:application)
      other.income_proof.attach(old_blob)
      negative = create(:application, :with_id_proof)
      approve_document(negative, :id, received_at: @now - 1.day, reviewed_at: @now - 2.days)
      future = create(:application, :with_id_proof)
      approve_document(future, :id, received_at: @now - 1.day, reviewed_at: @now + 1.day)

      summary = summaries.fetch(:proofs)

      assert_equal 0, summary.approval_sample_count
      assert_nil summary.average_approval_days
    end

    test 'provider signature queue ages confirmed sends and leaves link-only requests undated' do
      before = summaries.fetch(:providers)
      signing_date = @now - 10_000.days
      signing = create(:application, disability_certification_status: :requested, document_signing_status: :sent,
                                     disability_certification_requested_at: signing_date, document_signing_requested_at: signing_date)
      email = create(:application, disability_certification_status: :requested, disability_certification_requested_at: @now - 11_000.days)
      accepted_at = @now - 10_002.days
      accepted_provider_email(email, accepted_at:)
      prepared = create(:application, disability_certification_status: :requested, disability_certification_requested_at: @now - 12_000.days)
      create(:certification_upload_form, application: prepared, sent_at: @now - 12_000.days)

      summary = summaries.fetch(:providers)

      assert_equal before.count + 3, summary.count
      assert_equal before.unknown_dates + 1, summary.unknown_dates
      assert_equal email, summary.oldest.application
      assert_equal ['Provider signature'], summary.oldest.documents
      assert_equal accepted_at, summary.oldest.entered_at
      assert_equal 10_002, summary.oldest.days
      assert_nil summary.average_approval_days
      assert_equal 0, summary.approval_sample_count
      assert_equal [signing.id, email.id, prepared.id].sort,
                   FilterService.new(Application.all, filter: 'certifications_awaiting_provider').apply_filters.data
                                .where(id: [signing.id, email.id, prepared.id]).ids.sort
    end

    test 'received signed approved and archived certifications leave the provider signature queue' do
      before = summaries.fetch(:providers).count
      create(:application, disability_certification_status: :received)
      create(:application, disability_certification_status: :requested, document_signing_status: :signed)
      create(:application, disability_certification_status: :approved)
      create(:application, :archived, disability_certification_status: :requested, document_signing_status: :sent)

      assert_equal before, summaries.fetch(:providers).count
    end

    test 'superseded signing dates queued mail and revoked upload forms do not invent a current send date' do
      before = summaries.fetch(:providers)
      application = create(:application, disability_certification_status: :requested, document_signing_status: :sent,
                                         disability_certification_requested_at: @now - 2.days, document_signing_requested_at: @now - 5.days)
      form = create(:certification_upload_form, :revoked, application:, sent_at: @now - 3.days)
      accepted_provider_email(application, origin: form, accepted_at: @now - 1.day)
      accepted_provider_email(application, accepted_at: @now - 4.days)

      summary = summaries.fetch(:providers)

      assert_equal before.count + 1, summary.count
      assert_equal before.unknown_dates + 1, summary.unknown_dates
    end

    private

    def summaries
      ReviewQueueSummary.new(now: @now).call
    end

    def accepted_provider_email(application, accepted_at:, origin: application)
      EmailDeliveryAttempt.create!(application:, origin:, destination: 'provider@example.org',
                                   correlation_id: SecureRandom.uuid, recipient_key: SecureRandom.hex(32), server_id: 'test-server',
                                   mail_action: 'CertifyingProfessionalMailer#request_certification',
                                   attempted_at: accepted_at, accepted_at:, state: 'accepted')
    end

    def approve_document(application, type, received_at:, reviewed_at:)
      attachment = application.document_attachment_for(type)
      attachment.attachment.update!(created_at: received_at)
      ProofReview.record_decision!(application:, admin: @admin, proof_type: type, status: :approved,
                                   reviewed_blob_id: attachment.blob.id, decision_key: SecureRandom.uuid) do |review|
        review.record!(reviewed_at:)
      end
    end
  end
end
