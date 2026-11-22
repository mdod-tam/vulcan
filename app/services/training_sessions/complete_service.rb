# frozen_string_literal: true

module TrainingSessions
  class CompleteService < BaseService
    def initialize(training_session, current_user, params)
      super()
      @training_session = training_session
      @actor = current_user
      @params = params
    end

    def call
      @training_session.with_current_trainer_lock(@actor) do
        raise OperationError, I18n.t('training_sessions.complete.invalid_status') unless @training_session.can_complete?

        attributes = {
          status: :completed, completed_at: @params[:completed_at], report_submitted_at: Time.current,
          constituent_summary: @params[:constituent_summary], summary_locale: @params[:summary_locale],
          product_trained_on_id: @params[:product_trained_on_id], duration_hours: @params[:duration_hours]
        }
        attributes[:internal_notes] = @params[:internal_notes] if @params.key?(:internal_notes)
        @training_session.assign_attributes(attributes)
        snapshot_funding!
        @training_session.save!
        link_equipment!
        AuditEventService.log(
          actor: @actor, action: 'training_completed', auditable: @training_session,
          metadata: { application_id: @training_session.application_id, training_session_id: @training_session.id,
                      completed_at: @training_session.completed_at.iso8601, report_submitted_at: @training_session.report_submitted_at.iso8601,
                      duration_hours: @training_session.duration_hours.to_s('F'), product_trained_on_id: @training_session.product_trained_on_id,
                      product_trained_on_name: @training_session.product_trained_on.name,
                      summary_locale: @training_session.summary_locale }
        )
        @notification_outcome = TrainingSessionNotifier.new(
          @training_session, actor: @actor, action: 'training_completed'
        ).deliver_after_commit
      end
      success(I18n.t('training_sessions.complete.success'), { training_session: @training_session, notification_outcome: @notification_outcome })
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { training_session: @training_session })
    rescue OperationError => e
      failure(e.message, { training_session: @training_session })
    end

    private

    def snapshot_funding!
      Icanconnect::ServiceFunding.snapshot!(@training_session, service_date: @training_session.completed_at)
    rescue Date::Error => e
      raise OperationError, e.message
    end

    def link_equipment!
      ids = Array(@params[:equipment_item_ids]).compact_blank.map(&:to_i).uniq
      return if ids.empty?

      items = @training_session.application.equipment_items.active.where(id: ids).order(:id).lock.to_a
      raise OperationError, 'Select active equipment that belongs to this training beneficiary' unless items.size == ids.size
      raise OperationError, 'Include the product trained on among the linked equipment' unless items.any? do |item|
        item.product_id == @training_session.product_trained_on_id
      end

      items.each { |item| @training_session.training_session_equipment_items.create!(equipment_item: item) }
    end
  end
end
