# frozen_string_literal: true

module EquipmentNeeds
  class Writer
    def self.initialize_from!(evaluation, actor:)
      application = evaluation.application
      initialized = false
      application.with_lock do
        if application.equipment_procurement_eligible? && application.equipment_needs_initialized_at.nil?
          validate_report!(evaluation, actor)
          if evaluation.recommendation_outcome_catalog_products?
            evaluation.recommended_products.order(:id).each do |product|
              application.equipment_needs.create!(product: product, remaining_quantity: 1, source_evaluation: evaluation, unfulfilled_since: Time.current,
                                                  disability_setup_group: application.default_equipment_setup_group)
            end
          end
          application.equipment_source_evaluation = evaluation
          application.save!
          stamp_initialization!(application)
          Equipment::Mutation.audit!(application, actor: actor, action: 'equipment_needs_initialized',
                                                  changes: { equipment_needs: { old: [], new: snapshot(application.equipment_needs.order(:id)) } },
                                                  source_evaluation_id: evaluation.id)
          initialized = true
        end
      end
      initialized
    end

    def self.update!(application, rows:, expected_initialized_at:, actor:, reason:)
      Equipment::Mutation.authorize!(actor)
      raise Equipment::Conflict, 'Describe the reason for changing purchasing needs.' if reason.to_s.strip.blank?

      application.with_lock do
        Equipment::Mutation.eligible!(application)
        unless application.equipment_needs_initialized_at&.iso8601(6).to_s == expected_initialized_at.to_s
          raise Equipment::Conflict, 'Purchasing needs changed. Refresh the page before saving.'
        end

        needs = application.equipment_needs.order(:id).lock.to_a
        submitted = normalize_rows(rows)
        validate_rows!(needs, submitted)
        before = snapshot(needs)
        save_rows!(application, needs, submitted)
        after = snapshot(application.equipment_needs.order(:id))
        refresh_reserved_bids!(after.reject { |row| before.include?(row) }.pluck('id'))
        first_edit = application.equipment_needs_initialized_at.nil?
        stamp_initialization!(application) if first_edit
        first_decision = application.equipment_needs_decided_at.nil?
        application.update!(equipment_needs_decided_at: Time.current) if first_decision
        if before != after || first_edit || first_decision
          Equipment::Mutation.audit!(application, actor: actor, action: 'equipment_needs_updated',
                                                  changes: { equipment_needs: { old: before, new: after } }, reason: reason.to_s.strip)
        end
      end
      application
    end

    def self.validate_report!(evaluation, actor)
      unless actor&.persisted? && actor.public_login_active? && (actor.admin? || evaluation.evaluator_id == actor.id)
        raise Equipment::Conflict, 'Only the assigned evaluator or an administrator can initialize purchasing needs.'
      end
      raise Equipment::Conflict, 'Purchasing needs require a completed evaluation report.' unless evaluation.status_completed?
      return if evaluation.recommended_products_available?

      raise Equipment::Conflict, "The report recommends archived catalog products; review the application's purchasing needs."
    end
    private_class_method :validate_report!

    def self.stamp_initialization!(application)
      # This marker is bookkeeping; intake validations and lifecycle callbacks do not apply.
      return if application.touch(:equipment_needs_initialized_at) # rubocop:disable Rails/SkipsModelValidations -- Initialization bookkeeping only.

      raise ActiveRecord::RecordNotSaved.new('Purchasing needs initialization was not recorded.', application)
    end
    private_class_method :stamp_initialization!

    def self.normalize_rows(rows)
      Array(rows).filter_map do |attributes|
        row = attributes.to_h.symbolize_keys
        next if row[:id].blank? && row[:product_id].blank?

        {
          id: row[:id].present? ? Integer(row[:id].to_s, 10) : nil,
          product_id: Integer(row[:product_id].to_s, 10),
          remaining_quantity: Integer(row[:remaining_quantity].to_s, 10),
          disability_setup_group: row[:disability_setup_group].presence,
          lock_version: row[:id].present? ? row[:lock_version] : nil
        }
      end
    rescue ArgumentError, TypeError
      raise Equipment::Conflict, 'Choose a catalog product and enter a whole number of devices.'
    end
    private_class_method :normalize_rows

    def self.validate_rows!(needs, rows)
      raise Equipment::Conflict, 'Purchasing needs changed. Refresh the page before saving.' if rows.filter_map { |row| row[:id] }.sort != needs.map(&:id)
      raise Equipment::Conflict, 'Each catalog product can appear only once. Change its existing quantity.' if rows.pluck(:product_id).uniq.size != rows.size

      rows_by_id = rows.index_by { |row| row[:id] }
      needs.each do |need|
        row = rows_by_id.fetch(need.id)
        Equipment::Mutation.version!(need, row[:lock_version])
        next if row[:product_id] == need.product_id

        raise Equipment::Conflict, 'Set the old model quantity to zero and add the replacement model.'
      end
    end
    private_class_method :validate_rows!

    def self.save_rows!(application, needs, rows)
      products = Product.where(id: rows.pluck(:product_id)).index_by(&:id)
      needs_by_id = needs.index_by(&:id)
      rows.each do |row|
        need = needs_by_id[row[:id]]
        product = products[row[:product_id]]
        raise Equipment::Conflict, 'A selected catalog product no longer exists.' unless product

        quantity = row[:remaining_quantity]
        setup = row[:disability_setup_group]
        setup ||= application.default_equipment_setup_group if need.nil?
        next if need && need.remaining_quantity == quantity && need.disability_setup_group == setup

        validate_change!(application, need, product, quantity, setup)

        need ||= application.equipment_needs.build(product: product)
        need.update!(remaining_quantity: quantity, disability_setup_group: setup,
                     unfulfilled_since: (quantity.positive? && need.remaining_quantity.to_i.zero? ? Time.current : need.unfulfilled_since))
      end
    end
    private_class_method :save_rows!

    def self.refresh_reserved_bids!(need_ids)
      groups = BidGroup.where(id: BidGroupLine.reserved.where(equipment_need_id: need_ids).select(:bid_group_id))
      groups.order(:id).lock.each { |group| group.update!(membership_changed_at: Time.current) }
    end
    private_class_method :refresh_reserved_bids!

    def self.validate_change!(application, need, product, quantity, setup)
      reserved_quantity = need&.reserved_quantity
      if reserved_quantity&.positive? && quantity < reserved_quantity
        raise Equipment::Conflict, "Keep at least #{reserved_quantity} while devices are reserved in bids. Reduce the bid quantity first to request fewer."
      end
      if quantity.positive? && setup.present? && application.program_disability_groups.exclude?(setup)
        raise Equipment::Conflict, 'Choose a setup from the confirmed application program groups.'
      end

      raise Equipment::Conflict, 'A new purchasing need must request at least one device.' if need.nil? && quantity <= 0

      validate_product_request!(application, need, product, quantity)
    end
    private_class_method :validate_change!

    def self.validate_product_request!(application, need, product, quantity)
      increasing = need.nil? || quantity > need.remaining_quantity
      return unless increasing && quantity.positive?

      raise Equipment::Conflict, 'Choose an available catalog product before adding devices.' unless product.available?
      return if product.eligible_for?(application.program_disability_groups)

      raise Equipment::Conflict, 'Confirm the program groups and choose an eligible exact model.'
    end
    private_class_method :validate_product_request!

    def self.snapshot(needs)
      needs.map { |need| need.attributes.slice('id', 'product_id', 'remaining_quantity', 'source_evaluation_id', 'disability_setup_group') }
    end
    private_class_method :snapshot
  end
end
