# frozen_string_literal: true

require 'openssl'

module UserEmailSearch
  extend ActiveSupport::Concern

  MINIMUM_EMAIL_TOKEN_LENGTH = 3
  EMAIL_SEGMENT_SPLIT = /[._+-]+/

  included do
    has_many :email_search_tokens,
             class_name: 'UserEmailSearchToken',
             dependent: :destroy,
             inverse_of: :user

    after_save :refresh_email_search_tokens, if: :email_search_tokens_need_refresh?
  end

  class_methods do
    def with_email_search_match(query)
      token_digest = email_search_token_digest_for_query(query)
      return none if token_digest.blank?

      direct_user_ids = UserEmailSearchToken.where(token_digest: token_digest).select(:user_id)
      # Dependents without their own contact email are searchable by any linked guardian email.
      dependent_ids = GuardianRelationship
                      .where(guardian_id: direct_user_ids)
                      .where(dependent_id: users_without_dependent_email.select(:id))
                      .select(:dependent_id)

      where(id: direct_user_ids).or(where(id: dependent_ids))
    end

    def email_search_token_digest_for_query(query)
      normalized_token = normalize_email_search_token(query)
      return nil if normalized_token.blank? || normalized_token.length < MINIMUM_EMAIL_TOKEN_LENGTH

      email_search_token_digest(normalized_token)
    end

    def email_search_token_digest(token)
      OpenSSL::HMAC.hexdigest('SHA256', email_search_secret, token)
    end

    def email_search_tokens_for(*emails)
      emails.flat_map { |email| tokens_for_email(email) }.uniq
    end

    def tokens_for_email(email)
      normalized_email = normalize_email(email)
      return [] unless normalized_email&.include?('@')

      local_part, domain = normalized_email.split('@', 2)
      domain_labels = domain.to_s.split('.')

      tokens = [normalized_email, domain]
      tokens.concat(prefixes_for(normalized_email))
      tokens.concat(prefixes_for(local_part))
      tokens.concat(local_part.to_s.split(EMAIL_SEGMENT_SPLIT).flat_map { |segment| prefixes_for(segment) })
      tokens.concat(domain_labels[0...-1].to_a.flat_map { |label| prefixes_for(label) })

      tokens.compact_blank.select { |token| token.length >= MINIMUM_EMAIL_TOKEN_LENGTH }.uniq
    end

    private

    def normalize_email_search_token(query)
      query.to_s.strip.downcase.presence
    end

    def prefixes_for(value)
      value = value.to_s
      return [] if value.length < MINIMUM_EMAIL_TOKEN_LENGTH

      (MINIMUM_EMAIL_TOKEN_LENGTH..value.length).map { |length| value.first(length) }
    end

    def users_without_dependent_email
      where(dependent_email: nil).or(where(dependent_email: ''))
    end

    def email_search_secret
      Rails.application.key_generator.generate_key('user-email-search-token', 32)
    end
  end

  def rebuild_email_search_tokens!
    digests = self.class.email_search_tokens_for(email, dependent_email)
                  .map { |token| self.class.email_search_token_digest(token) }

    email_search_tokens.delete_all
    return if digests.empty?

    digests.each { |digest| email_search_tokens.create!(token_digest: digest) }
  end

  private

  def refresh_email_search_tokens
    rebuild_email_search_tokens!
  end

  def email_search_tokens_need_refresh?
    return false unless user_email_search_tokens_table_available?

    saved_change_to_email? || saved_change_to_dependent_email? || !email_search_tokens.exists?
  end

  def user_email_search_tokens_table_available?
    UserEmailSearchToken.table_exists?
  end
end
