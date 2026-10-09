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
        saved_errors = @vendor.errors.dup
        retry_phone = @vendor.phone
        @vendor.reload
        @retained_w9 = @vendor.with_lock { Vendors::W9Document.retained(params[:users_vendor], vendor: @vendor) }
        @vendor.assign_attributes(vendor_params.except(:w9_form, :w9_form_signed_id))
        @vendor.phone = retry_phone if vendor_params.key?(:phone)
        @vendor.errors.copy!(saved_errors)
        submitted_reference = params[:users_vendor][:w9_form_signed_id]
        @retained_w9_reference = if @retained_w9 && Vendors::W9Document.resolve_reference(submitted_reference, vendor: @vendor)&.id == @retained_w9.id
                                   submitted_reference
                                 elsif @retained_w9
                                   Vendors::W9Document.reference(@retained_w9, vendor: @vendor)
                                 end
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
      @vendor.with_lock do
        if w9_form.present?
          Vendors::ReplaceW9.call(vendor: @vendor, file: w9_form, attributes: attributes)
        else
          @vendor.update!(attributes)
        end
      end
      true
    rescue UploadedDocument::Refused => e
      @vendor.assign_attributes(attributes)
      @vendor.errors.add(:w9_form, e.user_message)
      false
    rescue ActiveRecord::RecordInvalid
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
