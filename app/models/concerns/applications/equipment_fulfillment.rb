# frozen_string_literal: true

module Applications
  module EquipmentFulfillment
    extend ActiveSupport::Concern

    included do
      # The unfiltered events and evaluations associations own destruction.
      has_many :equipment_needs_events, -> { where(action: %w[equipment_needs_initialized equipment_needs_updated]).order(:created_at, :id) },
               class_name: 'Event', as: :auditable, inverse_of: :auditable, dependent: nil
      has_many :completed_equipment_reports, -> { completed_sessions.by_report_submission },
               class_name: 'Evaluation', foreign_key: :application_id, inverse_of: :application, dependent: nil

      scope :equipment_procurement_eligible, -> { status_approved.fulfillment_type_equipment }
    end

    class_methods do
      def preload_equipment_fulfillment(applications, include_display_details: true)
        applications = applications.select(&:equipment_fulfillment?)
        needs = include_display_details ? [:product, { source_evaluation: %i[recommended_products evaluator] }] : [:source_evaluation]
        items = include_display_details ? { equipment_items: [:product, { purchase_order: :vendor }] } : :equipment_items
        ActiveRecord::Associations::Preloader.new(
          records: applications,
          associations: [{ equipment_needs: needs }, items]
        ).call

        preload_equipment_fulfillment_metadata(applications, include_display_details:)
      end

      private

      def preload_equipment_fulfillment_metadata(applications, include_display_details:)
        fallback_applications = applications.select { |application| application.equipment_needs.none?(&:source_evaluation) }
        metadata_applications = include_display_details ? fallback_applications : fallback_applications.select(&:equipment_report_needed_for_responsibility?)
        reports = include_display_details ? { completed_equipment_reports: %i[recommended_products evaluator] } : :completed_equipment_reports
        ActiveRecord::Associations::Preloader.new(
          records: metadata_applications,
          associations: [:equipment_needs_events, reports]
        ).call

        outside_catalog_applications = (applications - fallback_applications).select do |application|
          (include_display_details || application.equipment_report_needed_for_responsibility?) &&
            application.equipment_needs_initialized_at.present? && application.equipment_source_report&.recommendation_outcome_outside_catalog?
        end
        ActiveRecord::Associations::Preloader.new(
          records: outside_catalog_applications, associations: :equipment_needs_events
        ).call
      end
    end

    def equipment_procurement_eligible?
      status_approved? && equipment_fulfillment?
    end

    def equipment_needs_decided?
      equipment_needs_events.any? { |event| event.action == 'equipment_needs_updated' }
    end

    def equipment_catalog_product_pending?
      equipment_needs_initialized_at.present? && equipment_source_report&.recommendation_outcome_outside_catalog? &&
        !equipment_needs_decided?
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

      equipment_procurement_responsibility_state || equipment_needs_responsibility_state
    end

    def equipment_report_needed_for_responsibility?
      equipment_fulfillment? && equipment_needs_initialized_at.present? && equipment_procurement_responsibility_state.nil?
    end

    private

    def equipment_procurement_responsibility_state
      return :needs_action if equipment_needs.any? { |need| need.remaining_quantity.positive? } || equipment_items.any? { |item| item.queue_status == 'needs_ordering' }

      recorded_equipment_fulfillment_state
    end

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
