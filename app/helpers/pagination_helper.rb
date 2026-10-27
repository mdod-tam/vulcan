# frozen_string_literal: true

module PaginationHelper
  LINK_CLASSES = 'btn btn-outline min-h-11 min-w-11'

  def pagination_link(pagy, page, text = page, rel: nil)
    page_label = t('pagination.page', page: page)
    label = rel ? "#{text}, #{page_label}" : page_label
    link_to text, pagy_url_for(pagy, page), rel: rel, aria: { label: label }, class: LINK_CLASSES
  end
end
