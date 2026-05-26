# frozen_string_literal: true

class UserEmailSearchToken < ApplicationRecord
  belongs_to :user

  validates :token_digest, presence: true, uniqueness: { scope: :user_id }
end
