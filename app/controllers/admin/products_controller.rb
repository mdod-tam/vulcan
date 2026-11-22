# frozen_string_literal: true

module Admin
  class ProductsController < ApplicationController
    before_action :require_admin!
    before_action :set_product, only: %i[show edit update archive unarchive]

    def index
      @selected_device_types = Array(params[:device_types]).compact_blank.uniq
      @selected_disability_groups = Array(params[:disability_groups]).compact_blank.uniq
      @query = params[:q].to_s.strip
      @selected_sort = params[:sort] == 'model' ? 'model' : 'manufacturer'
      scope = filtered_products_scope
      @products = params[:include_discontinued] == '1' ? scope : scope.active
      @pagy, @products = paginate_or_first_page(@products)
      @products_by_category = group_products_by_category(@products)
    end

    def show
      @product_resources = @product.product_resources.with_attached_document.by_language_and_title
    end

    def new
      @product = Product.new
    end

    def edit; end

    def create
      @product = Product.new(product_params)
      if @product.save
        redirect_to admin_products_path, notice: t('.product_created_pass')
      else
        render :new, status: :unprocessable_content
      end
    end

    def update
      if @product.update(product_params)
        redirect_to admin_products_path, notice: t('.product_updated_pass')
      else
        render :edit, status: :unprocessable_content
      end
    end

    def archive
      @product.archive!
      redirect_to admin_products_path, notice: t('.product_archive_pass')
    rescue ActiveRecord::RecordInvalid
      redirect_to admin_products_path, alert: t('.product_archive_fail')
    end

    def unarchive
      @product.unarchive!
      redirect_to admin_products_path, notice: t('.product_unarchive_pass')
    rescue ActiveRecord::RecordInvalid
      redirect_to admin_products_path, alert: t('.product_unarchive_fail')
    end

    private

    def product_params
      filtered_params = params.expect(
        product: [:name,
                  :manufacturer,
                  :model_number,
                  :description,
                  :features,
                  :compatibility_notes,
                  :documentation_url,
                  :category, :model_confirmed, :msrp,
                  { device_types: [],
                    eligible_disability_groups: [] }]
      )
      filtered_params[:device_types]&.reject!(&:blank?)
      filtered_params[:eligible_disability_groups]&.reject!(&:blank?)
      filtered_params
    end

    def set_product
      @product = Product.find_by(id: params[:id])
      return if @product

      redirect_to admin_products_path, alert: t('.product_not_found')
    end

    def filtered_products_scope
      scope = Product.ordered_by_name
      scope = scope.reorder(:model_number, :name, :id) if @selected_sort == 'model'
      if @query.present?
        pattern = "%#{Product.sanitize_sql_like(@query)}%"
        scope = scope.where('manufacturer ILIKE :query OR model_number ILIKE :query OR name ILIKE :query', query: pattern)
      end
      scope = scope.by_device_types(@selected_device_types) if @selected_device_types.any?
      scope = scope.eligible_for_groups(@selected_disability_groups) if @selected_disability_groups.any?
      scope
    end

    def group_products_by_category(products)
      products.group_by(&:category).transform_values do |category_products|
        category_products.group_by { |product| product.eligible_disability_groups.uniq.sort }
                         .sort_by { |groups, _| groups.map { |group| Product::PROGRAM_GROUPS.fetch(group) }.join(', ') }.to_h
      end
    end
  end
end
