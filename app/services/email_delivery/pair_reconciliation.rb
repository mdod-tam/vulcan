# frozen_string_literal: true

module EmailDelivery
  # Template pairs whose English and Spanish rows disagree. The approved policy is conservative:
  # a pair with any disabled locale is turned off entirely, so a locale that is sending today
  # stops. report lists exactly which locales stop, for review before apply! runs.
  module PairReconciliation
    Row = Data.define(:name, :format, :locales) do
      # Locales currently enabled that stop sending when the pair is turned off.
      def stopping_locales = locales.select { |_locale, enabled| enabled }.keys.sort
    end

    module_function

    def mixed_pairs
      EmailTemplate.deliverable.order(:name, :format, :locale).group_by { |row| [row.name, row.format] }
                                                              .filter_map do |(name, format), rows|
        next if rows.map(&:enabled).uniq.size < 2

        Row.new(name: name, format: format, locales: rows.to_h { |row| [row.locale, row.enabled] })
      end
    end

    def report
      pairs = mixed_pairs
      return 'No template pairs have mismatched English and Spanish settings.' if pairs.empty?

      lines = pairs.map do |pair|
        settings = pair.locales.sort.map { |locale, enabled| "#{locale.upcase} #{enabled ? 'on' : 'off'}" }.join(', ')
        "#{pair.name} (#{pair.format}): #{settings} -> stops #{pair.stopping_locales.map(&:upcase).join(', ')}"
      end
      (["#{pairs.size} template pairs will be turned off:"] + lines).join("\n")
    end

    # Turns every mixed pair off through the writer, which audits each change and cancels pending mail.
    # The operation id is per pair, so a rerun does not repeat a change.
    def apply!(actor:)
      mixed_pairs.map do |pair|
        ControlWriter.set_template_pair(name: pair.name, format: pair.format, enabled: false, actor: actor,
                                        operation_id: "pair-reconciliation:#{pair.name}:#{pair.format}")
      end
    end
  end
end
