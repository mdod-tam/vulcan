# frozen_string_literal: true

# Genuine browser interaction uses the normal session, MFA and CSRF gates.
class SessionActivitiesController < ApplicationController
  def show = render_deadlines

  def create = render_deadlines

  private

  def track_session_activity? = request.post?

  def render_deadlines
    response.headers['Cache-Control'] = 'no-store'
    render json: current_session.activity_deadlines
  end
end
