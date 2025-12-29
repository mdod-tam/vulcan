# frozen_string_literal: true

module Admin
  class ProductsController < ApplicationController
    before_action :require_admin!
    before_action :set_product, only: %i[show edit update archive unarchive]
    include Pagy::Backend

    def index
      scope = filtered_products_scope
      @products = params[:show_archived] ? scope : scope.active
      @pagy, @products = pagy(@products, items: 20)
      @products_by_type = group_products_by_type(@products)
    end

    def show; end

    def new
      @product = Product.new
      load_vendors
    end

    def edit
      load_vendors
    end

    def create
      @product = Product.new(product_params)
      if @product.save
        redirect_to admin_products_path, notice: t('.product_created_pass')
      else
        load_vendors
        render :new, status: :unprocessable_content
      end
    end

    def update
      if @product.update(product_params)
        redirect_to admin_products_path, notice: t('.product_updated_pass')
      else
        load_vendors
        render :edit, status: :unprocessable_content
      end
    end

    def archive
      if @product&.archive!
        redirect_to admin_products_path, notice: t('.product_archive_pass')
      else
        redirect_to admin_products_path, alert: t('.product_archive_fail')
      end
    end

    def unarchive
      if @product&.unarchive!
        redirect_to admin_products_path, notice: t('.product_unarchive_pass')
      else
        redirect_to admin_products_path, alert: t('.product_unarchive_fail')
      end
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
                  { device_types: [],
                    vendor_ids: [] }]
      )
      filtered_params[:device_types]&.reject!(&:blank?)
      filtered_params
    end

    def set_product
      @product = Product.find_by(id: params[:id])
      return if @product

      redirect_to admin_products_path, alert: t('.product_not_found')
    end

    def load_vendors
      @vendors = User.vendors.ordered_by_name
    end

    def filtered_products_scope
      scope = Product.includes(:vendors).ordered_by_name
      return scope if params[:device_types].blank?

      types = Array(params[:device_types]).compact_blank
      types.any? ? scope.with_selected_types(types) : scope
    end

    def group_products_by_type(products)
      products.each_with_object({}) do |product, hash|
        (product.device_types || []).each do |type|
          hash[type] ||= []
          hash[type] << product
        end
      end
    end
  end
end
