# frozen_string_literal: true

module Applications
  # Serializes paper writers that are about to create the same identity. There is no row to lock
  # before creation, so the key is the same name/date-of-birth identity used by duplicate matching.
  class PaperIdentityCreationLock
    TRANSACTION_REQUIRED_MESSAGE = 'PaperIdentityCreationLock.lock! must run inside an open transaction'

    class << self
      def lock!(identity_facts)
        connection = ActiveRecord::Base.connection
        raise ArgumentError, TRANSACTION_REQUIRED_MESSAGE unless connection.transaction_open?

        connection.exec_query(
          'SELECT pg_advisory_xact_lock($1)::text',
          'Paper identity lock',
          [ActiveRecord::Relation::QueryAttribute.new(
            'key', key_for(identity_facts), ActiveRecord::Type::BigInteger.new
          )]
        )
      end

      def key_for(identity_facts)
        facts = identity_facts.to_h.with_indifferent_access
        canonical = JSON.generate(
          [facts[:first_name].to_s.downcase.strip,
           facts[:last_name].to_s.downcase.strip,
           facts[:date_of_birth].to_s]
        )
        Digest::SHA256.digest(canonical).unpack1('q>')
      end

      private :key_for
    end
  end
end
