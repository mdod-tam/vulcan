# Evaluation confirmation templates: v1.0 release review

Before rollout, staff must review customized English and Spanish text bodies for `evaluator_mailer_evaluation_submission_confirmation` in **Admin → Email Templates**.

The outcome-copy migration updates only bodies that exactly match the previous stock text, for the `en` and `es` text variants. Customized bodies and other formats remain unchanged. It preserves custom wording instead of replacing it with the new stock copy; this does not mean that wording is suitable for the new outcomes.

Review both locale panels and save EN and ES independently:

1. Keep the required **Recommended Products Text List** variable. Its Standard placeholder is `%<recommended_products_text_list>s`; the editor's Insert Variable control supplies the correct placeholder for the selected style. The value now carries catalog recommendations, an outside-catalog recommendation, or a no-suitable-product outcome, together with the evaluator's Recommendation details.
2. Replace introductions that assume a product was recommended with neutral wording, such as “The evaluation outcome and any product recommendations are:” / “El resultado de la evaluación y las recomendaciones de productos, si las hay, son:”. Remove any wording that promises equipment delivery for every outcome.
3. Use **Preview Draft** to check template syntax and the surrounding custom prose. Before rollout, have deployment QA render the saved customized template with catalog, outside-catalog and no-suitable-product reports in both languages, including a recommendation and an explanation in Recommendation details. The editor's catalog sample can't tell you whether the other outcomes read well.

Recommendation details are applicant-facing: they are included verbatim in the confirmation email or letter for the applicant or managing guardian. Evaluators should put internal contact, preparation and follow-up information in **Working Notes**, which are excluded from those confirmations. The evaluator forms and this template's editor help explain this boundary.

Do not reseed templates to complete this review: the template seeds update existing bodies and can overwrite staff customization. Use the admin editor to retain the required variables and approved local wording.
