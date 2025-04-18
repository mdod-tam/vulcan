# frozen_string_literal: true

module CredentialManagement
  extend ActiveSupport::Concern

  included do
    before_action :set_credential, only: [:destroy]
  end

  # DELETE /:credential_type_credentials/:id
  def destroy
    if @credential.destroy
      redirect_to edit_profile_path, notice: "#{credential_type_name} removed successfully"
    else
      redirect_to edit_profile_path, alert: "Failed to remove #{credential_type_name.downcase}"
    end
  end

  # GET /:credential_type_credentials/create_success
  def create_success
    # Just renders the success view
  end

  protected

  # Methods to be implemented in including controllers
  def credential_type
    # Should return symbol like :webauthn, :totp, or :sms
    raise NotImplementedError, 'Controllers must implement credential_type'
  end

  def credential_type_name
    # Human-readable name, like 'Security key', 'Authenticator app', or 'SMS verification'
    case credential_type
    when :webauthn then 'Security key'
    when :totp then 'Authenticator app'
    when :sms then 'SMS verification'
    else credential_type.to_s.humanize
    end
  end

  def set_credential
    @credential = current_user.send("#{credential_type}_credentials").find(params[:id])
  rescue ActiveRecord::RecordNotFound
    redirect_to edit_profile_path, alert: "#{credential_type_name} not found"
  end
end
