# frozen_string_literal: true

require 'test_helper'

class PaperApplicantCandidateTest < ActiveSupport::TestCase
  test 'constituent is a paper applicant candidate' do
    user = create(:constituent, email: generate(:email))
    assert user.paper_applicant_candidate?
  end

  test 'admin without applicant history is not a candidate' do
    user = create(:admin, email: generate(:email))
    assert_not user.paper_applicant_candidate?
  end

  test 'non-constituent with prior application as subject user is not a candidate' do
    user = create(:evaluator, email: generate(:email), hearing_disability: true)
    assert_not user.paper_applicant_candidate?

    create(:application, :archived, user: user)
    assert_not user.reload.paper_applicant_candidate?
  end

  test 'legacy Constituent STI row is a paper applicant candidate' do
    user = create(:constituent, email: generate(:email))
    user.update_column(:type, 'Constituent')

    assert User.find(user.id).paper_applicant_candidate?
  end
end
