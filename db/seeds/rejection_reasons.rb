# frozen_string_literal: true

# Seeds EN rejection reason records from the authoritative strings in
# app/views/admin/applications/_modals.html.erb.
#
# address_mismatch body uses a %{address} placeholder so it can be
# interpolated with the applicant's actual address at send time.
# All other bodies are static.
def seed_rejection_reasons # rubocop:disable Metrics/MethodLength
  reasons = [
    # ── Income ────────────────────────────────────────────────────────────
    {
      code: 'address_mismatch',
      proof_type: 'income',
      en_body: 'The address provided on your income documentation does not match ' \
               'the application address. Please submit documentation that contains ' \
               'the address exactly matching the one shared in your application: %<address>s',
      es_body: 'La dirección proporcionada en su documentación de ingresos no coincide ' \
               'con la dirección de la solicitud. Por favor, envíe documentación que contenga ' \
               'la dirección que coincida exactamente con la compartida en su solicitud: %<address>s'
    },
    {
      code: 'expired',
      proof_type: 'income',
      en_body: 'The income documentation you provided is more than 1 year old or is ' \
               'expired. Please submit documentation that is less than 1 year old and ' \
               'which is not expired.',
      es_body: 'La documentación de ingresos que proporcionó tiene más de 1 año o está ' \
               'vencida. Por favor, envíe documentación que tenga menos de 1 año y ' \
               'que no esté vencida.'
    },
    {
      code: 'missing_name',
      proof_type: 'income',
      en_body: 'The income documentation you provided does not show your name. Please ' \
               'submit documentation that clearly displays your full name as it appears ' \
               'on your application.',
      es_body: 'La documentación de ingresos que proporcionó no muestra su nombre. Por favor, ' \
               'envíe documentación que muestre claramente su nombre completo tal como aparece ' \
               'en su solicitud.'
    },
    {
      code: 'wrong_document',
      proof_type: 'income',
      en_body: 'The document you submitted is not an acceptable type of income proof. ' \
               'Please submit one of the following: recent pay stubs, tax returns, ' \
               'Social Security benefit statements, or other official documentation ' \
               'that verifies your income.',
      es_body: 'El documento que envió no es un tipo aceptable de prueba de ingresos. ' \
               'Por favor, envíe uno de los siguientes: recibos de pago recientes, declaraciones de impuestos, ' \
               'estados de beneficios del Seguro Social u otra documentación oficial ' \
               'que verifique sus ingresos.'
    },
    {
      code: 'missing_amount',
      proof_type: 'income',
      en_body: 'The income documentation you provided does not clearly show your income ' \
               'amount. Please submit documentation that clearly displays your income ' \
               'figures, such as pay stubs with earnings clearly visible or benefit ' \
               'statements showing payment amounts.',
      es_body: 'La documentación de ingresos que proporcionó no muestra claramente su monto de ingresos. ' \
               'Por favor, envíe documentación que muestre claramente sus cifras de ingresos, ' \
               'como recibos de pago con ganancias claramente visibles o estados de beneficios ' \
               'que muestren los montos de pago.'
    },
    {
      code: 'exceeds_threshold',
      proof_type: 'income',
      en_body: 'Based on the income documentation you provided, your household income ' \
               'exceeds the maximum threshold to qualify for the MAT program. The program ' \
               'is designed to assist those with financial need, and unfortunately, your ' \
               'income level is above our current eligibility limits.',
      es_body: 'Según la documentación de ingresos que proporcionó, el ingreso de su hogar ' \
               'supera el umbral máximo para calificar para el programa MAT. El programa ' \
               'está diseñado para ayudar a aquellos con necesidades financieras y, lamentablemente, su ' \
               'nivel de ingresos está por encima de nuestros límites de elegibilidad actuales.'
    },
    {
      code: 'outdated_ss_award',
      proof_type: 'income',
      en_body: 'Your Social Security benefit award letter is out-of-date. Please submit ' \
               'your most recent award letter, which should be dated within the last 12 ' \
               'months. You can obtain a new benefit verification letter by visiting the ' \
               'Social Security Administration website or contacting your local SSA office.',
      es_body: 'Su carta de concesión de beneficios del Seguro Social está desactualizada. Por favor, envíe ' \
               'su carta de concesión más reciente, que debe estar fechada dentro de los últimos 12 ' \
               'meses. Puede obtener una nueva carta de verificación de beneficios visitando el ' \
               'sitio web de la Administración del Seguro Social o comunicándose con su oficina local de la SSA.'
    },
    {
      code: 'missing_signature',
      proof_type: 'income',
      en_body: 'The income documentation you provided is missing a required signature. ' \
               'Please submit documentation that is properly signed by the issuing authority.',
      es_body: 'A la documentación de ingresos que proporcionó le falta una firma requerida. ' \
               'Por favor, envíe documentación que esté debidamente firmada por la autoridad emisora.'
    },
    {
      code: 'illegible',
      proof_type: 'income',
      en_body: 'The income documentation you provided is illegible or unclear. Please ' \
               'submit a clear, readable copy of your documentation.',
      es_body: 'La documentación de ingresos que proporcionó es ilegible o poco clara. Por favor, ' \
               'envíe una copia clara y legible de su documentación.'
    },
    {
      code: 'incomplete_documentation',
      proof_type: 'income',
      en_body: 'The income documentation you provided is incomplete. Please submit ' \
               'documentation that includes all required information to verify your income.',
      es_body: 'La documentación de ingresos que proporcionó está incompleta. Por favor, envíe ' \
               'documentación que incluya toda la información requerida para verificar sus ingresos.'
    },

    # ── Residency ──────────────────────────────────────────────────────────
    {
      code: 'address_mismatch',
      proof_type: 'residency',
      en_body: 'The address provided on your residency documentation does not match ' \
               'the application address. Please submit documentation that contains ' \
               'the address exactly matching the one shared in your application: %<address>s',
      es_body: 'La dirección proporcionada en su documentación de residencia no coincide ' \
               'con la dirección de la solicitud. Por favor, envíe documentación que contenga ' \
               'la dirección que coincida exactamente con la compartida en su solicitud: %<address>s'
    },
    {
      code: 'expired',
      proof_type: 'residency',
      en_body: 'The residency documentation you provided is more than 1 year old or is ' \
               'expired. Please submit documentation that is less than 1 year old and ' \
               'which is not expired.',
      es_body: 'La documentación de residencia que proporcionó tiene más de 1 año o está ' \
               'vencida. Por favor, envíe documentación que tenga menos de 1 año y ' \
               'que no esté vencida.'
    },
    {
      code: 'missing_name',
      proof_type: 'residency',
      en_body: 'The residency documentation you provided does not show your name. Please ' \
               'submit documentation that clearly displays your full name as it appears ' \
               'on your application.',
      es_body: 'La documentación de residencia que proporcionó no muestra su nombre. Por favor, ' \
               'envíe documentación que muestre claramente su nombre completo tal como aparece ' \
               'en su solicitud.'
    },
    {
      code: 'wrong_document',
      proof_type: 'residency',
      en_body: 'The document you submitted is not an acceptable type of residency proof. ' \
               'Please submit one of the following: utility bill, lease agreement, mortgage ' \
               'statement, or other official documentation that verifies your Maryland residence.',
      es_body: 'El documento que envió no es un tipo aceptable de prueba de residencia. ' \
               'Por favor, envíe uno de los siguientes: factura de servicios públicos, contrato de arrendamiento, estado de cuenta hipotecario ' \
               'u otra documentación oficial que verifique su residencia en Maryland.'
    },
    {
      code: 'missing_signature',
      proof_type: 'residency',
      en_body: 'The residency documentation you provided is missing a required signature. ' \
               'Please submit documentation that is properly signed (e.g., a signed lease or ' \
               'utility bill from the provider).',
      es_body: 'A la documentación de residencia que proporcionó le falta una firma requerida. ' \
               'Por favor, envíe documentación que esté debidamente firmada (por ejemplo, un contrato ' \
               'de arrendamiento firmado o una factura de servicios públicos del proveedor).'
    },
    {
      code: 'illegible',
      proof_type: 'residency',
      en_body: 'The residency documentation you provided is illegible or unclear. Please ' \
               'submit a clear, readable copy of your documentation.',
      es_body: 'La documentación de residencia que proporcionó es ilegible o poco clara. Por favor, ' \
               'envíe una copia clara y legible de su documentación.'
    },
    {
      code: 'incomplete_documentation',
      proof_type: 'residency',
      en_body: 'The residency documentation you provided is incomplete. Please submit ' \
               'documentation that includes all required information to verify your Maryland residence.',
      es_body: 'La documentación de residencia que proporcionó está incompleta. Por favor, envíe ' \
               'documentación que incluya toda la información requerida para verificar su residencia en Maryland.'
    },

    # ── Medical Certification ──────────────────────────────────────────────
    {
      code: 'missing_provider_credentials',
      proof_type: 'medical_certification',
      en_body: 'The disability certification is missing required provider credentials or ' \
               'license number. Please ensure the resubmitted form includes the certifying ' \
               "professional's full credentials and license information.",
      es_body: 'A la certificación de discapacidad le faltan las credenciales requeridas del proveedor o ' \
               'el número de licencia. Por favor, asegúrese de que el formulario reenviado incluya las credenciales ' \
               'completas del profesional certificador y la información de la licencia.'
    },
    {
      code: 'incomplete_disability_documentation',
      proof_type: 'medical_certification',
      en_body: 'The documentation of the disability is incomplete. The certification must ' \
               'include a complete description of the disability and how it affects major ' \
               'life activities.',
      es_body: 'La documentación de la discapacidad está incompleta. La certificación debe ' \
               'incluir una descripción completa de la discapacidad y cómo afecta las principales ' \
               'actividades de la vida.'
    },
    {
      code: 'outdated_certification',
      proof_type: 'medical_certification',
      en_body: 'The disability certification is outdated. Please provide a certification ' \
               'that has been completed within the last 12 months.',
      es_body: 'La certificación de discapacidad está desactualizada. Por favor, proporcione una certificación ' \
               'que se haya completado en los últimos 12 meses.'
    },
    {
      code: 'missing_signature',
      proof_type: 'medical_certification',
      en_body: 'The disability certification is missing the required signature from the ' \
               'certifying professional. Please ensure the resubmitted form is properly ' \
               'signed and dated.',
      es_body: 'A la certificación de discapacidad le falta la firma requerida del ' \
               'profesional certificador. Por favor, asegúrese de que el formulario reenviado esté debidamente ' \
               'firmado y fechado.'
    },
    {
      code: 'missing_functional_limitations',
      proof_type: 'medical_certification',
      en_body: 'The disability certification lacks sufficient detail about functional ' \
               'limitations. Please ensure the resubmitted form includes specific ' \
               'information about how the disability affects daily activities.',
      es_body: 'La certificación de discapacidad carece de suficientes detalles sobre las limitaciones ' \
               'funcionales. Por favor, asegúrese de que el formulario reenviado incluya información ' \
               'específica sobre cómo la discapacidad afecta las actividades diarias.'
    },
    {
      code: 'incorrect_form_used',
      proof_type: 'medical_certification',
      en_body: 'The wrong certification form was used. Please ensure the certifying ' \
               'professional completes the official Disability Certification Form for ' \
               'MAT program eligibility.',
      es_body: 'Se usó el formulario de certificación incorrecto. Por favor, asegúrese de que el ' \
               'profesional certificador complete el Formulario de Certificación de Discapacidad oficial para ' \
               'la elegibilidad del programa MAT.'
    },
    {
      code: 'illegible',
      proof_type: 'medical_certification',
      en_body: 'The disability certification you provided is illegible or unclear. Please ' \
               'submit a clear, readable copy of the certification form.',
      es_body: 'La certificación de discapacidad que proporcionó es ilegible o poco clara. Por favor, ' \
               'envíe una copia clara y legible del formulario de certificación.'
    }
  ]

  reasons.each do |attrs|
    # Ensure EN reason exists
    RejectionReason.find_or_create_by!(
      code: attrs[:code],
      proof_type: attrs[:proof_type],
      locale: 'en'
    ) do |r|
      r.body = attrs[:en_body]
    end

    # Ensure ES reason exists
    RejectionReason.find_or_create_by!(
      code: attrs[:code],
      proof_type: attrs[:proof_type],
      locale: 'es'
    ) do |r|
      r.body = attrs[:es_body]
    end
  end

  Rails.logger.debug { "Seeded #{RejectionReason.count} rejection reason(s)." }
end
