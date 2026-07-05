# frozen_string_literal: true

module ProgramContact
  OFFICE_ADDRESS = '301 W. Preston Street, Suite 1008A, Baltimore MD 21201'
  SUPPORT_PHONE = '410-767-6960'
  SUPPORT_VIDEOPHONE = '443-453-5970'
  WEBSITE_URL = 'www.mdmat.org'

  module_function

  def office_address
    OFFICE_ADDRESS
  end

  def support_phone
    SUPPORT_PHONE
  end

  def support_videophone
    SUPPORT_VIDEOPHONE
  end

  def support_videophone_label
    "#{SUPPORT_VIDEOPHONE} (VP)"
  end

  def support_phone_display
    "#{SUPPORT_PHONE} or #{support_videophone_label}"
  end

  def website_url
    WEBSITE_URL
  end
end
