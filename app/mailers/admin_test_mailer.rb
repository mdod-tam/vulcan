# frozen_string_literal: true

# Mailer used solely for sending test previews of EmailTemplates to admins.
class AdminTestMailer < ApplicationMailer
  # Sends a test email using pre-rendered content.
  # Expects :user, :recipient_email, :template_name, :subject, :body, :format in params.
  def test_email
    @user = params[:user]
    @body = params[:body]
    recipient_email = params[:recipient_email] || @user.email
    subject = "[TEST] #{params[:subject]} (Template: #{params[:template_name]})"
    # Ensure :format is a symbol (:html or :text)
    params[:format] = params[:format].to_sym

    mail(to: recipient_email, subject: subject) do |format|
      format.text { render plain: @body } # Render pre-rendered text
    end
  end
end
