# frozen_string_literal: true

FactoryBot.define do
  factory :feature_flag do
    sequence(:name) { |n| "feature_#{n}" }
    enabled { true }
  end
end
