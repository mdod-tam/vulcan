# frozen_string_literal: true

# Attaches real StringIO files for tests that need file content or real
# ActiveStorage behavior. Use AttachmentTestHelper#mock_attached_file when
# only the presence of an attachment matters.
module ActiveStorageTestHelper
  module_function

  # Attaches real StringIO objects as income and residency proofs to an application.
  #
  # @param application [Application] The application to attach proofs to
  # @param options [Hash] Options to customize the attachment
  # @option options [String] :income_content ("income proof content") Content for the income proof
  # @option options [String] :residency_content ("residency proof content") Content for the residency proof
  # @option options [Boolean] :with_medical_certification (false) Whether to also attach a medical certification
  #
  # @deprecated Do not use thread-local state (:skip_proof_validation).
  #   Use factories instead:
  #   `create(:application, :with_income_proof, :with_residency_proof)`
  def attach_test_proofs_to_application(application, options = {})
    options = {
      income_content: 'income proof content',
      residency_content: 'residency proof content',
      with_medical_certification: false
    }.merge(options)

    # TODO: Refactor to avoid using thread-local validation skipping.
    original_value = Thread.current[:skip_proof_validation]
    Thread.current[:skip_proof_validation] = true

    application.income_proof.attach(
      io: StringIO.new(options[:income_content]),
      filename: 'income.pdf',
      content_type: 'application/pdf'
    )

    application.residency_proof.attach(
      io: StringIO.new(options[:residency_content]),
      filename: 'residency.pdf',
      content_type: 'application/pdf'
    )

    if options[:with_medical_certification]
      application.medical_certification.attach(
        io: StringIO.new('medical certification content'),
        filename: 'medical_certification.pdf',
        content_type: 'application/pdf'
      )
    end
  ensure
    Thread.current[:skip_proof_validation] = original_value
  end

  # Attaches a real income proof to an application.
  #
  # @param application [Application] The application to attach the proof to
  # @param content [String] Optional content for the proof file
  def attach_income_proof(application, content = 'income proof content')
    application.income_proof.attach(
      io: StringIO.new(content),
      filename: 'income.pdf',
      content_type: 'application/pdf'
    )
  end

  # Attaches a real residency proof to an application.
  #
  # @param application [Application] The application to attach the proof to
  # @param content [String] Optional content for the proof file
  def attach_residency_proof(application, content = 'residency proof content')
    application.residency_proof.attach(
      io: StringIO.new(content),
      filename: 'residency.pdf',
      content_type: 'application/pdf'
    )
  end

  # Attaches a real medical certification to an application.
  #
  # @param application [Application] The application to attach the certification to
  # @param content [String] Optional content for the certification file
  def attach_medical_certification(application, content = 'medical certification content')
    application.medical_certification.attach(
      io: StringIO.new(content),
      filename: 'medical_certification.pdf',
      content_type: 'application/pdf'
    )
  end
end
