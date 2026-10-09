# frozen_string_literal: true

module Admin
  class W9ReviewsController < Admin::BaseController
    before_action :set_vendor
    before_action :set_w9_review, only: [:show]
    # Don't skip checking for w9_form in tests - we need consistent behavior
    before_action :check_w9_form, only: %i[new create]
    before_action :load_delivery_history, only: %i[new show create]

    def index
      @pagy, @w9_reviews = pagy(@vendor.w9_reviews.includes(:admin).order(created_at: :desc, id: :desc), limit: 20)
    end

    def show
      # Set @w9_form for the view for consistency
      @w9_form = @w9_review.reviewed_blob
    end

    def new
      # Set up the new review form
      @w9_review = @vendor.w9_reviews.build(reviewed_blob: @vendor.w9_form.blob)
      @w9_form = @vendor.w9_form
    end

    def create
      result = Vendors::ReviewW9.new(vendor: @vendor, admin: current_user, attributes: w9_review_params).call
      @w9_review = result.data[:review]
      @w9_form = @vendor.w9_form
      if result.success?
        delivery = result.data[:delivery]
        flash[:warning] = "The decision was recorded. Delivery outcome: #{delivery}." unless %w[pending submitted delivered requested].include?(delivery)
        redirect_to admin_vendor_path(@vendor), notice: t('.w9_review_complete')
      else
        flash.now[:alert] = result.message
        render :new, status: :unprocessable_content
      end
    end

    private

    def load_delivery_history
      @w9_notifications = EmailDelivery::Visibility.preload(Notification.where(recipient: @vendor, action: %w[w9_approved w9_rejected]).order(created_at: :desc))
      @vendor_secure_request_forms = EmailDelivery::Visibility.preload(@vendor.vendor_secure_request_forms.order(sent_at: :desc))
    end

    def check_w9_form
      @w9_form = @vendor.w9_form

      # Check if w9_form is attached and redirect if it's not
      redirect_to admin_vendors_path, alert: t('alerts.w9_missing') unless @w9_form&.attached?
    end

    def set_vendor
      # Use Users::Vendor to match the STI type column
      @vendor = Users::Vendor.find(params[:vendor_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_vendors_path, alert: t('admin.w9_reviews.set_vendor.vendor_not_found')
    end

    def set_w9_review
      @w9_review = @vendor.w9_reviews.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      # We always want to redirect to the vendor page if review not found
      redirect_to admin_vendor_path(@vendor), alert: t('alerts.review_not_found')
    end

    def w9_review_params
      params.expect(w9_review: %i[status rejection_reason_code rejection_reason reviewed_blob_id])
    end

    def require_admin!
      return if current_user&.admin?

      flash[:alert] = t('alerts.unauthorized_action')
      redirect_to root_path
    end
  end
end
