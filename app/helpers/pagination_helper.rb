# frozen_string_literal: true

module PaginationHelper
  LINK_CLASSES = %w[
    inline-flex min-h-11 min-w-11 items-center justify-center rounded-md border border-gray-300
    bg-white px-3 text-sm font-medium text-gray-700 hover:bg-gray-50
    focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2
  ].join(' ').freeze

  def pagination_link(pagy, page, text = page, rel: nil)
    page_label = t('pagination.page', page: page)
    label = rel ? "#{text}, #{page_label}" : page_label
    link_to text, pagy_url_for(pagy, page), rel: rel, aria: { label: label }, class: LINK_CLASSES
  end
end
