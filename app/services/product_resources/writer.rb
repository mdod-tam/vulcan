# frozen_string_literal: true

module ProductResources
  # The resource, attachment change, and structural audit commit together.
  class Writer
    attr_reader :accepted_document

    def initialize(resource:, actor:)
      @resource = resource
      @actor = actor
    end

    def save(attributes:, source:, document: nil)
      @accepted_document = resolve_document(document) if document.present? && source == 'pdf'
      unless %w[url pdf].include?(source)
        @resource.assign_attributes(attributes)
        @resource.errors.add(:base, 'Choose an external link or PDF document.')
        return false
      end
      action = @resource.new_record? ? 'created' : 'updated'
      ProductResource.transaction do
        @resource.lock! if @resource.persisted?
        @resource.assign_attributes(attributes)
        if @accepted_document
          # Recheck and hold the staged blob lock until publication, alongside cleanup's lock.
          @resource.document = UploadedDocument.resolve!(@accepted_document, record: @resource, name: 'document', scan_owner: @actor)
        end
        @resource.document = nil if source == 'url'
        @resource.url = nil if source == 'pdf'
        fields = @resource.changed + (@resource.attachment_changes.any? ? ['document'] : [])
        @resource.save!
        audit(action, fields)
      end
      true
    rescue UploadedDocument::Refused => e
      @accepted_document = nil
      @resource.assign_attributes(attributes)
      @resource.errors.add(:document, e.user_message)
      false
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.equal?(@resource)

      false
    end

    def destroy!
      ProductResource.transaction do
        @resource.lock!
        audit('deleted', ['title', 'locale', @resource.source_type == 'pdf' ? 'document' : 'url'])
        @resource.destroy!
      end
    end

    private

    def resolve_document(input)
      # Keep an accepted upload available for a corrected form submission.
      ProductResource.transaction do
        UploadedDocument.resolve!(input, record: @resource, name: 'document', scan_owner: @actor)
      end
    end

    def audit(operation, fields)
      AuditEventService.log(action: "product_resource_#{operation}", actor: @actor, auditable: @resource.product,
                            metadata: { product_id: @resource.product_id, product_resource_id: @resource.id,
                                        source_type: @resource.source_type, changed_fields: fields.sort,
                                        operation_id: SecureRandom.uuid })
    end
  end
end
