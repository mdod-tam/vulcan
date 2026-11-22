# frozen_string_literal: true

module Applications
  class ReviewQueueSummary
    Summary = Data.define(:count, :oldest, :average_approval_days, :approval_sample_count, :unknown_dates)
    Entry = Data.define(:application, :documents, :entered_at, :days)
    PROOF_LABELS = { 'id' => 'ID', 'residency' => 'Residency', 'income' => 'Income' }.freeze

    def initialize(now: Time.current)
      @now = now
    end

    def call
      proofs = Application.staff_review_queue.awaiting_proof_review
      certifications = Application.certifications_needing_review
      {
        proofs: summarize(proofs, pending_proof_attachments(proofs), PROOF_LABELS.keys),
        certifications: summarize(certifications, attachments_for(certifications, 'disability_certification'), ['disability_certification']),
        providers: provider_summary
      }
    end

    private

    def provider_summary
      sent_at = provider_sent_at_expression
      applications = Application.certifications_awaiting_provider
      dated = applications.where(sent_at.not_eq(nil))
      application = dated.includes(:user).select(Application.arel_table[Arel.star], sent_at.as('provider_sent_at'))
                         .order(sent_at.asc, :id).first
      oldest = if application
                 entered_at = application.provider_sent_at
                 Entry.new(application:, documents: ['Provider signature'], entered_at:,
                           days: Equipment::WaitTime.days_since(entered_at, now: @now))
               end
      count = applications.count
      Summary.new(count:, oldest:, average_approval_days: nil, approval_sample_count: 0, unknown_dates: count - dated.count)
    end

    def provider_sent_at_expression
      applications = Application.arel_table
      current_signing = applications[:document_signing_status].in(Application.document_signing_statuses.values_at('sent', 'opened'))
      current_signing = current_signing.and(applications[:document_signing_requested_at].gteq(applications[:disability_certification_requested_at]))
      current_signing = current_signing.and(applications[:document_signing_requested_at].lteq(@now))
      signing_date = Arel::Nodes::Case.new.when(current_signing).then(applications[:document_signing_requested_at])
      Arel::Nodes::NamedFunction.new('GREATEST', [signing_date, provider_email_sent_at_expression])
    end

    # Link issuance and queueing are not sending. Only a provider-accepted email supplies this clock.
    def provider_email_sent_at_expression
      applications = Application.arel_table
      attempts = EmailDeliveryAttempt.arel_table
      forms = SecureRequestForm.certification_upload.status_sent.where(submitted_at: nil, revoked_at: nil)
                               .where(SecureRequestForm.arel_table[:application_id].eq(applications[:id]))
      origin = attempts[:origin_type].eq('Application').and(attempts[:origin_id].eq(applications[:id]))
      origin = origin.or(attempts[:origin_type].eq('SecureRequestForm').and(attempts[:origin_id].in(forms.select(:id).arel)))
      EmailDeliveryAttempt.where(mail_action: 'CertifyingProfessionalMailer#request_certification', accepted_at: ..@now)
                          .where(attempts[:application_id].eq(applications[:id])).where(origin)
                          .where(attempts[:accepted_at].gteq(applications[:disability_certification_requested_at]))
                          .select(attempts[:accepted_at].maximum).arel
    end

    def summarize(applications, attachments, types)
      count = applications.distinct.count
      sample_count, average_seconds = approval_statistics(types)
      Summary.new(count:, oldest: oldest_entry(attachments),
                  average_approval_days: average_seconds && (average_seconds.to_f / 1.day).round(1),
                  approval_sample_count: sample_count, unknown_dates: count - attachments.distinct.count(:record_id))
    end

    def attachments_for(applications, name)
      ActiveStorage::Attachment.where(record_type: Application.base_class.name, name:, record_id: applications.select(:id))
    end

    def pending_proof_attachments(applications)
      PROOF_LABELS.keys.map do |type|
        pending = if type == 'income'
                    applications.awaiting_income_proof_review
                  else
                    applications.where("#{type}_proof_status" => :not_reviewed).where.not(status: :approved)
                  end
        attachments_for(pending, DocumentType.fetch(type).attachment_name)
      end.reduce(&:or)
    end

    def oldest_entry(attachments)
      attachment = attachments.order(:created_at, :record_id, :id).first
      return unless attachment

      application = Application.includes(:user).find(attachment.record_id)
      names = attachments.where(record_id: application.id).pluck(:name)
      documents = PROOF_LABELS.filter_map { |type, label| label if names.include?(DocumentType.fetch(type).attachment_name.to_s) }
      documents = ['Certification'] if names.include?('disability_certification')
      Entry.new(application:, documents:, entered_at: attachment.created_at,
                days: Equipment::WaitTime.days_since(attachment.created_at, now: @now))
    end

    # A surviving primary attachment supplies an exact receipt date. Replaced or unrecorded documents are omitted.
    def approval_statistics(types)
      reviews = ProofReview.arel_table
      attachments = ActiveStorage::Attachment.arel_table
      names = Arel::Nodes::Case.new(reviews[:proof_type])
      types.each { |type| names.when(ProofReview.proof_types.fetch(type)).then(DocumentType.fetch(type).attachment_name.to_s) }
      match = attachments[:record_type].eq(Application.base_class.name)
                                       .and(attachments[:record_id].eq(reviews[:application_id]))
                                       .and(attachments[:blob_id].eq(reviews[:reviewed_blob_id]))
                                       .and(attachments[:name].eq(names))
      join = reviews.join(attachments, Arel::Nodes::InnerJoin).on(match).join_sources
      ProofReview.status_approved.where(proof_type: types, reviewed_at: ..@now).joins(join)
                 .where(reviews[:reviewed_at].gteq(attachments[:created_at]))
                 .pick(Arel.sql('COUNT(*)'), Arel.sql('AVG(EXTRACT(EPOCH FROM (proof_reviews.reviewed_at - active_storage_attachments.created_at)))'))
    end
  end
end
