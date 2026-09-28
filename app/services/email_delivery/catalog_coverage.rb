# frozen_string_literal: true

module EmailDelivery
  # Compares the catalog with the mailers the application defines. The catalog test runs this in CI,
  # so adding a mailer action without classifying it fails the build instead of blocking mail in production.
  module CatalogCoverage
    # Positional arguments each NotificationService adapter passes.
    ADAPTER_ARITY = {
      recipient: 1,
      proof_review: 2,
      proof_attached: 2,
      vendor_params: 0,
      notifiable: 1,
      notifiable_and_notification: 2
    }.freeze

    module_function

    def application_mailers
      Rails.application.eager_load!
      ActionMailer::Base.descendants.select do |mailer|
        next false if mailer.name.nil? || Catalog::NON_SENDING_MAILERS.include?(mailer.name)

        path = Object.const_source_location(mailer.name)&.first.to_s
        path.start_with?(Rails.root.join('app/mailers').to_s)
      end
    end

    # Mailer actions with no catalog entry. Helper-module methods are excluded by module name only.
    def unclassified_actions(mailers = application_mailers)
      mailers.flat_map do |mailer|
        current_actions(mailer).filter_map do |action|
          owner = mailer.instance_method(action).owner
          next if Catalog::HELPER_MODULES.include?(owner.name)

          key = "#{mailer.name}##{action}"
          key unless Catalog.mail_action(key)
        end
      end.sort
    end

    # Action Mailer caches its action list; recompute it so a method stubbed and removed earlier
    # in the process is not reported.
    def current_actions(mailer)
      mailer.clear_action_methods!
      mailer.action_methods
    end

    # Catalog entries whose mailer action no longer exists.
    def stale_entries(mailers = application_mailers)
      defined = mailers.flat_map { |mailer| current_actions(mailer).map { |action| "#{mailer.name}##{action}" } }
      Catalog::MAIL_ACTIONS.keys.reject { |key| key.start_with?('DocuSeal#') || defined.include?(key) }.sort
    end

    # Notification actions whose adapter passes arguments the mailer method cannot accept.
    def incompatible_dispatch_contracts
      Catalog::NOTIFICATION_ACTIONS.values.reject(&:audit_only?).filter_map do |entry|
        mailer, method = entry.mail_action.split('#')
        parameters = mailer.constantize.instance_method(method).parameters
        passed = ADAPTER_ARITY.fetch(entry.adapter)
        required = parameters.count { |type, _| type == :req }
        optional = parameters.count { |type, _| type == :opt }
        next if parameters.any? { |type, _| type == :rest } && passed >= required
        next if passed.between?(required, required + optional)

        "#{entry.action} passes #{passed} to #{entry.mail_action}(#{parameters.map(&:last).join(', ')})"
      end
    end
  end
end
