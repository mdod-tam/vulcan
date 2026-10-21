# frozen_string_literal: true

module ProductResourcesHelper
  def product_resource_groups(product)
    product.product_resources.with_attached_document.by_language_and_title.to_a.group_by(&:locale)
           .sort_by { |locale, _| [locale == I18n.locale.to_s ? 0 : 1, locale] }
  end

  def product_resource_language(locale)
    t("product_resources.languages.#{locale}", default: locale)
  end

  def product_resource_product_label(product)
    [product.manufacturer, product.name, product.model_number].compact_blank.join(' · ')
  end

  def product_resource_heading_tag(level)
    raise ArgumentError, 'Product resource headings must use levels 2 through 6' unless (2..6).include?(level)

    "h#{level}"
  end

  def safe_manufacturer_documentation_url(product)
    product.documentation_url if WebUrlValidator.safe?(product.documentation_url)
  end
end
