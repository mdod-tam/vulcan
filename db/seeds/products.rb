# frozen_string_literal: true

require 'yaml'

module Seeds
  module Products
    def self.catalog
      YAML.load_file(Rails.root.join('db/seeds/products.yml')).flat_map do |category, rows|
        rows.map { |attributes| attributes.merge('category' => category) }
      end
    end

    def self.required_keys
      catalog.map { |attributes| attributes.fetch('catalog_key') }
    end

    def self.call
      Product.transaction do
        entries = catalog
        entries.each do |attributes|
          Product.find_or_initialize_by(catalog_key: attributes.fetch('catalog_key')).update!(attributes)
        end
        Product.active.where.not(catalog_key: nil).where.not(catalog_key: entries.map { |attributes| attributes.fetch('catalog_key') }).find_each(&:archive!)
      end
    end
  end
end
