# frozen_string_literal: true

class EmailDeliveryReceipt < ApplicationRecord
  belongs_to :email_delivery_attempt
  validates :event_key, :occurred_at, presence: true
  validates :kind, inclusion: { in: %w[delivered bounced complained opened delayed] }
end
