# frozen_string_literal: true

FactoryBot.define do
  factory :product_resource do
    product
    title { 'Getting started' }
    locale { 'en' }
    url { 'https://example.com/guide' }
  end
end
