# frozen_string_literal: true

module Applications
  module EquipmentFulfillment
    extend ActiveSupport::Concern

    included do
      # The original report remains available even when it recommends no catalog devices.
      belongs_to :equipment_source_evaluation, class_name: 'Evaluation', optional: true
      has_many :open_equipment_evaluations, -> { open_assigned.order(:id) },
               class_name: 'Evaluation', foreign_key: :application_id, inverse_of: :application, dependent: nil
      scope :equipment_procurement_eligible, -> { status_approved.fulfillment_type_equipment.or(approved_deafblind) }
    end

    class_methods do
      def preload_equipment_fulfillment(applications, include_display_details: true)
        applications = applications.select { |application| application.equipment_fulfillment? || application.equipment_needs_initialized_at? }
        preload_equipment_requests(applications)
        preload_equipment_stages(applications)
        preload_equipment_display_details(applications) if include_display_details
      end

      private

      def preload_equipment_requests(applications)
        ActiveRecord::Associations::Preloader.new(records: applications, associations: %i[equipment_needs equipment_items]).call
        needs = applications.flat_map(&:equipment_needs).select { |need| need.remaining_quantity.positive? }
        items = applications.flat_map(&:equipment_items).reject(&:withdrawn_at?)
        requests = needs + items
        ActiveRecord::Associations::Preloader.new(records: requests, associations: :bid_group_lines).call
        lines = requests.flat_map(&:bid_group_lines).reject(&:released_at?)
        ActiveRecord::Associations::Preloader.new(records: lines, associations: :bid_group).call
        ActiveRecord::Associations::Preloader.new(records: items.select(&:direct_vendor?), associations: :purchase_order).call
      end

      def preload_equipment_stages(applications)
        reports = applications.select { |application| application.equipment_needs_initialized_at? && !application.equipment_needs_decided? }
        ActiveRecord::Associations::Preloader.new(records: reports, associations: :equipment_source_evaluation).call
        stages = applications.map { |application| Equipment::FulfillmentStage.new(application) }
        waiting = applications.zip(stages).filter_map { |application, stage| application if stage.needs_evaluation? }
        ActiveRecord::Associations::Preloader.new(records: waiting, associations: :open_equipment_evaluations).call
        requests = stages.flat_map(&:catalog_review_requests)
        ActiveRecord::Associations::Preloader.new(records: requests, associations: :product).call
      end

      def preload_equipment_display_details(applications)
        needs = applications.flat_map(&:equipment_needs).select { |need| need.remaining_quantity.positive? }
        items = applications.flat_map(&:equipment_items)
        ActiveRecord::Associations::Preloader.new(records: needs + items, associations: :product).call
        ActiveRecord::Associations::Preloader.new(records: items, associations: :purchase_order).call
        ActiveRecord::Associations::Preloader.new(records: applications, associations: :equipment_source_evaluation).call
        reports = applications.filter_map(&:equipment_source_evaluation)
        ActiveRecord::Associations::Preloader.new(records: reports, associations: :evaluator).call
        ActiveRecord::Associations::Preloader.new(records: reports.select(&:recommendation_outcome_catalog_products?), associations: :recommended_products).call
      end
    end

    def equipment_procurement_eligible?
      (status_approved? && equipment_fulfillment?) || approved_deafblind?
    end

    def equipment_needs_decided?
      equipment_needs_decided_at.present?
    end

    def equipment_catalog_product_pending?
      equipment_needs_initialized_at.present? && !equipment_needs_decided? &&
        equipment_source_report&.recommendation_outcome.in?(%w[outside_catalog no_suitable_product])
    end

    def equipment_source_report
      equipment_source_evaluation
    end

    def equipment_fulfillment_stage
      Equipment::FulfillmentStage.new(self).result
    end

    def admin_fulfillment_responsibility_state
      return :voucher_no_equipment if voucher_fulfillment? && !equipment_needs_initialized_at?

      equipment_fulfillment_stage.stage
    end
  end
end
