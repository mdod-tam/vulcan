# frozen_string_literal: true

module Admin
  module ReportsHelper
    REPORT_SECTIONS = {
      index: 'Applications', evaluation_metrics: 'Evaluations and training', equipment_distribution: 'Equipment orders',
      vendor_performance: 'Vendor performance', mfr: 'MFR reports'
    }.freeze
    SERVICE_VIEWS = {
      'appointments' => 'Appointments and hours', 'timing' => 'Reports and scheduling', 'devices' => 'Devices'
    }.freeze
    SERIES_COLORS = %w[#4f46e5 #0e7490 #b45309 #9333ea #047857 #be185d #475569 #9a3412].freeze
    LINE_DASHES = [[], [6, 4], [2, 3]].freeze
    FEW_VENDOR_SHAPES = %w[circle rect triangle rectRot].freeze
    HORIZONTAL_CHART_HEIGHTS = { 5 => 'h-72', 8 => 'h-96', 11 => 'h-[30rem]', 15 => 'h-[38rem]' }.freeze

    def report_path(section, **params)
      return admin_reports_path(params) if section == :index

      public_send(:"#{section}_admin_reports_path", params)
    end

    def report_date_range(range)
      [range.begin, range.end].map { |date| date.strftime('%b %-d, %Y') }.join(' to ')
    end

    def report_months(period)
      period.months.map { |month| month.strftime('%b %Y') }
    end

    def report_number(value)
      value.is_a?(Numeric) ? number_with_delimiter(value) : value.presence || 'No data'
    end

    def report_days(value)
      value.nil? ? 'No data' : "#{report_number(value)} #{'day'.pluralize(value)}"
    end

    def report_no_results
      tag.p 'No results for these dates.', class: 'mb-3 text-sm text-gray-600'
    end

    def report_equipment_stages
      {
        awaiting_bid: ['Devices waiting for a bid', admin_equipment_index_path(tab: 'needs_ordering')],
        awaiting_award: ['Bid groups awaiting award', admin_bid_groups_path(state: 'awaiting_award')],
        awaiting_send: ['Orders without a sent date', admin_purchase_orders_path(state: 'unsent')],
        awaiting_shipment: ['Purchase orders awaiting shipment', admin_equipment_index_path(tab: 'ordered', source: 'vendor')],
        awaiting_delivery: ['Shipped units missing delivery dates', admin_equipment_index_path(tab: 'shipped', delivery: 'awaiting')]
      }
    end

    def report_outstanding_order_rows(orders)
      orders.map do |entry|
        vendor = entry.order.vendor_name.presence || 'Vendor not recorded'
        order_link = link_to "#{vendor} · PO #{entry.order.number}", admin_purchase_order_path(entry.order), class: 'text-primary-700 underline'
        [order_link, entry.units, entry.days]
      end
    end

    def report_chart(title, labels, series, category:, unit:, **settings)
      type = settings.fetch(:type, 'bar')
      horizontal = settings.fetch(:horizontal, false)
      stacked = settings.fetch(:stacked, false)
      config = report_chart_config(labels, series, unit:, type:, horizontal:, stacked:)
      rows = labels.each_with_index.map { |label, i| [label, *series.values.map { |values| values[i] }] }
      show_zero = settings[:show_zero]
      measured = series.values.flatten.compact
      available = show_zero ? measured.any? : measured.any?(&:nonzero?)
      height = horizontal ? report_horizontal_height(labels.size) : 'h-72'
      headings = series.keys.map { |name| settings[:table_unit] ? "#{name} (#{settings[:table_unit]})" : name }
      render 'chart', title:, config:, headers: [category, *headings], rows:, available:, height:, note: settings[:note],
                      data_table: settings.fetch(:data_table, true), data_label: settings[:data_label], show_empty: settings.fetch(:show_empty, true)
    end

    def report_equipment_type_chart_config(chart_data, vouchers_enabled:)
      series = { 'Shipped units' => chart_data.fetch(:non_voucher).values }
      series['Units from vouchers'] = chart_data.fetch(:voucher).values if vouchers_enabled
      report_chart_config(chart_data.fetch(:non_voucher).keys, series, unit: 'Units', type: 'bar', horizontal: false, stacked: false)
    end

    def report_vendor_scatter(rows)
      title = 'Shipment volume versus speed'
      datasets = rows.each_with_index.map do |(vendor, volume, days), index|
        report_dataset(vendor, [{ x: volume, y: days }], index, type: 'scatter')
      end
      scales = { x: { beginAtZero: true, title: { display: true, text: 'Units shipped' } },
                 y: { beginAtZero: true, title: { display: true, text: 'Median days to ship' } } }
      options = report_chart_options(horizontal: false, scales:, multiple: datasets.size > 1)
      options[:plugins][:legend][:labels] = { usePointStyle: true, boxWidth: 12 }
      config = { type: 'scatter', data: { datasets: }, options: }
      render 'chart', title:, config:, headers: ['Vendor', 'Units shipped', 'Median days to ship'], rows:,
                      available: rows.any?, height: 'h-80', note: 'From order sent to shipment.', data_label: 'shipment volume and speed'
    end

    def report_product_chart(title, rows, category:, unit:, people_on_axis: false, **settings)
      label_index, series_index = people_on_axis ? [0, 1] : [1, 0]
      counts = rows.group_by { |row| row[label_index] }.transform_values { |matches| matches.sum(&:last) }
      labels = counts.sort_by { |label, count| [-count, label] }.map(&:first)
      series_names = rows.pluck(series_index).uniq.sort
      pairs = rows.to_h { |row| [[row[series_index], row[label_index]], row.last] }
      series = series_names.index_with { |name| labels.map { |label| pairs.fetch([name, label], 0) } }
      report_chart(title, labels, series, category:, unit:, horizontal: true, stacked: true, **settings)
    end

    private

    def report_chart_config(labels, series, unit:, type:, horizontal:, stacked:)
      datasets = series.each_with_index.map { |(name, data), i| report_dataset(name, data, i, type:) }
      category_axis, value_axis = horizontal ? %i[y x] : %i[x y]
      scales = {
        category_axis => { stacked:, grid: { display: false }, ticks: { maxRotation: 0 } },
        value_axis => { stacked:, beginAtZero: true, title: { display: true, text: unit } }
      }
      options = report_chart_options(horizontal:, scales:, multiple: datasets.size > 1)
      { type:, data: { labels: report_axis_labels(labels, horizontal), datasets: }, options: }
    end

    def report_horizontal_height(categories)
      HORIZONTAL_CHART_HEIGHTS.find { |count, _height| categories <= count }&.last || 'h-[48rem]'
    end

    def report_chart_options(horizontal:, scales:, multiple:)
      {
        responsive: true, maintainAspectRatio: false, animation: false, indexAxis: horizontal ? 'y' : 'x',
        scales:, plugins: { legend: { display: multiple, position: 'bottom', labels: { boxWidth: 14 }, onClick: nil } }
      }
    end

    def report_axis_labels(labels, horizontal)
      labels.map do |label|
        horizontal ? truncate(label, length: 25, separator: ' ') : label
      end
    end

    def report_dataset(name, values, index, type:)
      color = SERIES_COLORS[index % SERIES_COLORS.size]
      data = values.map { |value| value.is_a?(BigDecimal) ? value.to_f : value }
      dataset = { label: name, data:, backgroundColor: color, borderColor: color }
      case type
      when 'line' then dataset.merge(pointRadius: 3, borderWidth: 2, borderDash: LINE_DASHES[index % LINE_DASHES.size])
      when 'scatter' then dataset.merge(pointRadius: 6, pointStyle: FEW_VENDOR_SHAPES[index % FEW_VENDOR_SHAPES.size])
      else dataset.merge(maxBarThickness: 32)
      end
    end
  end
end
