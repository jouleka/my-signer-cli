# frozen_string_literal: true

RSpec.describe Mysigner do
  it 'has a version number' do
    expect(Mysigner::VERSION).not_to be nil
  end

  it 'loads required modules' do
    expect(defined?(Mysigner::Config)).to eq('constant')
    expect(defined?(Mysigner::Client)).to eq('constant')
  end
end
