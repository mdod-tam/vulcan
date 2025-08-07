# frozen_string_literal: true

class UsersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_current_user
  helper_method :after_update_path # Add this line to make the method available to views

  def edit
    @user = current_user
  end

  def update
    @user = current_user
    if @user.update(user_params)
      flash[:notice] = 'Profile successfully updated'
      redirect_to after_update_path(@user) # Add @user as argument
    else
      render :edit, status: :unprocessable_content
    end
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
