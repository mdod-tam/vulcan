# frozen_string_literal: true

module TurboStreamResponseHandling
  extend ActiveSupport::Concern

  # @param updates [Hash] element_id => partial_name
  # @param modals_to_remove [Array<String>] modal element IDs
  def handle_turbo_stream_success(message:, updates: {}, modals_to_remove: [])
    prepare_turbo_stream_data if respond_to?(:prepare_turbo_stream_data, true)
    flash.now[:success] = message
    streams = build_success_turbo_streams(updates, modals_to_remove)
    render turbo_stream: streams
  end

  def handle_turbo_stream_error(message:)
    flash.now[:error] = message
    render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash')
  end

  # The flash always updates. A 'modals' key in updates replaces the modal container,
  # so modals_to_remove is then ignored.
  def build_success_turbo_streams(updates = {}, modals_to_remove = [])
    streams = []

    streams << turbo_stream.update('flash', partial: 'shared/flash')

    updates.each do |element_id, partial_name|
      streams << turbo_stream.update(element_id, partial: partial_name)
    end

    unless updates.key?('modals')
      modals_to_remove.each do |modal_id|
        streams << turbo_stream.remove(modal_id)
      end
    end

    streams
  end

  # @param turbo_message [String] defaults to html_message
  # @param turbo_modals_to_remove [Array<String>] DEPRECATED. To replace the full modal container,
  #   put 'modals' => 'modals' in turbo_updates.
  # @param turbo_redirect_path [String] when present, Turbo gets a 303 redirect, not streams
  def handle_success_response(
    html_redirect_path:,
    html_message:,
    turbo_message: nil,
    turbo_updates: {},
    turbo_modals_to_remove: [],
    turbo_redirect_path: nil
  )
    turbo_message ||= html_message

    respond_to do |format|
      # HTML keeps the :notice flash key because existing tests expect it.
      format.html { redirect_to html_redirect_path, notice: html_message }

      format.turbo_stream do
        if turbo_redirect_path.present?
          # Turbo converts a 303 redirect into a visit.
          redirect_to turbo_redirect_path, status: :see_other, notice: turbo_message
        else
          handle_turbo_stream_success(
            message: turbo_message,
            updates: turbo_updates,
            modals_to_remove: turbo_modals_to_remove
          )
        end
      end
    end
  end

  # HTML precedence: html_redirect_path, then html_render_action, then redirect back.
  # status applies only to html_render_action.
  def handle_error_response(error_message:, html_redirect_path: nil, html_render_action: nil, status: :unprocessable_content)
    respond_to do |format|
      if html_redirect_path
        format.html { redirect_to html_redirect_path, alert: error_message }
      elsif html_render_action
        format.html do
          flash.now[:alert] = error_message
          render html_render_action, status: status
        end
      else
        format.html { redirect_back_or_to root_path, alert: error_message }
      end

      format.turbo_stream { handle_turbo_stream_error(message: error_message) }
    end
  end
end
