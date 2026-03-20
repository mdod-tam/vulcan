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

  test 'evaluator with prior application as subject user is a candidate' do
    user = create(:evaluator, email: generate(:email), hearing_disability: true)
    assert_not user.paper_applicant_candidate?

    create(:application, :archived, user: user)
    assert user.reload.paper_applicant_candidate?
  end
end
