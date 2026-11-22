# frozen_string_literal: true

module Admin
  module Icanconnect
    class FinancialRecordsController < Admin::BaseController
      before_action :load_record, only: %i[edit update]
      before_action :load_application, only: %i[new create]

      FINANCE_FIELDS = {
        'EquipmentItem' => %i[unit_cost delivered_on installed_on],
        'PurchaseOrder' => %i[vendor_name shipping_cost tax_cost other_cost other_cost_category invoice_total invoice_on vendor_invoice_number],
        'Evaluation' => %i[funding_source hourly_rate billable_hours mileage mileage_rate vendor_invoice_number],
        'TrainingSession' => %i[funding_source hourly_rate billable_hours mileage mileage_rate vendor_invoice_number],
        'ApplicationServiceExpense' => %i[category equipment_item_id service_date vendor_name amount vendor_invoice_number]
      }.freeze

      def new
        @record = @application.application_service_expenses.build
      end

      def edit; end

      def create
        @application.with_lock do
          @record = @application.application_service_expenses.build(params.expect(expense: %i[equipment_item_id category service_date vendor_name amount
                                                                                              vendor_invoice_number]))
          @record.save!
          changes = @record.saved_changes.slice('equipment_item_id', 'category', 'service_date', 'vendor_name', 'amount', 'vendor_invoice_number')
          AuditEventService.log(action: 'icc_service_expense_recorded', actor: current_user, auditable: @record,
                                metadata: { application_ids: [@application.id], equipment_item_ids: [@record.equipment_item_id],
                                            purchase_order_ids: [@record.equipment_item.purchase_order_id].compact,
                                            changes: changes })
        end
        redirect_to edit_admin_icanconnect_financial_record_path("ApplicationServiceExpense:#{@record.id}"), status: :see_other
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        @error = e.message
        render :new, status: :unprocessable_content
      end

      def update
        attributes = finance_params
        correction_requested = params[:correction_reason].present? || params[:correction_reference].present?
        if @correction_required || (@record.icc_financial_evidence_locked? && correction_requested)
          attributes.merge!(::Icanconnect::Claimable::MARK_FIELDS.index_with(nil)) if params[:void_filing_marker] == '1'
          ::Icanconnect::FilingWriter.new(actor: current_user).correct!(record: @record, attributes: attributes,
                                                                        lock_version: params[:lock_version], reason: params[:correction_reason],
                                                                        external_reference: params[:correction_reference])
        else
          ::Icanconnect::FilingWriter.new(actor: current_user).update_evidence!(record: @record, attributes: attributes,
                                                                                lock_version: params[:lock_version])
        end
        redirect_to edit_admin_icanconnect_financial_record_path(@key), notice: 'Financial evidence saved.', status: :see_other
      rescue ActiveRecord::StaleObjectError
        @error = 'This record changed while you were editing. The saved values are shown below. Review them and enter your changes again.'
        %i[finance correction_reason correction_reference void_filing_marker].each { |key| params.delete(key) }
        load_record
        render :edit, formats: [:html], status: :unprocessable_content
      rescue ArgumentError, ActiveRecord::RecordInvalid, Equipment::Conflict, UploadedDocument::Refused => e
        @error = e.message
        @record.reload
        load_financial_applications
        @record.assign_attributes(params.expect(finance: FINANCE_FIELDS.fetch(@record.class.name)).to_h)
        @correction_required = correction_required?
        load_mileage_rate
        if @record.respond_to?(:financial_document)
          @financial_blob = UploadedDocument.restorable(params.dig(:finance, :financial_document_signed_id), record: @record,
                                                                                                             name: 'financial_document')
        end
        render :edit, formats: [:html], status: :unprocessable_content
      end

      private

      def load_application
        @application = Application.find(params.expect(:application_id))
        @equipment = @application.equipment_items.where(funding_source: 'icanconnect', withdrawn_at: nil).includes(:product).order(:id)
      end

      def load_record
        @key = params[:id]
        @record = ::Icanconnect::FilingPrep.find_record(@key)
        @expected_version = action_name == 'edit' || params[:finance].nil? ? @record.lock_version : params[:lock_version]
        @correction_required = correction_required?
        load_financial_applications
        load_mileage_rate
        load_history
        if @record.is_a?(ApplicationServiceExpense)
          units = @record.application.equipment_items.where(funding_source: 'icanconnect')
          @equipment = units.active.or(units.where(id: @record.equipment_item_id)).includes(:product).order(:id)
        end
        return unless @record.is_a?(TrainingSession)

        current_ids = @record.equipment_item_ids
        @training_equipment = @record.application.equipment_items.where(withdrawn_at: nil)
                                     .or(@record.application.equipment_items.where(id: current_ids)).includes(:product).order(:id)
      end

      def load_financial_applications
        @financial_applications = if @record.is_a?(PurchaseOrder)
                                    Application.where(id: @record.equipment_items.select(:application_id)).order(:id).to_a
                                  else
                                    [@record.application].compact
                                  end
        ActiveRecord::Associations::Preloader.new(records: @financial_applications, associations: :user).call
        @financial_constituent_names = @financial_applications.map(&:constituent_full_name).uniq
      end

      def load_history
        @history = case @record
                   when EquipmentItem, PurchaseOrder then @record.equipment_history
                   else Event.where(auditable: @record).includes(:user).order(created_at: :desc, id: :desc)
                   end
        @equipment_audit_records = Equipment::AuditRecords.for(@history.to_a)
      end

      def load_mileage_rate
        @suggested_mileage_rate = nil
        return unless @record.is_a?(Evaluation) || @record.is_a?(TrainingSession)
        return if @record.mileage_rate.present?

        @suggested_mileage_rate = MileageRate.for_service_date(@record.service_source_on)
      end

      def correction_required?
        @record.icc_financial_evidence_locked? && !(@record.is_a?(EquipmentItem) && !@record.icc_claimed?)
      end

      def finance_params
        fields = FINANCE_FIELDS.fetch(@record.class.name)
        fields = [*fields, { equipment_item_ids: [] }] if @record.is_a?(TrainingSession)
        values = params.expect(finance: fields).to_h
        document = params.dig(:finance, :financial_document).presence || params.dig(:finance, :financial_document_signed_id).presence
        values[:financial_document] = document if document.present? && @record.respond_to?(:financial_document)
        values
      end
    end
  end
end
