# frozen_string_literal: true

module Applications
  # Server-issued attestation that staff looked at specific possible matches and decided none of
  # them is this applicant.
  #
  # Paper intake asks staff to decide only where the computer is genuinely unsure. Two people can
  # legitimately share a name and date of birth, so a soft match is a real decision: creating
  # automatically risks a duplicate, refusing automatically turns away a legitimate applicant. This
  # token is the record that the decision was made, and what it was made about.
  #
  # It exists only for that override. Nothing surfacing is not a decision -- the server's own search,
  # run against the completed applicant immediately before the write, establishes that -- and an
  # exact contact collision is not a decision either, because it cannot be overridden at all.
  #
  # The failure it closes is ordinary, not adversarial. Staff review the matches for "John Smith",
  # get pulled away, come back, realize it is actually the daughter's application, change the name to
  # "Jane Smith", and submit. Everyone did their job and a duplicate is created anyway, because the
  # "these are different people" was about a different person than the record being written.
  #
  # ## Why signed rather than a digest of what the client holds
  #
  # A digest of candidate ids proves only that the client *knows* those ids, which any client can
  # arrange. This is an HMAC the server issues when it shows staff the candidates, so a decision
  # cannot be manufactured by a request that never saw them. It is admin-only behind authentication,
  # so the threat model is weak; the point is provenance, not defence against a hostile admin.
  #
  # ## Why nothing is carried in the token
  #
  # The token is `v1:<issued_at>:<hmac>`. The payload is *recomputed* at the write boundary from the
  # submitted facts and a fresh detection run, then re-signed and compared. Nothing about the
  # applicant travels in the token, so there is no name, date of birth, or contact value to leak or
  # tamper with, and a stale decision cannot survive a changed identity: change any bound fact and
  # the recomputed HMAC simply stops matching.
  #
  # ## What it does not claim
  #
  # Recomputing at the write boundary closes stale *client* state, and nothing more. This token is
  # stateless -- it is never marked spent -- so on its own it can be presented twice. Two concurrent
  # submissions racing between the read and the write are excluded separately, by the identity
  # advisory lock in PaperApplicationService. The honest contract for this object alone is: staff
  # reviewed the candidate snapshot as recomputed at the write boundary.
  class PaperIdentityDecision
    VERSION = 'v1'
    HMAC_PURPOSE = 'applications/paper_identity_decision'

    # A decision goes stale on its own so an old form left open overnight cannot authorize a
    # creation the next day, even if nothing about the identity changed in between.
    MAX_AGE = 30.minutes

    Result = Struct.new(:valid, :reason) do
      def valid? = valid
    end

    # The facts a decision is bound to, carried together because they are meaningless apart: a
    # decision is always "this admin, about this identity, having seen these candidates matching for
    # these reasons, in this context".
    #
    # `candidates` is the presented snapshot -- the exact rows the browser rendered -- not a list of
    # ids. Ids alone answered "were these the same records", but staff decide on what they can see:
    # a name, a date of birth, a city, and whether the row could be selected at all. Those can each
    # change while the ids and the reason codes stay identical, and a decision that survives that
    # was made about a screen that no longer exists.
    Facts = Struct.new(:context, :admin, :identity, :candidates, :reasons)

    class << self
      # Issued when the server shows staff the candidates it found.
      def issue(facts, issued_at: Time.current)
        stamp = issued_at.to_i
        "#{VERSION}:#{stamp}:#{signature(facts, stamp)}"
      end

      # The instant a given token stops verifying -- the *first* moment `verify` will reject it, not
      # the last moment it works. Derived from the stamp the token was signed with and from the same
      # comparison `verify` uses, so a UI counting down to this value and the server enforcing it
      # agree to the second rather than differing by one.
      def expires_at(token)
        stamp = token.to_s.split(':', 3)[1]
        return nil unless stamp.to_s.match?(/\A\d+\z/)

        Time.zone.at(stamp.to_i + MAX_AGE.to_i)
      end

      # Verified at the write boundary against a *freshly recomputed* candidate set, never against
      # anything the request supplied.
      def verify(token, facts, now: Time.current)
        version, stamp, digest = token.to_s.split(':', 3)
        return Result.new(false, :malformed) if digest.blank? || version != VERSION
        return Result.new(false, :malformed) unless stamp.to_s.match?(/\A\d+\z/)
        return Result.new(false, :expired) if now.to_i - stamp.to_i >= MAX_AGE.to_i

        expected = signature(facts, stamp.to_i)
        return Result.new(false, :mismatched) unless ActiveSupport::SecurityUtils.secure_compare(digest, expected)

        Result.new(true, nil)
      end

      private

      # Bound to the decision context, the admin who made it, the identity it was made about, the
      # exact candidate rows shown, the reasons those candidates matched, and when it was issued.
      # Sorted so an order change in either list is not a different decision.
      def signature(facts, stamp)
        payload = JSON.generate(
          {
            'context' => facts.context.to_s,
            'admin_id' => facts.admin&.id.to_s,
            'identity' => identity_fingerprint(facts.identity),
            'candidates' => candidates_fingerprint(facts.candidates),
            'reasons' => Array(facts.reasons).map(&:to_s).sort,
            'issued_at' => stamp
          }
        )
        OpenSSL::HMAC.hexdigest('SHA256', hmac_key, payload)
      end

      # Fingerprints the rows as presented, so any displayed fact that changes invalidates the
      # decision -- including `selectable`, since "this row offered no way to pick it" is part of
      # what staff were looking at when they concluded these are different people.
      #
      # Hashed rather than embedded for the same reason as the identity: a name plus a date of birth
      # plus a city is low-entropy PII, and the token travels through a form field and a log.
      # Ordered by id so the browser's rendering order is not a different decision, and keys sorted
      # within each row so a serializer change is not either.
      def candidates_fingerprint(candidates)
        canonical = Array(candidates)
                    .map { |candidate| candidate.to_h.transform_keys(&:to_s).sort.to_h }
                    .sort_by { |candidate| candidate['id'].to_i }
        OpenSSL::HMAC.hexdigest('SHA256', hmac_key, JSON.generate(canonical))
      end

      # Fingerprints **every** fact duplicate detection was given, not a chosen subset. Binding only
      # name/DOB/contact left a gap: swapping one non-matching address for another preserves the
      # candidate ids and the reason codes, so a decision stayed valid while a fact that feeds
      # matching had changed underneath it.
      #
      # Canonicalization is deliberately not repeated here. The caller passes the same hash it hands
      # DuplicateDetectionService, so there is one definition of "the same facts" rather than two
      # that can drift apart. Note that hash is only *partially* normalized: `duplicate_detection_attrs`
      # canonicalizes email, phone and date of birth, while names, address lines, city, state and ZIP
      # are passed through as submitted and therefore compared strictly. Sorted so key order is not a
      # different decision.
      #
      # Hashed rather than embedded for the reason the portal request fingerprint is keyed: a name
      # plus a date of birth plus an address is partly low-entropy PII, and a plain digest of it is a
      # searchable index into that data.
      def identity_fingerprint(identity)
        # Typed values are preserved rather than stringified: `nil` and `""` are different facts --
        # "no second address line supplied" is not "second address line cleared" -- and collapsing
        # them would let one replace the other under a decision issued for the first.
        canonical = JSON.generate(identity.to_h.transform_keys(&:to_s).sort.to_h)
        OpenSSL::HMAC.hexdigest('SHA256', hmac_key, canonical)
      end

      def hmac_key
        Rails.application.key_generator.generate_key(HMAC_PURPOSE, 32)
      end
    end
  end
end
