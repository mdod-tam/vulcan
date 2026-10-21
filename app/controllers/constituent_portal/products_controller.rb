# frozen_string_literal: true

module ConstituentPortal
  class ProductsController < ApplicationController
    include ViewerLocale

    around_action :with_viewer_locale

    before_action :authenticate_user!
    before_action :require_constituent!

    def index
      @product_groups = product_history.groups
    end

    def show
      @product = product_history.find_product!(params[:id])
      @product_groups = product_history.groups.filter_map do |group|
        entries = group.entries.select { |entry| entry.product.id == @product.id }
        Applications::ProductHistory::Group.new(beneficiary: group.beneficiary, entries: entries) if entries.any?
      end
    end

    private

    def product_history
      @product_history ||= Applications::ProductHistory.new(applications: Application.accessible_by(current_user))
    end

    def require_constituent!
      return if current_user&.constituent?

      redirect_to root_path, alert: t('product_resources.devices.access_denied')
    end
  end
end
