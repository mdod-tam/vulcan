# frozen_string_literal: true

module Admin
  class TestEmailForm
    include ActiveModel::Model
    include ActiveModel::Validations

    attr_accessor :email, :template_id

    validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
    validates :template_id, presence: true

    def initialize(attributes = {})
      @email = attributes[:email]
      @template_id = attributes[:template_id]
    end

    def email_template
      return @email_template if defined?(@email_template)

      @email_template = EmailTemplate.find_by(id: template_id)
    end
  end
end
