# frozen_string_literal: true

class DuplicateDetectionService < BaseService
  CONTEXTS = %i[
    public_registration
    paper_new_self
    paper_new_guardian
    paper_new_dependent
    admin_create
  ].freeze

  PUBLIC_OUTCOMES = %i[redirect_sign_in support_only proceed].freeze
  RECOMMENDED_ACTIONS = %i[allow flag warn block].freeze

  SCORE_NAME_DOB = 1.0
  SCORE_ADDRESS_ZIP = 0.5
  SOFT_MATCH_THRESHOLD = 1.0

  STREET_SUFFIX_NORMALIZATIONS = {
    'st' => 'street',
    'rd' => 'road',
    'ave' => 'avenue',
    'blvd' => 'boulevard',
    'ln' => 'lane',
    'dr' => 'drive',
    'ct' => 'court',
    'pl' => 'place',
    'cir' => 'circle',
    'hwy' => 'highway'
  }.freeze

  Result = Struct.new(
    :matched_users,
    :score,
    :reasons,
    :hard_block,
    :recommended_action,
    :public_outcome
  ) do
    def blocked?
      hard_block == true
    end
  end

  def initialize(context:, attrs:, excluding_user_id: nil)
    super()
    @context = context.to_sym
    @attrs = attrs.with_indifferent_access
    @excluding_user_id = excluding_user_id
  end

  def call
    return failure('Invalid duplicate detection context') unless CONTEXTS.include?(@context)

    success(nil, evaluate)
  end

  private

  def evaluate
    if exact_contact_matching_context?
      if contact_pair_present?
        split_result = evaluate_email_phone_split
        return split_result if split_result.hard_block
      end

      email_result = evaluate_exact_email
      return email_result if email_result.hard_block

      phone_result = evaluate_exact_phone
      return phone_result if phone_result.hard_block
    end

    evaluate_soft_signals
  end

  def exact_contact_matching_context?
    CONTEXTS.include?(@context)
  end

  def public_registration_context?
    @context == :public_registration
  end

  def contact_pair_present?
    User.normalize_email(@attrs[:email]).present? && User.normalize_phone(@attrs[:phone]).present?
  end

  def evaluate_exact_email
    email = User.normalize_email(@attrs[:email])
    return empty_result if email.blank?

    matched_user = exclude_user(User.find_by_email(email))
    return empty_result if matched_user.blank?

    if matched_user.email_backed_public_portal_account?
      block_result(
        matched_users: [matched_user],
        reasons: ['exact_email'],
        public_outcome: public_email_outcome
      )
    else
      block_result(
        matched_users: [matched_user],
        reasons: ['exact_email_non_portal'],
        public_outcome: non_portal_email_outcome
      )
    end
  end

  def evaluate_exact_phone
    phone = User.normalize_phone(@attrs[:phone])
    return empty_result if phone.blank?

    matched_user = exclude_user(User.find_by_phone(phone))
    return empty_result unless matched_user&.real_phone?

    block_result(
      matched_users: [matched_user],
      reasons: ['exact_phone'],
      public_outcome: public_phone_outcome
    )
  end

  def evaluate_email_phone_split
    email = User.normalize_email(@attrs[:email])
    phone = User.normalize_phone(@attrs[:phone])

    email_user = exclude_user(User.find_by_email(email))
    phone_user = exclude_user(User.find_by_phone(phone))
    return empty_result if email_user.blank? || phone_user.blank?
    return empty_result unless phone_user.real_phone?
    return empty_result if email_user.id == phone_user.id

    if email_user.email_backed_public_portal_account?
      block_result(
        matched_users: [email_user, phone_user],
        reasons: %w[exact_email email_phone_split],
        public_outcome: public_email_outcome
      )
    else
      block_result(
        matched_users: [email_user, phone_user],
        reasons: %w[exact_email_non_portal email_phone_split],
        public_outcome: non_portal_email_outcome
      )
    end
  end

  def public_email_outcome
    public_registration_context? ? :redirect_sign_in : :proceed
  end

  def non_portal_email_outcome
    public_registration_context? ? :support_only : :proceed
  end

  def public_phone_outcome
    public_registration_context? ? :support_only : :proceed
  end

  def evaluate_soft_signals
    reasons = []
    matched_users = []
    score = 0.0

    name_dob_matches = find_name_dob_matches.to_a
    if name_dob_matches.any?
      reasons << 'name_dob'
      score += SCORE_NAME_DOB
      matched_users.concat(name_dob_matches)

      address_matches = name_dob_matches.select { |user| address_zip_match?(user) }
      if address_matches.any?
        reasons << 'address_zip'
        score += SCORE_ADDRESS_ZIP
      end

      reasons << 'address_only_record' if address_only_intake? && address_matches.any?(&:address_only_contact?)
    end

    if score >= SOFT_MATCH_THRESHOLD
      return Result.new(
        matched_users: matched_users.uniq,
        score: score,
        reasons: reasons.uniq,
        hard_block: false,
        recommended_action: :flag,
        public_outcome: :proceed
      )
    end

    Result.new(
      matched_users: matched_users.uniq,
      score: score,
      reasons: reasons.uniq,
      hard_block: false,
      recommended_action: :allow,
      public_outcome: :proceed
    )
  end

  def address_only_intake?
    User.normalize_email(@attrs[:email]).blank? && User.normalize_phone(@attrs[:phone]).blank?
  end

  def address_zip_match?(user)
    submitted_address = normalize_address_line(@attrs[:physical_address_1])
    submitted_zip = normalize_zip_code(@attrs[:zip_code])
    return false if submitted_address.blank? || submitted_zip.blank?

    stored_address = normalize_address_line(user.physical_address_1)
    stored_zip = normalize_zip_code(user.zip_code)
    return false if stored_address.blank? || stored_zip.blank?

    submitted_address == stored_address && submitted_zip == stored_zip
  end

  def normalize_address_line(address)
    normalized = address.to_s.strip.downcase.gsub(/[^a-z0-9\s]/, ' ')
    words = normalized.split.compact_blank
    words.map { |word| STREET_SUFFIX_NORMALIZATIONS.fetch(word, word) }.join
  end

  def normalize_zip_code(zip_code)
    digits = zip_code.to_s.gsub(/\D/, '')
    digits.first(5).presence
  end

  def find_name_dob_matches
    first_name = @attrs[:first_name].to_s.strip
    last_name = @attrs[:last_name].to_s.strip
    date_of_birth = @attrs[:date_of_birth]
    return Users::Constituent.none if first_name.blank? || last_name.blank? || date_of_birth.blank?

    query = Users::Constituent.find_duplicates(first_name, last_name, date_of_birth)
    query = query.where.not(id: @excluding_user_id) if @excluding_user_id.present?
    query
  end

  def exclude_user(user)
    return nil if user.blank?
    return nil if @excluding_user_id.present? && user.id == @excluding_user_id

    user
  end

  def block_result(matched_users:, reasons:, public_outcome:)
    Result.new(
      matched_users: matched_users,
      score: 100.0,
      reasons: reasons,
      hard_block: true,
      recommended_action: :block,
      public_outcome: public_outcome
    )
  end

  def empty_result
    Result.new(
      matched_users: [],
      score: 0.0,
      reasons: [],
      hard_block: false,
      recommended_action: :allow,
      public_outcome: :proceed
    )
  end
end
