# frozen_string_literal: true

# Handles rendering of the application home page
class HomeController < ApplicationController
  skip_before_action :authenticate_user!

  def index; end
end
