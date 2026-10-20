# frozen_string_literal: true

require 'test_helper'

class FilterParameterLoggingTest < ActiveSupport::TestCase
  test 'vendor TIN parameters are filtered at every request nesting level' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter('business_tax_id' => '123456789', 'vendor' => { 'business_tax_id' => '987654321' },
                             'users_vendor' => { 'business_tax_id' => '98-7654321' })

    assert_equal '[FILTERED]', filtered['business_tax_id']
    assert_equal '[FILTERED]', filtered.dig('vendor', 'business_tax_id')
    assert_equal '[FILTERED]', filtered.dig('users_vendor', 'business_tax_id')
  end

  test 'Postmark filters do not hide unrelated request diagnostics' do
    parameters = {
      'content_type' => 'application/json', 'description' => 'equipment category',
      'from_date' => '2026-09-01', 'subject_type' => 'Application', 'metadata_kind' => 'delivery'
    }

    assert_equal parameters, ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(parameters)
  end

  test 'authorization credentials remain filtered globally without matching unrelated keys' do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      'Authorization' => 'Basic private-credential', 'HTTP_AUTHORIZATION' => 'Bearer private-token',
      'authorization_method' => 'basic'
    )

    assert_equal '[FILTERED]', filtered['Authorization']
    assert_equal '[FILTERED]', filtered['HTTP_AUTHORIZATION']
    assert_equal 'basic', filtered['authorization_method']
  end

  test 'autosave logs retain the field and revision but redact its value and page id' do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      'field_name' => 'application[medical_provider_email]', 'field_value' => 'doctor@example.com',
      'autosave_context' => '0194504e-7920-4c00-b289-bd47348794b6', 'autosave_revision' => '7'
    )
    assert_equal '[FILTERED]', filtered['field_value']
    assert_equal '[FILTERED]', filtered['autosave_context']
    assert_equal 'application[medical_provider_email]', filtered['field_name']
    assert_equal '7', filtered['autosave_revision']
  end

  test 'filters contact and password parameters from logs' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      'contact' => '410-555-0198',
      'password' => 'password1234',
      'controller' => 'sessions',
      'action' => 'create'
    )

    assert_equal '[FILTERED]', filtered['contact']
    assert_equal '[FILTERED]', filtered['password']
    assert_equal 'sessions', filtered['controller']
    assert_equal 'create', filtered['action']
  end

  test 'evaluation free text is filtered in nested hashes and arrays without hiding ordinary fields' do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      'notes' => 'Private report context',
      'post_completion_notes' => 'Private supplemental context',
      'working_notes' => 'Private scheduling context',
      'reschedule_reason' => 'Private reason for postponing the appointment',
      'attendees_field' => ['Private attendee name'],
      'evaluation' => {
        'notes' => 'Private appointment findings',
        'post_completion_notes' => 'Private follow-up findings',
        'working_notes' => 'Private appointment context',
        'recommendation_notes' => 'Personal assessment rationale',
        'reschedule_reason' => 'Private family circumstances',
        'attendees_field' => 'Private interpreter and family names',
        'recommendation_outcome' => 'no_suitable_product',
        'location' => 'Main Office'
      },
      'evaluations' => [
        { 'notes' => 'Private report in an array',
          'post_completion_notes' => 'Private supplemental note in an array',
          'working_notes' => 'Private contact attempts in an array',
          'recommendation_notes' => 'Private rationale in an array',
          'reschedule_reason' => 'Private rescheduling reason in an array',
          'attendees_field' => ['Private support person in an array'],
          'id' => '17', 'status' => 'completed' }
      ],
      'controller' => 'evaluators/evaluations', 'action' => 'supplemental_notes'
    )

    assert_equal '[FILTERED]', filtered['notes']
    assert_equal '[FILTERED]', filtered['post_completion_notes']
    assert_equal '[FILTERED]', filtered['working_notes']
    assert_equal '[FILTERED]', filtered['reschedule_reason']
    assert_equal '[FILTERED]', filtered['attendees_field']
    %w[notes post_completion_notes working_notes recommendation_notes reschedule_reason attendees_field].each do |field|
      assert_equal '[FILTERED]', filtered.dig('evaluation', field)
      assert_equal '[FILTERED]', filtered['evaluations'].first[field]
    end
    assert_equal 'no_suitable_product', filtered.dig('evaluation', 'recommendation_outcome')
    assert_equal 'Main Office', filtered.dig('evaluation', 'location')
    assert_equal '17', filtered['evaluations'].first['id']
    assert_equal 'completed', filtered['evaluations'].first['status']
    assert_equal 'evaluators/evaluations', filtered['controller']
    assert_equal 'supplemental_notes', filtered['action']
  end

  test 'training text is redacted at top level and in nested hashes and arrays before request logs render' do
    private_text = 'TrainingPrivateLogSentinel7284'
    fields = %w[internal_notes constituent_summary cancellation_reason no_show_notes reschedule_reason]
    values = fields.index_with { |field| "#{private_text}:#{field}" }
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      values.merge('training_session' => values.merge('summary_locale' => 'es', 'duration_hours' => '1.5'),
                   'training_sessions' => [values.merge('id' => '7', 'status' => 'completed')],
                   'controller' => 'trainers/training_sessions', 'action' => 'complete')
    )

    fields.each do |field|
      assert_equal '[FILTERED]', filtered[field]
      assert_equal '[FILTERED]', filtered.dig('training_session', field)
      assert_equal '[FILTERED]', filtered['training_sessions'].first[field]
    end
    assert_equal 'es', filtered.dig('training_session', 'summary_locale')
    assert_equal '1.5', filtered.dig('training_session', 'duration_hours')
    assert_equal '7', filtered['training_sessions'].first['id']
    assert_equal 'completed', filtered['training_sessions'].first['status']
    assert_equal 'trainers/training_sessions', filtered['controller']
    assert_equal 'complete', filtered['action']
    assert_not_includes "Parameters: #{filtered.inspect}", private_text
  end

  test 'training stored free text does not appear in SQL bind debug logs' do
    session = create(:training_session)
    fields = %w[internal_notes constituent_summary cancellation_reason no_show_notes reschedule_reason]
    values = fields.index_with { |field| "TrainingSqlPrivateProbe:#{field}" }
    log = capture_active_record_log { session.update!(values) }

    assert_not_includes log, 'TrainingSqlPrivateProbe'
    fields.each do |field|
      assert_includes log, "[\"#{field}\", \"[FILTERED]\"]"
      assert_equal values.fetch(field), session.reload.public_send(field)
    end
  end

  test 'evaluation attendee names are filtered at their stored SQL attribute as well as the form field' do
    evaluation = create(:evaluation)

    log = capture_active_record_log do
      evaluation.update!(attendees_field: 'SqlAttendeeProbeName')
    end

    assert_no_match(/SqlAttendeeProbeName/, log)
    assert_match(/\["attendees", "\[FILTERED\]"\]/, log)
    assert_equal [{ 'name' => 'SqlAttendeeProbeName' }], evaluation.reload.attendees
  end

  # Paper identity review posts the applicant's identifying facts and receives a short-lived
  # decision token, which the form then submits back. POST keeps those out of the URL; this keeps
  # them out of the log. The names matter here specifically because they travel alongside a date of
  # birth and an address, and that combination is what identifies a person.
  test 'filters paper identity review facts and the decision token from logs' do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      'constituent' => {
        'first_name' => 'Jane', 'last_name' => 'Doe', 'date_of_birth' => '1990-04-02',
        'email' => 'jane@example.com', 'phone' => '555-000-0000',
        'physical_address_1' => '1 Main St', 'city' => 'Baltimore', 'zip_code' => '21201'
      },
      'identity_review_receipt' => "v1:#{Time.current.to_i}:#{'a' * 64}",
      'controller' => 'admin/paper_applications',
      'action' => 'identity_review'
    )

    %w[first_name last_name date_of_birth email phone physical_address_1 city zip_code].each do |field|
      assert_equal '[FILTERED]', filtered['constituent'][field], "#{field} must not reach the log"
    end
    assert_equal '[FILTERED]', filtered['identity_review_receipt'],
                 'the decision token authorizes a creation and must not outlive its request in a log'
    assert_equal 'identity_review', filtered['action']
  end

  # Filtering the request parameters is only half of it. The identity-matching query puts the same
  # names back on their way to the database, and `filter_parameters` matches on a bind's attribute
  # name -- so a positional bind, which Active Record logs as `[nil, "smith"]`, has no name to match
  # and lands in the query log in the clear. The date of birth was filtered the whole time only
  # because a hash condition carries its column name.
  #
  # Asserts the values are absent rather than that the binds are named: the requirement is that the
  # name does not reach the log, not that any particular construction is used to achieve it.
  test 'the duplicate-matching query does not write names to the query log' do
    log = capture_active_record_log do
      Users::Constituent.find_duplicates('SqlBindProbeFirst', 'SqlBindProbeLast', Date.new(1990, 4, 2)).to_a
    end

    assert_no_match(/sqlbindprobefirst/i, log, 'the first name reached the query log')
    assert_no_match(/sqlbindprobelast/i, log, 'the last name reached the query log')
    assert_match(/\["first_name", "\[FILTERED\]"\]/, log, 'the first name bind should be named and redacted')
    assert_match(/\["last_name", "\[FILTERED\]"\]/, log, 'the last name bind should be named and redacted')
  end

  # Redaction is worthless if it changed what the query matches, and this query decides whether two
  # people are the same person.
  test 'the duplicate-matching query still matches case-insensitively on name and date of birth' do
    existing = create(:constituent, first_name: 'Casing', last_name: 'Probe',
                                    date_of_birth: Date.new(1990, 4, 2))

    assert_includes Users::Constituent.find_duplicates('cAsInG', 'pRoBe', Date.new(1990, 4, 2)).map(&:id),
                    existing.id
    assert_not_includes Users::Constituent.find_duplicates('Casing', 'Probe', Date.new(1991, 4, 2)).map(&:id),
                        existing.id
  end

  test 'equipment identifiers and correction context are redacted from nested requests' do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      'equipment_item' => { 'imei' => '123456789012345', 'normalized_imei' => '123456789012345',
                            'serial_number' => 'DeviceSerial', 'tracking_number' => 'Package', 'carrier' => 'ups' },
      'reason' => 'Private correction context', 'serial_duplicate_reason' => 'Private acknowledgment',
      'impact_token' => 'Signed confirmation'
    )
    %w[imei normalized_imei serial_number tracking_number].each { |field| assert_equal '[FILTERED]', filtered.dig('equipment_item', field) }
    %w[reason serial_duplicate_reason impact_token].each { |field| assert_equal '[FILTERED]', filtered[field] }
    assert_equal 'ups', filtered.dig('equipment_item', 'carrier')
  end

  private

  def capture_active_record_log
    io = StringIO.new
    original = ActiveRecord::Base.logger
    ActiveRecord::Base.logger = ActiveSupport::Logger.new(io)
    ActiveRecord::Base.logger.level = :debug
    yield
    io.string
  ensure
    ActiveRecord::Base.logger = original
  end
end
