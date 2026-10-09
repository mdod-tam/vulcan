# frozen_string_literal: true

# Repository-owned vendor agreement and its publication gate.
class VendorTerms
  def self.published?
    Rails.application.config_for(:vendor_terms)[:published] == true
  end

  def self.agreement
    Rails.application.config_for(:vendor_terms)[:agreement].to_s
  end

  def self.available?
    published? && agreement.strip.present?
  end
end
