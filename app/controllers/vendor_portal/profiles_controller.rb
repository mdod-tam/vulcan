# frozen_string_literal: true

module VendorPortal
  # Controller for vendor profile management
  class ProfilesController < BaseController
    def edit
      @vendor = current_user
      @stored_w9 = @vendor.w9_form.blob
    end

    def update
      @vendor = current_user
      @stored_w9 = @vendor.w9_form.blob

      if update_vendor
        flash[:notice] = 'Profile updated successfully'
        redirect_to vendor_portal_dashboard_path
      else
        # A usable new W-9 rides along so the vendor need not choose it again
        @retained_w9 = UploadedDocument.retained(params[:users_vendor], record: @vendor, field: 'w9_form')
        flash.now[:alert] = 'There was an error updating your profile'
        render :edit, status: :unprocessable_content
      end
    end

    private

    # A new W-9 is resolved through UploadedDocument in the same transaction as the update,
    # so a refused file leaves the profile and the W-9 on file unchanged.
    def update_vendor
      attributes = vendor_params.except(:w9_form, :w9_form_signed_id)
      w9_form = UploadedDocument.submitted(params[:users_vendor], 'w9_form')
      Users::Vendor.transaction do
        attributes[:w9_form] = UploadedDocument.resolve!(w9_form, record: @vendor, name: 'w9_form') if w9_form.present?
        @vendor.update(attributes) || raise(ActiveRecord::Rollback)
      end
    rescue UploadedDocument::Refused => e
      @vendor.assign_attributes(attributes.except(:w9_form))
      @vendor.errors.add(:w9_form, e.user_message)
      false
    end

    def vendor_params
      permitted = params.expect(
        users_vendor: [:business_name,
                       :business_tax_id,
                       :website_url,
                       :address_line1,      # legacy key that may be submitted
                       :address_line2,      # legacy key that may be submitted
                       :physical_address_1,
                       :physical_address_2,
                       :city,
                       :state,
                       :zip_code,
                       :phone,
                       :email,
                       :w9_form,
                       :w9_form_signed_id,
                       :terms_accepted]
      )

      # Map legacy keys to new column names if new ones are blank.
      permitted[:physical_address_1] = permitted.delete(:address_line1) if permitted[:physical_address_1].blank? && permitted[:address_line1].present?

      permitted[:physical_address_2] = permitted.delete(:address_line2) if permitted[:physical_address_2].blank? && permitted[:address_line2].present?

      permitted
    end
  end
end
