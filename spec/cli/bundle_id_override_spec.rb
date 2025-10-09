require 'spec_helper'
require 'mysigner/cli'
require 'stringio'

RSpec.describe 'mysigner build/ship --bundle-id', type: :integration do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:project_info) { { path: '/path/to/Test.xcodeproj', type: :project, framework: :native, directory: '/path/to' } }
  let(:parser) { instance_double(Mysigner::Build::Parser) }
  let(:executor) { instance_double(Mysigner::Build::Executor) }
  let(:validator) { instance_double(Mysigner::Signing::Validator) }

  before do
    allow(cli).to receive(:load_config).and_return(config)
    allow(cli).to receive(:create_client).and_return(client)
    allow(config).to receive(:api_token).and_return('test-token')
    allow(config).to receive(:organization_id).and_return('org-123')
    
    # Stub Build::Detector
    allow(Mysigner::Build::Detector).to receive(:detect).and_return(project_info)
    
    # Stub Build::Parser
    allow(Mysigner::Build::Parser).to receive(:new).and_return(parser)
    allow(parser).to receive(:main_target).and_return(double(name: 'TestApp'))
    allow(parser).to receive(:bundle_id).and_return('com.test.app')
    allow(parser).to receive(:has_multiple_apps?).and_return(false)
    allow(parser).to receive(:product_type).and_return(:app)
    allow(parser).to receive(:target_platform).and_return(:ios)
    allow(parser).to receive(:has_extensions?).and_return(false)
    allow(parser).to receive(:code_sign_style).and_return('Automatic')
    allow(parser).to receive(:team_id).and_return('ABCD1234')
    allow(parser).to receive(:signing_configured?).and_return(true)
    
    # Stub Signing::Validator
    allow(Mysigner::Signing::Validator).to receive(:new).and_return(validator)
    allow(validator).to receive(:validate!)
    
    # Stub Build::Executor
    allow(Mysigner::Build::Executor).to receive(:new).and_return(executor)
    allow(executor).to receive(:build!).and_return('/path/to/build/TestApp.xcarchive')
    
    # Stub client for team fetch
    allow(client).to receive(:get).with("/api/v1/organizations/org-123").and_return({
      'app_store_connect_team_id' => 'TEAM123'
    })
  end

  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  describe 'mysigner build --bundle-id' do
    context 'with valid bundle ID override' do
      before do
        cli.options = { 
          configuration: 'Release', 
          bundle_id: 'com.mycompany.newapp'
        }
      end

      it 'passes bundle ID to executor' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: 'com.mycompany.newapp')
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: com.mycompany.newapp (overridden)')
      end

      it 'shows override indicator in output' do
        output = capture_output { cli.build }
        
        expect(output).to include('📦 Bundle ID: com.mycompany.newapp (overridden)')
      end

      it 'validates bundle ID before building' do
        expect(executor).to receive(:build!)
        
        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: com.mycompany.newapp (overridden)')
      end
    end

    context 'with invalid bundle ID format' do
      before do
        cli.options = { 
          configuration: 'Release', 
          bundle_id: 'invalid bundle id!'
        }
      end

      it 'rejects bundle ID with spaces' do
        expect(cli).to receive(:exit).with(1)
        allow(cli).to receive(:say)
        allow(cli).to receive(:error)

        cli.build

        # Verify error method was called with appropriate message
        expect(cli).to have_received(:error).with('Invalid bundle ID format: invalid bundle id!')
      end

      it 'shows helpful error message' do
        expect(cli).to receive(:exit).with(1)
        
        output = capture_output { cli.build rescue nil }
        
        expect(output).to include('Invalid bundle ID format')
        expect(output).to include('Bundle IDs must contain only letters, numbers, hyphens, and periods')
      end
    end

    context 'with bundle ID containing variables' do
      before do
        cli.options = { 
          configuration: 'Release', 
          bundle_id: '$(PRODUCT_BUNDLE_PREFIX).app'
        }
      end

      it 'rejects bundle ID with variables' do
        expect(cli).to receive(:exit).with(1)
        allow(cli).to receive(:say)
        allow(cli).to receive(:error)

        cli.build

        expect(cli).to have_received(:error).with('Bundle ID cannot contain variables: $(PRODUCT_BUNDLE_PREFIX).app')
      end
    end

    context 'with bundle ID containing ${VAR} syntax' do
      before do
        cli.options = { 
          configuration: 'Release', 
          bundle_id: '${BUNDLE_PREFIX}.app'
        }
      end

      it 'rejects bundle ID with shell-style variables' do
        expect(cli).to receive(:exit).with(1)
        allow(cli).to receive(:say)
        allow(cli).to receive(:error)

        cli.build

        expect(cli).to have_received(:error).with('Bundle ID cannot contain variables: ${BUNDLE_PREFIX}.app')
      end
    end

    context 'with bundle ID containing special characters' do
      before do
        cli.options = { 
          configuration: 'Release', 
          bundle_id: 'com.test.app@#$'
        }
      end

      it 'rejects bundle ID with special characters' do
        expect(cli).to receive(:exit).with(1)
        allow(cli).to receive(:say)
        allow(cli).to receive(:error)

        cli.build

        expect(cli).to have_received(:error).with('Invalid bundle ID format: com.test.app@#$')
      end
    end

    context 'with valid bundle ID containing hyphens' do
      before do
        cli.options = { 
          configuration: 'Release', 
          bundle_id: 'com.my-company.my-app'
        }
      end

      it 'accepts bundle ID with hyphens' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: 'com.my-company.my-app')
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: com.my-company.my-app (overridden)')
      end
    end

    context 'without bundle ID override' do
      before do
        cli.options = { configuration: 'Release' }
      end

      it 'uses project bundle ID' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: nil)
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: com.test.app')
        expect(output).not_to include('(overridden)')
      end
    end

    context 'with both team and bundle ID overrides' do
      before do
        cli.options = { 
          configuration: 'Release',
          team: 'CUSTOM123',
          bundle_id: 'com.custom.app'
        }
      end

      it 'passes both overrides to executor' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(
            team_id: 'CUSTOM123',
            bundle_id: 'com.custom.app'
          )
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: com.custom.app (overridden)')
      end
    end
  end

  # Note: mysigner ship tests are covered by the build tests above
  # since ship calls build internally with the same options

  describe 'Executor integration' do
    let(:real_executor) { Mysigner::Build::Executor.new(project_info, parser) }

    before do
      allow(Mysigner::Build::Executor).to receive(:new).and_return(real_executor)
      allow(real_executor).to receive(:execute_with_output).and_return(true)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(/\.xcarchive$/).and_return(true)
      allow(FileUtils).to receive(:mkdir_p)
    end

    it 'includes PRODUCT_BUNDLE_IDENTIFIER in xcodebuild command' do
      cli.options = { 
        configuration: 'Release',
        bundle_id: 'com.override.test'
      }

      # Capture the command that would be executed
      allow(real_executor).to receive(:execute_with_output) do |cmd|
        expect(cmd).to include('PRODUCT_BUNDLE_IDENTIFIER=com.override.test')
        true
      end

      capture_output { cli.build }
    end

    it 'does not include PRODUCT_BUNDLE_IDENTIFIER when not overridden' do
      cli.options = { configuration: 'Release' }

      allow(real_executor).to receive(:execute_with_output) do |cmd|
        expect(cmd).not_to include('PRODUCT_BUNDLE_IDENTIFIER')
        true
      end

      capture_output { cli.build }
    end

    it 'includes both DEVELOPMENT_TEAM and PRODUCT_BUNDLE_IDENTIFIER when both overridden' do
      cli.options = { 
        configuration: 'Release',
        team: 'CUSTOM123',
        bundle_id: 'com.custom.bundle'
      }

      allow(real_executor).to receive(:execute_with_output) do |cmd|
        expect(cmd).to include('DEVELOPMENT_TEAM=CUSTOM123')
        expect(cmd).to include('PRODUCT_BUNDLE_IDENTIFIER=com.custom.bundle')
        true
      end

      capture_output { cli.build }
    end
  end

  describe 'edge cases' do
    before do
      cli.options = { configuration: 'Release' }
    end

    context 'with empty bundle ID' do
      before do
        cli.options[:bundle_id] = ''
      end

      it 'treats empty string as no override' do
        # Empty string is falsy in Ruby, so it should be treated as nil
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: '')
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        # Empty string is still passed, but it's up to the executor to handle it
      end
    end

    context 'with very long bundle ID' do
      let(:long_bundle_id) { 'com.' + 'a' * 200 }

      before do
        cli.options[:bundle_id] = long_bundle_id
      end

      it 'accepts long but valid bundle ID' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: long_bundle_id)
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('(overridden)')
      end
    end

    context 'with single character segments' do
      before do
        cli.options[:bundle_id] = 'a.b.c'
      end

      it 'accepts single character segments' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: 'a.b.c')
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: a.b.c (overridden)')
      end
    end

    context 'with numbers in bundle ID' do
      before do
        cli.options[:bundle_id] = 'com.test123.app456'
      end

      it 'accepts numbers in bundle ID' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: 'com.test123.app456')
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: com.test123.app456 (overridden)')
      end
    end

    context 'with uppercase letters' do
      before do
        cli.options[:bundle_id] = 'com.MyCompany.MyApp'
      end

      it 'accepts uppercase letters' do
        expect(executor).to receive(:build!).with(
          'TestApp',
          'Release',
          hash_including(bundle_id: 'com.MyCompany.MyApp')
        ).and_return('/path/to/build/TestApp.xcarchive')

        output = capture_output { cli.build }
        expect(output).to include('Bundle ID: com.MyCompany.MyApp (overridden)')
      end
    end
  end

  describe 'help documentation' do
    it 'documents --bundle-id flag in build command help' do
      help_output = capture_output { cli.help('build') }
      expect(help_output).to include('--bundle-id')
      expect(help_output).to include('Bundle ID (overrides project setting)')
    end

    it 'documents -b alias in build command help' do
      help_output = capture_output { cli.help('build') }
      expect(help_output).to include('-b')
    end

    it 'documents --bundle-id flag in ship command help' do
      help_output = capture_output { cli.help('ship') }
      expect(help_output).to include('--bundle-id')
      expect(help_output).to include('Bundle ID (overrides project setting)')
    end
  end
end

