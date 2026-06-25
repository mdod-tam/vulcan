# frozen_string_literal: true

module Admin
  class VendorsController < ApplicationController
    include TurboStreamResponseHandling

    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_vendor, only: %i[show edit update]

    def index
      # Attachment presence controls whether the W9 review action is actionable.
      @vendors = Users::Vendor.includes([:w9_form_attachment]).order(:business_name)

      # Filter by W9 status if provided
      return if params[:w9_status].blank?

      @vendors = @vendors.where(w9_status: params[:w9_status])
    end

    def show
      @w9_reviews = @vendor.w9_reviews.includes(:admin).order(created_at: :desc)
      @vendor_secure_request_forms = @vendor.vendor_secure_request_forms.order(sent_at: :desc)
      @w9_secure_request_notifications = Notification
                                         .where(notifiable: @vendor,
                                                action: 'w9_resubmission_requested')
                                         .includes(:actor)
                                         .order(created_at: :desc)
      @w9_secure_request_events = Event
                                  .where(auditable: @vendor,
                                         action: %w[
                                           w9_submitted_via_secure_form
                                           w9_upload_request_revoked
                                           w9_upload_request_expired
                                         ])
                                  .includes(:user)
                                  .order(created_at: :desc)
    end

    def edit; end

    def update
      if @vendor.update(vendor_params)
        AuditEventService.log(
          action: 'vendor_updated',
          actor: current_user,
          auditable: @vendor,
          metadata: { changes: @vendor.saved_changes }
        )
        handle_success_response(
          html_redirect_path: admin_vendor_path(@vendor),
          html_message: 'Vendor was successfully updated.',
          turbo_message: 'Vendor was successfully updated.'
        )
      else
        handle_error_response(
          html_render_action: :edit,
          error_message: 'Failed to update vendor.'
        )
      end
    end

    private

    def set_vendor
      # Use Users::Vendor to match the STI type column
      @vendor = Users::Vendor.find(params[:id])
    end

    def vendor_params
      params.expect(vendor: %i[business_name business_tax_id vendor_authorization_status])
    end

    def require_admin!
      return if current_user&.admin?

      handle_error_response(
        html_redirect_path: root_path,
        error_message: 'You are not authorized to perform this action'
      )
    end
  end
end
