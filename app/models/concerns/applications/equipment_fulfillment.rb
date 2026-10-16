# frozen_string_literal: true

module Applications
  module EquipmentFulfillment
    extend ActiveSupport::Concern

    EARLIER_EQUIPMENT_ORDER_FIELDS = %i[equipment_po_sent_at equipment_tracking_number].freeze

    included do
      # The unfiltered events and evaluations associations own destruction.
      has_many :equipment_needs_events, -> { where(action: %w[equipment_needs_initialized equipment_needs_updated]).order(:created_at, :id) },
               class_name: 'Event', as: :auditable, inverse_of: :auditable, dependent: nil
      has_many :completed_equipment_reports, -> { completed_sessions.by_report_submission },
               class_name: 'Evaluation', foreign_key: :application_id, inverse_of: :application, dependent: nil

      scope :equipment_procurement_eligible, -> { status_approved.fulfillment_type_equipment }
      scope :equipment_legacy_review, lambda {
        facts = EARLIER_EQUIPMENT_ORDER_FIELDS.map do |field|
          column = arel_table[field]
          field == :equipment_tracking_number ? column.matches_regexp('[^[:space:]]') : column.not_eq(nil)
        end
        equipment_procurement_eligible.where(equipment_needs_initialized_at: nil)
                                      .where(facts.reduce(:or)).where.missing(:equipment_items)
      }
    end

    class_methods do
      def preload_equipment_fulfillment(applications)
        ActiveRecord::Associations::Preloader.new(
          records: applications,
          associations: [:equipment_needs_events, { equipment_needs: [:product, { source_evaluation: %i[recommended_products evaluator] }] },
                         { equipment_items: [:product, { purchase_order: :vendor }] },
                         { completed_equipment_reports: %i[recommended_products evaluator] }]
        ).call
      end
    end

    def equipment_procurement_eligible?
      status_approved? && equipment_fulfillment?
    end

    def equipment_legacy_unmapped?
      EARLIER_EQUIPMENT_ORDER_FIELDS.any? { |field| public_send(field).present? } && equipment_items.empty?
    end

    def equipment_legacy_review?
      equipment_procurement_eligible? && equipment_needs_initialized_at.nil? && equipment_legacy_unmapped?
    end

    def equipment_needs_decided?
      equipment_needs_events.any? { |event| event.action == 'equipment_needs_updated' }
    end

    def equipment_catalog_product_pending?
      equipment_needs_initialized_at.present? && !equipment_needs_decided? &&
        equipment_source_report&.recommendation_outcome_outside_catalog?
    end

    def equipment_source_report
      source = equipment_needs.filter_map(&:source_evaluation).first
      return source if source

      initialization = equipment_needs_events.find { |event| event.action == 'equipment_needs_initialized' }
      return completed_equipment_reports.find { |evaluation| evaluation.id.to_s == initialization.metadata['source_evaluation_id'].to_s } if initialization

      completed_equipment_reports.first
    end

    def admin_fulfillment_responsibility_state
      return :voucher_no_equipment if voucher_fulfillment?
      return :legacy_review if equipment_legacy_review?
      return :needs_action if equipment_needs.any? { |need| need.remaining_quantity.positive? } || equipment_items.any? { |item| item.queue_status == 'needs_ordering' }

      recorded_state = recorded_equipment_fulfillment_state
      return recorded_state if recorded_state

      equipment_needs_responsibility_state
    end

    private

    def recorded_equipment_fulfillment_state
      states = equipment_items.map(&:queue_status)
      return :po_sent if states.include?('ordered')

      :shipped if states.include?('shipped')
    end

    def equipment_needs_responsibility_state
      if equipment_catalog_product_pending?
        equipment_procurement_eligible? ? :needs_catalog_product : :outside_catalog
      elsif equipment_needs_initialized_at
        :no_equipment
      else
        :pending_evaluation
      end
    end
  end
end
