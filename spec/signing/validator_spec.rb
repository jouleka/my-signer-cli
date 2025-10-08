require 'spec_helper'
require 'mysigner/signing/validator'

RSpec.describe Mysigner::Signing::Validator do
  let(:build_settings) do
    {
      'DEVELOPMENT_TEAM' => 'ABC123XYZ',
      'CODE_SIGN_STYLE' => 'Automatic',
      'PRODUCT_BUNDLE_IDENTIFIER' => 'com.test.app'
    }
  end

  let(:parser) do
    instance_double(Mysigner::Build::Parser,
      team_id: build_settings['DEVELOPMENT_TEAM'],
      code_sign_style: build_settings['CODE_SIGN_STYLE'],
      bundle_id: build_settings['PRODUCT_BUNDLE_IDENTIFIER']
    )
  end

  let(:validator) { described_class.new(parser, 'TestApp', 'Release') }

  describe '#validate' do
    context 'with valid automatic signing setup' do
      it 'returns valid result' do
        result = validator.validate
        expect(result[:valid]).to be true
        expect(result[:errors]).to be_empty
      end
    end

    context 'with team override' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: nil,  # No team in project
          code_sign_style: 'Automatic',
          bundle_id: 'com.test.app'
        )
      end

      let(:validator) { described_class.new(parser, 'TestApp', 'Release', team_id: 'XYZ789') }

      it 'returns valid result with warning' do
        result = validator.validate
        expect(result[:valid]).to be true
        expect(result[:warnings]).to include(match(/Using team from My Signer: XYZ789/))
      end
    end

    context 'with no development team' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: nil,
          code_sign_style: 'Automatic',
          bundle_id: 'com.test.app'
        )
      end

      it 'returns error about missing team' do
        result = validator.validate
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(match(/No development team/))
        expect(result[:errors]).to include(match(/Add team to My Signer/))
        expect(result[:errors]).to include(match(/mysigner build --team/))
      end
    end

    context 'with empty development team' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: '',
          code_sign_style: 'Automatic',
          bundle_id: 'com.test.app'
        )
      end

      it 'returns error about missing team' do
        result = validator.validate
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(match(/No development team/))
        expect(result[:errors]).to include(match(/Add team to My Signer/))
        expect(result[:errors]).to include(match(/mysigner build --team/))
      end
    end

    context 'with missing bundle ID' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: 'ABC123XYZ',
          code_sign_style: 'Automatic',
          bundle_id: nil
        )
      end

      it 'returns error about bundle ID' do
        result = validator.validate
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(match(/Bundle ID not set/))
      end
    end

    context 'with bundle ID containing variables' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: 'ABC123XYZ',
          code_sign_style: 'Automatic',
          bundle_id: '$(PRODUCT_BUNDLE_ID)'
        )
      end

      it 'returns error about bundle ID variables' do
        result = validator.validate
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(match(/contains variables/))
      end
    end

    context 'with manual signing' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: 'ABC123XYZ',
          code_sign_style: 'Manual',
          bundle_id: 'com.test.app'
        )
      end

      before do
        # Mock security command for certificates check
        allow(validator).to receive(:`).with(/security find-identity/).and_return(
          "1) ABC123 \"iPhone Distribution: Test Company (ABC123)\"\n  1 valid identities found"
        )
      end

      it 'checks for certificates' do
        result = validator.validate
        expect(result[:warnings]).to include(match(/Found \d+ code signing certificate/))
      end
    end

    context 'with manual signing and no certificates' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: 'ABC123XYZ',
          code_sign_style: 'Manual',
          bundle_id: 'com.test.app'
        )
      end

      before do
        allow(validator).to receive(:`).with(/security find-identity/).and_return(
          "0 valid identities found"
        )
      end

      it 'returns error about missing certificates' do
        result = validator.validate
        expect(result[:valid]).to be false
        expect(result[:errors]).to include(match(/No code signing certificates/))
      end
    end
  end

  describe '#validate!' do
    context 'when validation passes' do
      it 'does not raise error' do
        expect { validator.validate! }.not_to raise_error
      end

      it 'prints success message' do
        expect { validator.validate! }.to output(/Pre-build validation passed/).to_stdout
      end
    end

    context 'when validation fails' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: nil,
          code_sign_style: 'Automatic',
          bundle_id: 'com.test.app'
        )
      end

      it 'raises ValidationError' do
        expect { validator.validate! }.to raise_error(Mysigner::Signing::Validator::ValidationError)
      end

      it 'prints error messages' do
        expect { 
          begin
            validator.validate!
          rescue Mysigner::Signing::Validator::ValidationError
            # Expected
          end
        }.to output(/No development team/).to_stdout
      end
    end

    context 'with warnings only' do
      let(:parser) do
        instance_double(Mysigner::Build::Parser,
          team_id: 'ABC123XYZ',
          code_sign_style: nil,  # Not set
          bundle_id: 'com.test.app'
        )
      end

      it 'does not raise error' do
        expect { validator.validate! }.not_to raise_error
      end

      it 'prints warning messages' do
        expect { validator.validate! }.to output(/Warnings:/).to_stdout
      end
    end
  end
end
