# frozen_string_literal: true

module EmailDelivery
  # Saved and effective state of every email control, for the admin controls page. Saved state is
  # what an admin set; effective state says whether email actually goes out once the master
  # control and the category are taken into account.
  class ControlPanel
    Control = Data.define(:name, :label, :row, :saved_enabled, :suppressed_by) do
      def effective_enabled? = saved_enabled && suppressed_by.nil?
      def missing? = row.nil?
    end

    Pair = Data.define(:name, :format, :rows, :category, :saved_enabled, :mixed, :suppressed_by) do
      def effective_enabled? = saved_enabled && suppressed_by.nil?
      def primary_row = rows.find { |row| row.locale == 'en' } || rows.first
      def locales = rows.map { |row| row.locale.upcase }.sort
    end

    UNASSIGNED = 'unassigned'

    def initialize(templates: EmailTemplate.order(:name, :format, :locale))
      @templates = templates.to_a
      @controls = FeatureFlag.where(name: CONTROL_NAMES).index_by(&:name)
    end

    def global
      @global ||= begin
        row = @controls[GLOBAL_CONTROL]
        Control.new(name: GLOBAL_CONTROL, label: I18n.t('admin.email_delivery.global_label', locale: :en), row: row,
                    saved_enabled: row&.enabled, suppressed_by: row ? nil : :configuration_error)
      end
    end

    def categories
      Catalog::CATEGORIES.map { |category| category_control(category) }
    end

    def category_control(category)
      name = EmailDelivery.category_control(category)
      row = @controls[name]
      Control.new(name: name, label: self.class.category_label(category), row: row,
                  saved_enabled: row&.enabled, suppressed_by: upstream_suppression || (row ? nil : :configuration_error))
    end

    # { category => [Pair] } in catalog order, then templates no email uses.
    def pairs_by_category
      grouped = pairs.group_by(&:category)
      (Catalog::CATEGORIES + [UNASSIGNED]).filter_map do |category|
        [category, grouped[category]] if grouped[category].present?
      end.to_h
    end

    def pairs
      @pairs ||= @templates.reject(&:fragment?).group_by { |row| [row.name, row.format] }.map do |(name, format), rows|
        category = Catalog.template_categories[name] || UNASSIGNED
        Pair.new(name: name, format: format, rows: rows, category: category, saved_enabled: rows.all?(&:enabled),
                 mixed: rows.map(&:enabled).uniq.size > 1, suppressed_by: pair_suppression(category))
      end
    end

    def pair_for(template)
      pairs.find { |pair| pair.name == template.name && pair.format == template.format }
    end

    def fragments
      @templates.select(&:fragment?)
    end

    def self.category_label(category)
      I18n.t("admin.email_delivery.categories.#{category}", locale: :en)
    end

    # Why an email is not going out, in words an admin can act on.
    def self.reason_text(reason, category: nil)
      case reason.to_s
      when 'global_disabled' then I18n.t('admin.email_delivery.reasons.global_disabled', locale: :en)
      when 'category_disabled'
        I18n.t('admin.email_delivery.reasons.category_disabled', category: category_label(category).downcase, locale: :en)
      when 'template_disabled' then I18n.t('admin.email_delivery.reasons.template_disabled', locale: :en)
      when 'pending_canceled', 'legacy_context_missing' then I18n.t('admin.email_delivery.reasons.pending_canceled', locale: :en)
      else I18n.t('admin.email_delivery.reasons.configuration_error', locale: :en)
      end
    end

    private

    def pair_suppression(category)
      return upstream_suppression if upstream_suppression
      return if category == UNASSIGNED

      control = category_control(category)
      return :configuration_error if control.missing?

      :category_disabled unless control.saved_enabled
    end

    def upstream_suppression
      return :configuration_error if global.missing?

      :global_disabled unless global.saved_enabled
    end
  end
end
