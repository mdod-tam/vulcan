# frozen_string_literal: true

module VendorPortal
  # Controller for vendor profile management
  class ProfilesController < BaseController
    def edit
      @vendor = current_user
    end

    def update
      @vendor = current_user

      if @vendor.update(vendor_params)
        flash[:notice] = 'Profile updated successfully'
        redirect_to vendor_portal_dashboard_path
      else
        flash.now[:alert] = 'There was an error updating your profile'
        render :edit, status: :unprocessable_content
      end
    end

    private

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
                       :terms_accepted]
      )

      # Map legacy keys to new column names if new ones are blank.
      permitted[:physical_address_1] = permitted.delete(:address_line1) if permitted[:physical_address_1].blank? && permitted[:address_line1].present?

      permitted[:physical_address_2] = permitted.delete(:address_line2) if permitted[:physical_address_2].blank? && permitted[:address_line2].present?

      permitted
    end
  end
end
