# frozen_string_literal: true

module Icanconnect
  module ServiceFunding
    def self.snapshot!(record, service_date:)
      date = service_date.respond_to?(:to_date) ? service_date.to_date : Date.iso8601(service_date.to_s)
      record.funding_source ||= 'mat'
      record.funding_service_on = date
    end
  end
end
