# frozen_string_literal: true

FactoryBot.define do
  factory :report do
    title { 'Vendor Performance Report' }
    content { 'This report contains detailed performance metrics for vendors.' }
  end
end
