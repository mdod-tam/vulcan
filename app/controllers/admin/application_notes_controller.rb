# frozen_string_literal: true

module Admin
  # Manages application notes for admin users, allowing them to create and attach
  # notes to application records for internal communication and tracking purposes
  class ApplicationNotesController < BaseController
    before_action :set_application

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

    private

    def set_application
      @application = Application.find(params[:application_id])
    end

    def note_params
      params.expect(application_note: %i[content internal_only])
    end
  end
end
