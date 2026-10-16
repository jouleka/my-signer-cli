# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/build/error_analyzer'

RSpec.describe Mysigner::Build::ErrorAnalyzer do
  it 'extracts a missing capability without a backtracking regular expression' do
    analyzer = described_class.new([
                                     'Provisioning profile "Release" doesn\'t include the Push Notifications capability'
                                   ])

    expect(analyzer.issues).to include(
      type: :profile_capability,
      profile_name: 'Release',
      capability: 'Push Notifications'
    )
  end

  it 'bounds extremely large untrusted build output' do
    analyzer = described_class.new(["Provisioning profile \"Release\" #{'x' * 1_000_000}"])

    expect(analyzer.issues).to be_empty
  end
end
