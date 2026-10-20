# frozen_string_literal: true

class ProductResource < ApplicationRecord
  self.filter_attributes += [:url]

  belongs_to :product
  has_one_attached :document

  normalizes :title, with: ->(value) { value.to_s.strip.presence }
  validates :title, :locale, presence: true
  validates :locale, inclusion: { in: ->(_) { I18n.available_locales.map(&:to_s) } }
  validates :url, web_url: true, allow_blank: true
  validates :document, document: { purpose: :product_resource }
  validate :exactly_one_source

  scope :by_language_and_title, -> { order(:locale, :title, :id) }

  def source_type
    url.present? ? 'url' : 'pdf'
  end

  private

  def exactly_one_source
    return if url.present? != document.attached?

    errors.add(:base, 'Choose exactly one external link or PDF document.')
  end
end
