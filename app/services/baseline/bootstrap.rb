# frozen_string_literal: true

module Baseline
  # Initializes an environment after its schemas are migrated. `bin/rails db:bootstrap` validates input, migrates,
  # then calls run!. It overwrites staff-edited baseline data but never changes an existing eligible administrator.
  module Bootstrap
    class ConfigurationError < StandardError; end
    class VerificationError < StandardError; end
    class CommittedError < StandardError; end

    ADMINISTRATOR_ENV = {
      email: 'BOOTSTRAP_ADMIN_EMAIL', first_name: 'BOOTSTRAP_ADMIN_FIRST_NAME',
      last_name: 'BOOTSTRAP_ADMIN_LAST_NAME', password: 'BOOTSTRAP_ADMIN_PASSWORD'
    }.freeze

    # Reads the human administrator's deployment inputs. Raises before any write when one is missing.
    def self.administrator_input(env = ENV)
      input = ADMINISTRATOR_ENV.transform_values { |name| env[name] }
      missing = ADMINISTRATOR_ENV.values_at(*input.select { |_key, value| value.blank? }.keys)
      raise ConfigurationError, "Set #{missing.join(', ')} before bootstrapping." if missing.any?
      if User.normalize_email(input[:email]) == PublicAuditActor::SYSTEM_AUDIT_EMAIL
        raise ConfigurationError, "#{ADMINISTRATOR_ENV[:email]} must differ from the system audit address."
      end

      input
    end

    def self.run!(input: administrator_input, out: $stdout)
      ApplicationRecord.transaction do
        system_actor = Accounts.provision_system_audit_actor!
        Accounts.provision_administrator!(**input)
        Policies.reset!(actor: system_actor)
        FeatureFlags.reset!(actor: system_actor)
        RejectionReasons.reset!(actor: system_actor)
        EmailTemplates::Catalog.replace!(actor: system_actor)
        verify!(input)
      end

      begin
        verify!(input)
      rescue StandardError => e
        raise CommittedError, "Bootstrap committed but its readback failed (#{e.message}). The changes were not rolled back; rerun db:bootstrap."
      end
      out.puts summary
    end

    # Required-record checks, run before commit and again after it.
    def self.verify!(input)
      problems = []
      problems << 'the system audit administrator is missing' unless PublicAuditActor.system_audit_actor
      problems << 'the administrator is missing' unless User.admins.exists?(email: User.normalize_email(input[:email]))
      problems << 'policy values differ from the defaults' unless Policy.where(key: Policies::DEFAULTS.keys).pluck(:key, :value).to_h == Policies::DEFAULTS
      unless FeatureFlag.where(name: FeatureFlags::DEFAULTS.keys).pluck(:name, :enabled).to_h == FeatureFlags::DEFAULTS
        problems << 'feature flags differ from the defaults'
      end
      problems << 'rejection reasons differ from the catalog' unless rejection_reasons_current?
      report = EmailTemplates::Audit.run
      problems.concat(EmailTemplates::Audit.blocking_findings(report))
      raise VerificationError, problems.join('; ') if problems.any?
    end

    def self.rejection_reasons_current?
      expected = RejectionReasons::DEFINITIONS.flat_map do |definition|
        RejectionReasons::LOCALES.map { |locale| [[definition[:code], definition[:proof_type], locale], definition.fetch(:"#{locale}_body")] }
      end.to_h
      stored = RejectionReason.where(needs_sync: false).pluck(:code, :proof_type, :locale, :body).to_h { |*key, body| [key, body] }
      expected.all? { |key, body| stored[key] == body }
    end
    private_class_method :rejection_reasons_current?

    def self.summary
      "Bootstrap complete: #{Policy.count} policies, #{FeatureFlag.count} feature flags, #{RejectionReason.count} rejection reasons, " \
        "#{EmailTemplate.count} email templates. Sign in as the configured administrator and enroll in MFA."
    end
    private_class_method :summary
  end
end
