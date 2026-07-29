# frozen_string_literal: true

class UsersController < ApplicationController
  class IneligibleProfileEditError < StandardError; end

  before_action :authenticate_user!
  before_action :set_current_user
  helper_method :after_update_path # Add this line to make the method available to views

  def edit
    @user = current_user
  end

  # Locks the current user before requalifying and updating primary contact fields, so a
  # concurrent merge and a concurrent profile edit can never interleave: either the merge
  # commits first and this reload sees the retired record and refuses, or the edit commits
  # first and the merge -- which takes the same lock -- waits.
  def update
    @user = current_user
    update_succeeded = false

    ActiveRecord::Base.transaction do
      locked_user = User.lock_for_merge_integrity!(@user).fetch(@user.id)
      raise IneligibleProfileEditError if locked_user.merged?

      @user = locked_user
      update_succeeded = @user.update(user_params)
      raise ActiveRecord::Rollback unless update_succeeded
    end

    if update_succeeded
      flash[:notice] = 'Profile successfully updated'
      redirect_to after_update_path(@user) # Add @user as argument
    else
      render :edit, status: :unprocessable_content
    end
  rescue IneligibleProfileEditError
    redirect_to edit_profile_path, alert: 'Your account is no longer eligible to update this profile.'
  end

  private

  def set_current_user
    Current.user = current_user
  end

  def user_params
    params.expect(user: %i[first_name last_name email phone phone_type])
  end

  def after_update_path(user)
    case user
    when Users::Administrator then admin_applications_path
    when Users::Constituent then constituent_portal_dashboard_path
    when Users::Evaluator then evaluators_dashboard_path
    when Users::Vendor then vendor_portal_dashboard_path
    else root_path
    end
  end
end
