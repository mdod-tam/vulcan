# frozen_string_literal: true

Rails.application.configure do
  config.after_initialize do
    if Rails.application.credentials.docuseal.present?
      Docuseal.key = Rails.application.credentials.docuseal[:api_key]
      Docuseal.url = Rails.application.credentials.docuseal[:base_url] || 'https://api.docuseal.com'

      Rails.logger.info 'DocuSeal API configured successfully'
    else
      Rails.logger.warn 'DocuSeal credentials not configured - document signing functionality will not work'
    end
  end
end
