# frozen_string_literal: true

module Admin
  # Manages application notes for admin users, allowing them to create and attach
  # notes to application records for internal communication and tracking purposes
  class ApplicationNotesController < BaseController
    before_action :set_application
    before_action :set_note, only: %i[update]

    def create
      @note = @application.application_notes.new(note_params)
      @note.admin = current_user

      if @note.save
        redirect_to admin_application_path(@application), notice: t('.note_added')
      else
        error_message = "Failed to add note: #{@note.errors.full_messages.join(', ')}"
        redirect_to admin_application_path(@application), alert: error_message
      end
    end

    def update
      if params[:unassign]
        if @note.unassign!
          redirect_to admin_application_path(@application), notice: 'Note unassigned successfully.'
        else
          redirect_to admin_application_path(@application), alert: 'Failed to unassign note.'
        end
      elsif params[:mark_done]
        if @note.mark_as_done!
          redirect_to admin_application_path(@application), notice: 'Note marked as done.'
        else
          redirect_to admin_application_path(@application), alert: 'Failed to mark note as done.'
        end
      elsif params[:mark_incomplete]
        if @note.mark_as_incomplete!
          redirect_to admin_application_path(@application), notice: 'Note reopened.'
        else
          redirect_to admin_application_path(@application), alert: 'Failed to reopen note.'
        end
      elsif params[:assigned_to_id].present?
        assignee = User.find(params[:assigned_to_id])
        if @note.assign_to!(assignee)
          redirect_to admin_application_path(@application), notice: "Note assigned to #{assignee.full_name}."
        else
          redirect_to admin_application_path(@application), alert: 'Failed to assign note.'
        end
      else
        redirect_to admin_application_path(@application), alert: 'No action provided.'
      end
    end

    private

    def set_application
      @application = Application.find(params[:application_id])
    end

    def set_note
      @note = @application.application_notes.find(params[:id])
    end

    def note_params
      params.expect(application_note: %i[content internal_only assigned_to_id])
    end
  end
end
