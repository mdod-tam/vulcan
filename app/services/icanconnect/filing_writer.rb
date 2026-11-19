# frozen_string_literal: true

module Icanconnect
  class FilingWriter
    def initialize(actor:)
      raise ArgumentError, 'Administrator required' unless actor.admin?

      @actor = actor
    end

    def mark!(selections:, period:, external_reference:)
      raise ArgumentError, 'Period and external filing reference are required' if period.blank? || external_reference.blank?
      raise ArgumentError, 'Choose at least one actual cost row' if selections.empty?

      records = selected_records(selections)

      ApplicationRecord.transaction do
        FinancialContext.lock!(records)
        reviewed = records.sort_by { |record| [record.class.name, record.id] }.map do |record|
          record.lock!
          selected = selections.find { |selection| selection.fetch('key') == "#{record.class.name}:#{record.id}" }
          validate_review!(record, selected)
        end
        reviewed.each do |row|
          record = row.record
          record.icc_financial_write = true
          record.update!(icc_claim_period: period, icc_external_filing_reference: external_reference,
                         icc_claimed_at: Time.current, icc_claimed_by: @actor)
          AuditEventService.log(action: 'icc_cost_marked_claimed', actor: @actor, auditable: record,
                                metadata: audit_context(record).merge(cost_record: row.key, period: period,
                                                                      external_filing_reference: external_reference, amount: row.amount,
                                                                      document_blob_ids: row.documents.map(&:blob_id)))
        end
      end
      records
    ensure
      records&.each { |record| record.icc_financial_write = false }
    end

    def update_evidence!(record:, attributes:, lock_version:)
      ApplicationRecord.transaction do
        FinancialContext.lock!([record])
        record.lock!
        check_version!(record, lock_version)
        attributes = resolve_financial_document(record, attributes)
        if record.is_a?(EquipmentItem) && attributes.key?(:unit_cost)
          Equipment::PurchaseCosts.update_unit!(item: record, amount: attributes.delete(:unit_cost), expected_version: record.lock_version, actor: @actor)
        end
        before = financial_audit_state(record)
        save_financial_attributes!(record, attributes)
        after = financial_audit_state(record)
        if before != after
          AuditEventService.log(action: 'icc_financial_evidence_updated', actor: @actor, auditable: record,
                                metadata: audit_context(record).merge(changed_fields: changed_fields(record, before, after), before: before, after: after))
        end
      end
      record
    end

    def correct!(record:, attributes:, lock_version:, reason:, external_reference:)
      raise ArgumentError, 'Reason and external correction reference are required' if reason.blank? || external_reference.blank?

      ApplicationRecord.transaction do
        FinancialContext.lock!([record])
        record.lock!
        check_version!(record, lock_version)
        raise ArgumentError, 'This correction path is for filed costs and their shared invoice evidence' unless record.icc_financial_evidence_locked?

        attributes = resolve_financial_document(record, attributes)
        attributes[:unit_cost] = Equipment::PurchaseCosts.parse_unit_cost!(attributes[:unit_cost]) if record.is_a?(EquipmentItem) && attributes.key?(:unit_cost)
        before = financial_audit_state(record)
        record.icc_financial_write = record.icc_correction_write = true
        retain_prior_invoice(record, attributes)
        save_financial_attributes!(record, attributes)
        after = financial_audit_state(record)
        AuditEventService.log(action: 'icc_filed_cost_corrected', actor: @actor, auditable: record,
                              metadata: audit_context(record).merge(correction_reason: reason, external_filing_reference: external_reference,
                                                                    changed_fields: changed_fields(record, before, after), before: before, after: after))
      end
      record
    ensure
      record.icc_financial_write = record.icc_correction_write = false
    end

    private

    def audit_context(record)
      context = { operation_id: SecureRandom.uuid, application_ids: [record.try(:application_id)].compact }
      case record
      when EquipmentItem
        context.merge!(equipment_item_ids: [record.id], purchase_order_ids: [record.purchase_order_id].compact)
      when PurchaseOrder
        units = record.equipment_items.pluck(:id, :application_id)
        context.merge!(application_ids: units.map(&:last).compact.uniq, equipment_item_ids: units.map(&:first), purchase_order_ids: [record.id])
      when TrainingSession
        units = record.equipment_items.pluck(:id, :purchase_order_id)
        context.merge!(equipment_item_ids: units.map(&:first), purchase_order_ids: units.map(&:last).compact.uniq)
      when ApplicationServiceExpense
        context.merge!(equipment_item_ids: [record.equipment_item_id], purchase_order_ids: [record.equipment_item.purchase_order_id].compact)
      end
      context
    end

    def save_financial_attributes!(record, attributes)
      if record.respond_to?(:mileage_rate) && record.mileage_rate.nil? && !attributes.key?(:mileage_rate)
        miles = attributes.fetch(:mileage, record.mileage).to_d
        attributes[:mileage_rate] = MileageRate.for_service_date(record.service_source_on) if miles.positive?
      end
      previous_ids = record.equipment_item_ids.sort if record.is_a?(TrainingSession)
      previous_version = record.lock_version
      record.update!(attributes)
      return unless previous_ids && previous_ids != record.equipment_item_ids.sort && record.lock_version == previous_version

      record.touch # rubocop:disable Rails/SkipsModelValidations -- update! validated the record; advance its membership version.
    end

    def changed_fields(record, before, after)
      fields = record.saved_changes.keys
      fields << 'equipment_item_ids' if before['equipment_item_ids'] != after['equipment_item_ids']
      fields
    end

    def resolve_financial_document(record, attributes)
      attributes = attributes.to_h.symbolize_keys
      document = attributes[:financial_document]
      attributes[:financial_document] = UploadedDocument.resolve!(document, record: record, name: 'financial_document', scan_owner: @actor) if document.present?
      attributes
    end

    def financial_audit_state(record)
      state = record.attributes.slice(*record.icc_financial_attributes)
      state['equipment_item_ids'] = record.equipment_item_ids.sort if record.is_a?(TrainingSession)
      if record.respond_to?(:financial_document)
        state['financial_document_blob_id'] = record.financial_document.blob&.id
        state['superseded_document_blob_ids'] = record.superseded_financial_documents.blobs.pluck(:id)
      end
      state
    end

    def retain_prior_invoice(record, attributes)
      replacement = attributes[:financial_document] || attributes['financial_document']
      return unless replacement && record.respond_to?(:financial_document) && record.financial_document.attached?

      original = record.financial_document.blob
      return if original.id == replacement.id

      retained = record.superseded_financial_documents.blobs.to_a
      record.superseded_financial_documents = retained.include?(original) ? retained : retained + [original]
    end

    def selected_records(selections)
      records = selections.map { |selection| FilingPrep.find_record(selection.fetch('key')) }
      raise ArgumentError, 'Duplicate cost rows' unless records.map { |record| [record.class.name, record.id] }.uniq.size == records.size

      records
    end

    def validate_review!(record, selection)
      check_version!(record, selection.fetch('lock_version'))
      row = FilingPrep.row(record)
      raise ActiveRecord::StaleObjectError.new(record, 'filing evidence') unless row.review_version == selection.fetch('review_version')
      raise ArgumentError, "Cost row #{row.key} has already been marked filed" if row.claimed?
      raise ArgumentError, "Cost row #{row.key} is incomplete: #{row.missing.join('; ')}" unless row.ready?

      row.documents.each { |attachment| DocumentScan.require_clean!(attachment.blob) }
      row
    end

    def check_version!(record, version)
      raise ActiveRecord::StaleObjectError.new(record, 'filing review') unless record.lock_version.to_s == version.to_s
    end
  end
end
