# frozen_string_literal: true

module ProductIdentity
  def self.normalize(value)
    value.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
  end

  def self.key(manufacturer, model_number)
    Digest::SHA256.hexdigest([normalize(manufacturer), normalize(model_number)].to_json)
  end
end
