# frozen_string_literal: true

module Icanconnect
  class Setting < ApplicationRecord
    include TypedDateInput

    self.table_name = 'icanconnect_settings'
    ID = 1

    typed_date_input :starts_on

    def self.active?(on: Date.current)
      starts_on = where(id: ID).pick(:starts_on)
      starts_on.present? && starts_on <= [Date.current, on.to_date].min
    end
  end
end
