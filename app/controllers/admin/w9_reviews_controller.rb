# frozen_string_literal: true

module Admin
  class W9ReviewsController < Admin::BaseController
    before_action :set_vendor
    before_action :set_w9_review, only: [:show]
    before_action :check_w9_form, only: %i[new create]
    before_action :load_delivery_history, only: %i[new show create]

    def index
      @pagy, @w9_reviews = pagy(@vendor.w9_reviews.includes(:admin).order(created_at: :desc, id: :desc), limit: 20)
    end

    def show
      @w9_form = @w9_review.reviewed_blob
    end

    def new
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
      notifications = Notification.where(recipient: @vendor, action: %w[w9_approved w9_rejected])
      notifications = notifications.where("metadata ->> 'w9_review_id' = ?", @w9_review.id.to_s) if @w9_review&.persisted?
      @w9_notifications = EmailDelivery::Visibility.preload(notifications.order(created_at: :desc, id: :desc))
      @vendor_secure_request_forms = EmailDelivery::Visibility.preload(@vendor.vendor_secure_request_forms.order(sent_at: :desc))
    end

    def check_w9_form
      @w9_form = @vendor.w9_form

      redirect_to admin_vendors_path, alert: t('alerts.w9_missing') unless @w9_form&.attached?
    end

    def set_vendor
      # Users::Vendor limits the lookup to vendor records.
      @vendor = Users::Vendor.find(params[:vendor_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_vendors_path, alert: t('admin.w9_reviews.set_vendor.vendor_not_found')
    end

    def set_w9_review
      @w9_review = @vendor.w9_reviews.find(params[:id])
    rescue ActiveRecord::RecordNotFound
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
