# frozen_string_literal: true

require 'spec_helper'

# Guards the release-metadata parser: ordinary YAML/JSON still parses, but
# YAML anchors/aliases are rejected with a clean error rather than expanded
# (a YAML alias-bomb / billion-laughs DoS vector on a hostile project file).
RSpec.describe Mysigner::CLI do
  subject(:cli) { described_class.new([], {}, {}) }

  describe '#parse_metadata_content' do
    it 'parses ordinary YAML' do
      expect(cli.send(:parse_metadata_content, "---\nfoo: bar\n", 'meta.yml')).to eq('foo' => 'bar')
    end

    it 'parses ordinary JSON' do
      expect(cli.send(:parse_metadata_content, '{"a":1}', 'meta.json')).to eq('a' => 1)
    end

    it 'rejects YAML anchors/aliases with a clean error instead of expanding them' do
      aliased = "---\na: &x [1, 2, 3]\nb: *x\n"
      expect { cli.send(:parse_metadata_content, aliased, 'evil.yml') }
        .to raise_error(/Failed to parse metadata file/)
    end
  end
end
