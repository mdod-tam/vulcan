# frozen_string_literal: true

# Handles rendering of static content pages for the application
class PagesController < ApplicationController
  skip_before_action :authenticate_user!,
                     only: %i[help how_it_works eligibility apply contact terms]

  def help; end

  def how_it_works; end

  def eligibility; end

  def apply; end

  def contact; end

  def terms; end
end
