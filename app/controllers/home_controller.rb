# frozen_string_literal: true

# Sends visitors to sign-in or their role's dashboard.
class HomeController < ApplicationController
  skip_before_action :authenticate_user!

  def index
    flash.keep
    response.headers['Cache-Control'] = 'no-store'
    redirect_to current_user ? dashboard_path_for_current_user : sign_in_path(locale: public_request_locale_param)
  end
end
