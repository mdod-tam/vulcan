# frozen_string_literal: true

module DocumentSigning
  # Accepts cleared provider documents or records their terminal scan failure.
  class AcceptScannedDocument
    class AcceptanceFailed < StandardError
      attr_reader :code

      def initialize(error)
        @code = error&.class&.name || 'acceptance_rejected'
        super('Certification attachment failed')
      end
    end

    def self.give_up(scan, error_code:)
      new(scan).give_up(error_code: error_code)
    end

    def self.call(scan)
      new(scan).call
    end

    def initialize(scan)
      @scan = scan
      @context = scan.context
    end

    def call
      raise ArgumentError, 'Unexpected scan continuation' unless @scan.continuation == 'docuseal'

      application = Application.find(@context.fetch('application_id'))
      application.with_lock do
        @scan.reload
        raise DocumentScan::NotCleared, 'Document scan has not finished' if @scan.pending?

        outcome = continue_request(application)
        @scan.update!(continued_at: Time.current, continuation_next_attempt_at: nil, continuation_error_code: nil) unless @scan.continued_at
        outcome
      end
    end

    def give_up(error_code:)
      application = Application.find_by(id: @context.fetch('application_id'))
      owner = application || @scan
      owner.with_lock do
        @scan.reload
        next if @scan.continued_at

        if application && !same_request?(application)
          @scan.update!(continued_at: Time.current, continuation_next_attempt_at: nil, continuation_error_code: 'request_superseded')
          next :superseded
        end

        actor = User.find_by(id: @context.fetch('actor_id')) || User.system_user
        metadata = failure_metadata(reason: 'continuation_gave_up', details: error_code)
        if actor
          AuditEventService.log(action: 'document_signing_attachment_failed', actor: actor, auditable: owner, metadata: metadata)
        else
          Rails.event.notify('document_scan.continuation_audit_actor_missing', document_scan_id: @scan.id)
        end
        @scan.update!(continued_at: Time.current, continuation_next_attempt_at: nil, continuation_error_code: error_code)
        Rails.event.notify('document_scan.continuation_gave_up', document_scan_id: @scan.id, error_code: error_code)
        :failed
      end
    end

    private

    def continue_request(application)
      # A newer signing request owns its own status and provider identity.
      return :superseded unless same_request?(application)
      return @scan.clean? && @scan.continuation_error_code.nil? ? :completed : :failed if @scan.continued_at

      actor = User.find(@context.fetch('actor_id'))
      @scan.clean? ? accept_document(application, actor) : record_scan_failure(application, actor)
    end

    def accept_document(application, actor)
      DocumentScan.require_clean!(@scan.blob)
      return :completed if attached?(application)

      @scan.blob.update!(metadata: @scan.blob.metadata.merge('source' => 'docuseal'))
      outcome = DisabilityCertificationAttachmentService.accept_submission(
        application: application, blob: @scan.blob, submission_method: :docuseal,
        requested_at: parsed_time('requested_at'), admin: actor, metadata: document_metadata
      )
      raise AcceptanceFailed, outcome[:error] unless outcome[:success]

      application.update!(document_signing_status: :signed, document_signing_signed_at: parsed_time('completed_at'),
                          document_signing_document_url: @context.fetch('document_url'), document_signing_audit_url: @context['audit_url'])
      AuditEventService.log(action: 'document_signing_completed', actor: actor, auditable: application,
                            metadata: document_metadata.merge('completed_at' => @context.fetch('completed_at'),
                                                              'provider_email' => @context['provider_email']).merge(retention_metadata(outcome)))
      :completed
    end

    def record_scan_failure(application, actor)
      metadata = failure_metadata(reason: @scan.blocked? ? 'scan_blocked' : 'scan_failed', details: @scan.last_error_code)
      AuditEventService.log(action: 'document_signing_attachment_failed', actor: actor, auditable: application, metadata: metadata)
      User.admins.find_each do |admin|
        notification = NotificationService.create_and_deliver!(type: 'attachment_failure_warning', recipient: admin, actor: actor,
                                                               notifiable: application, metadata: metadata, deliver: false)
        raise ActiveRecord::RecordNotSaved, 'Could not record the document scan warning' unless notification
      end
      :failed
    end

    def failure_metadata(reason:, details:)
      {
        document_signing_service: 'docuseal', document_signing_submission_id: @context.fetch('submission_id'),
        operation_id: "docuseal_scan_#{@scan.id}", document_scan_id: @scan.id,
        application_id: @context['application_id'], original_actor_id: @context['actor_id'], continuation_attempts: @scan.continuation_attempts,
        scan_status: @scan.status, failure_reason: reason, failure_details: details,
        failed_at: Time.current.iso8601
      }
    end

    def same_request?(application)
      application.document_signing_service == 'docuseal' &&
        application.document_signing_submission_id == @context.fetch('submission_id') &&
        application.document_signing_submitter_id == @context.fetch('submitter_id') &&
        application.document_signing_requested_at == parsed_time('requested_at') &&
        application.certifying_professional_email == @context['provider_email']
    end

    def attached?(application)
      application.disability_certification.blob&.id == @scan.blob_id ||
        application.additional_disability_certifications.blobs.exists?(id: @scan.blob_id)
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
        'retained_as' => 'additional_disability_certification',
        'additional_disability_certification_blob_id' => outcome[:additional_blob_id],
        'retention_reason' => outcome[:retention_reason]
      }
    end
  end
end
