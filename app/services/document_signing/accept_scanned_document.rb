# frozen_string_literal: true

module DocumentSigning
  # Finishes a provider submission only after its exact stored document is cleared.
  class AcceptScannedDocument
    def self.call(scan)
      new(scan).call
    end

    def initialize(scan)
      @scan = scan
      @context = scan.context
    end

    def call
      raise ArgumentError, 'Unexpected scan continuation' unless @scan.continuation == 'docuseal'

      DocumentScan.require_clean!(@scan.blob)
      application = Application.find(@context.fetch('application_id'))
      application.with_lock do
        # A newer signing request owns its own status and provider identity.
        return :superseded unless same_request?(application)
        return :completed if attached?(application)

        actor = User.find(@context.fetch('actor_id'))
        @scan.blob.update!(metadata: @scan.blob.metadata.merge('source' => 'docuseal'))
        outcome = MedicalCertificationAttachmentService.accept_submission(
          application: application, blob: @scan.blob, submission_method: :docuseal,
          requested_at: parsed_time('requested_at'), admin: actor, metadata: document_metadata
        )
        raise(outcome[:error] || 'Certification attachment failed') unless outcome[:success]

        application.update!(document_signing_status: :signed, document_signing_signed_at: parsed_time('completed_at'),
                            document_signing_document_url: @context.fetch('document_url'),
                            document_signing_audit_url: @context['audit_url'])
        AuditEventService.log(action: 'document_signing_completed', actor: actor, auditable: application,
                              metadata: document_metadata.merge('completed_at' => @context.fetch('completed_at'),
                                                                'provider_email' => @context['provider_email']).merge(retention_metadata(outcome)))
      end
      :completed
    end

    private

    def same_request?(application)
      application.document_signing_service == 'docuseal' &&
        application.document_signing_submission_id == @context.fetch('submission_id') &&
        application.document_signing_requested_at == parsed_time('requested_at') &&
        application.medical_provider_email == @context['provider_email']
    end

    def attached?(application)
      application.medical_certification.blob&.id == @scan.blob_id ||
        application.additional_medical_certifications.blobs.exists?(id: @scan.blob_id)
    end

    def parsed_time(key)
      Time.iso8601(@context[key]) if @context[key].present?
    end

    def document_metadata
      {
        'document_signing_service' => 'docuseal',
        'document_signing_submission_id' => @context.fetch('submission_id'),
        'document_signing_document_url' => @context.fetch('document_url'),
        'document_signing_audit_url' => @context['audit_url'],
        'document_scan_id' => @scan.id
      }
    end

    def retention_metadata(outcome)
      return {} unless outcome[:placement] == :additional

      {
        'retained_as' => 'additional_medical_certification',
        'additional_medical_certification_blob_id' => outcome[:additional_blob_id],
        'retention_reason' => outcome[:retention_reason]
      }
    end
  end
end
