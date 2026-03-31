# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/cli'
require 'mysigner/signing/certificate_checker'
require 'stringio'

RSpec.describe 'mysigner certificate check', type: :integration do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:checker) { instance_double(Mysigner::Signing::CertificateChecker) }

  before do
    allow(cli).to receive(:load_config).and_return(config)
    allow(cli).to receive(:create_client).and_return(client)
    allow(config).to receive(:api_token).and_return('test-token')
    allow(config).to receive(:organization_id).and_return('org-123')

    # Stub CertificateChecker
    allow(Mysigner::Signing::CertificateChecker).to receive(:new).and_return(checker)
  end

  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  describe 'with valid certificates' do
    let(:valid_certs) do
      [
        {
          name: 'Apple Development: John Doe (TEAM123)',
          hash: 'ABC123',
          team_id: 'TEAM123',
          type: 'Development',
          expires_at: Time.parse('2025-12-31'),
          days_until_expiry: 400,
          status: :valid
        },
        {
          name: 'Apple Distribution: Company Inc (TEAM123)',
          hash: 'DEF456',
          team_id: 'TEAM123',
          type: 'Distribution',
          expires_at: Time.parse('2026-06-30'),
          days_until_expiry: 600,
          status: :valid
        }
      ]
    end

    before do
      allow(checker).to receive(:check!).and_return(valid_certs)
      allow(checker).to receive(:by_status).and_return({
                                                         valid: valid_certs,
                                                         expiring_soon: [],
                                                         expired: []
                                                       })
      allow(checker).to receive(:has_issues?).and_return(false)
    end

    it 'shows valid certificates' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('✓ Valid Certificates (2)')
      expect(output).to include('Apple Development: John Doe (TEAM123)')
      expect(output).to include('Apple Distribution: Company Inc (TEAM123)')
    end

    it 'displays certificate details' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Type: Development')
      expect(output).to include('Type: Distribution')
      expect(output).to include('Team: TEAM123')
      expect(output).to include('Expires: 2025-12-31')
      expect(output).to include('400 days')
    end

    it 'shows success status' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Total: 2 certificates')
      expect(output).to include('Status: ✓ All certificates valid')
    end

    it 'does not show warnings or errors' do
      output = capture_output { cli.certificate('check') }

      expect(output).not_to include('Expiring Soon')
      expect(output).not_to include('Expired')
    end
  end

  describe 'with expiring soon certificates' do
    let(:expiring_certs) do
      [
        {
          name: 'Apple Development: Test (TEAM123)',
          hash: 'ABC123',
          team_id: 'TEAM123',
          type: 'Development',
          expires_at: Time.parse('2024-11-15'),
          days_until_expiry: 15,
          status: :expiring_soon
        }
      ]
    end

    before do
      allow(checker).to receive(:check!).and_return(expiring_certs)
      allow(checker).to receive(:by_status).and_return({
                                                         valid: [],
                                                         expiring_soon: expiring_certs,
                                                         expired: []
                                                       })
      allow(checker).to receive(:has_issues?).and_return(true)
    end

    it 'shows expiring soon warning' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('⚠️  Expiring Soon (1)')
      expect(output).to include('Apple Development: Test (TEAM123)')
    end

    it 'displays expiry warning message' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Renew these certificates soon to avoid build failures!')
    end

    it 'shows action required status' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Status: ⚠️  Action required')
    end
  end

  describe 'with expired certificates' do
    let(:expired_certs) do
      [
        {
          name: 'Apple Distribution: Expired (TEAM123)',
          hash: 'ABC123',
          team_id: 'TEAM123',
          type: 'Distribution',
          expires_at: Time.parse('2023-01-01'),
          days_until_expiry: -300,
          status: :expired
        }
      ]
    end

    before do
      allow(checker).to receive(:check!).and_return(expired_certs)
      allow(checker).to receive(:by_status).and_return({
                                                         valid: [],
                                                         expiring_soon: [],
                                                         expired: expired_certs
                                                       })
      allow(checker).to receive(:has_issues?).and_return(true)
    end

    it 'shows expired certificates' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('✗ Expired Certificates (1)')
      expect(output).to include('Apple Distribution: Expired (TEAM123)')
    end

    it 'displays days since expiry' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('300 days ago')
    end

    it 'provides renewal link' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('These certificates will cause build failures')
      expect(output).to include('https://developer.apple.com/account/resources/certificates/list')
    end

    it 'shows action required status' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Status: ⚠️  Action required')
    end
  end

  describe 'with mixed certificate statuses' do
    let(:mixed_certs) do
      [
        {
          name: 'Valid Cert',
          hash: 'ABC',
          team_id: 'TEAM123',
          type: 'Development',
          expires_at: Time.parse('2025-12-31'),
          days_until_expiry: 400,
          status: :valid
        },
        {
          name: 'Expiring Cert',
          hash: 'DEF',
          team_id: 'TEAM123',
          type: 'Distribution',
          expires_at: Time.parse('2024-11-15'),
          days_until_expiry: 15,
          status: :expiring_soon
        },
        {
          name: 'Expired Cert',
          hash: 'GHI',
          team_id: 'TEAM123',
          type: 'Development',
          expires_at: Time.parse('2023-01-01'),
          days_until_expiry: -300,
          status: :expired
        }
      ]
    end

    before do
      allow(checker).to receive(:check!).and_return(mixed_certs)
      allow(checker).to receive(:by_status).and_return({
                                                         valid: [mixed_certs[0]],
                                                         expiring_soon: [mixed_certs[1]],
                                                         expired: [mixed_certs[2]]
                                                       })
      allow(checker).to receive(:has_issues?).and_return(true)
    end

    it 'shows all certificate sections' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('✓ Valid Certificates (1)')
      expect(output).to include('⚠️  Expiring Soon (1)')
      expect(output).to include('✗ Expired Certificates (1)')
    end

    it 'displays correct total count' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Total: 3 certificates')
    end

    it 'shows action required status' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Status: ⚠️  Action required')
    end
  end

  describe 'with no certificates' do
    before do
      allow(checker).to receive(:check!).and_return([])
    end

    it 'shows no certificates message' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('No code signing certificates found in local Keychain')
    end

    it 'provides installation instructions' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('⚠️  Important:')
      expect(output).to include('This command checks certificates INSTALLED ON YOUR MAC')
      expect(output).to include('Certificates in My Signer API are not automatically installed locally')
      expect(output).to include('mysigner certificates')
      expect(output).to include('mysigner certificate download')
      expect(output).to include('Double-click the .cer file to install in Keychain')
    end

    it 'does not show certificate sections' do
      output = capture_output { cli.certificate('check') }

      expect(output).not_to include('Valid Certificates')
      expect(output).not_to include('Total:')
    end
  end

  describe 'when check fails' do
    before do
      allow(checker).to receive(:check!).and_raise(
        Mysigner::Signing::CertificateChecker::CheckError.new('Keychain is locked')
      )
      allow(cli).to receive(:exit)
    end

    it 'shows error message' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Certificate check failed: Keychain is locked')
    end

    it 'provides troubleshooting guidance' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('This usually means:')
      expect(output).to include('Keychain is locked')
      expect(output).to include('No certificates installed')
      expect(output).to include('Security command not available')
    end

    it 'exits with error code' do
      expect(cli).to receive(:exit).with(1)
      capture_output { cli.certificate('check') }
    end
  end

  describe 'certificate without team ID' do
    let(:cert_no_team) do
      [
        {
          name: 'Developer ID Application: Company',
          hash: 'ABC123',
          team_id: nil,
          type: 'Developer ID',
          expires_at: Time.parse('2025-12-31'),
          days_until_expiry: 400,
          status: :valid
        }
      ]
    end

    before do
      allow(checker).to receive(:check!).and_return(cert_no_team)
      allow(checker).to receive(:by_status).and_return({
                                                         valid: cert_no_team,
                                                         expiring_soon: [],
                                                         expired: []
                                                       })
      allow(checker).to receive(:has_issues?).and_return(false)
    end

    it 'shows Unknown for missing team ID' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Team: Unknown')
    end
  end

  describe 'help documentation' do
    it 'documents check action in certificate command help' do
      help_output = capture_output { cli.help('certificate') }

      expect(help_output).to include('check')
      expect(help_output).to include('Check certificates installed in your Mac\'s Keychain')
      expect(help_output).to include('scans your LOCAL Keychain')
    end

    it 'documents download action in certificate command help' do
      help_output = capture_output { cli.help('certificate') }

      expect(help_output).to include('download')
    end
  end

  describe 'command execution' do
    let(:valid_certs) do
      [
        {
          name: 'Test Cert',
          hash: 'ABC',
          team_id: 'TEAM123',
          type: 'Development',
          expires_at: Time.parse('2025-12-31'),
          days_until_expiry: 400,
          status: :valid
        }
      ]
    end

    before do
      allow(checker).to receive(:check!).and_return(valid_certs)
      allow(checker).to receive(:by_status).and_return({
                                                         valid: valid_certs,
                                                         expiring_soon: [],
                                                         expired: []
                                                       })
      allow(checker).to receive(:has_issues?).and_return(false)
    end

    it 'calls checker check! method' do
      expect(checker).to receive(:check!)

      capture_output { cli.certificate('check') }
    end

    it 'calls checker by_status method' do
      expect(checker).to receive(:by_status)

      capture_output { cli.certificate('check') }
    end

    it 'calls checker has_issues? method' do
      expect(checker).to receive(:has_issues?)

      capture_output { cli.certificate('check') }
    end
  end

  describe 'output formatting' do
    let(:certs) do
      [
        {
          name: 'Apple Development: Test (TEAM123)',
          hash: 'ABC',
          team_id: 'TEAM123',
          type: 'Development',
          expires_at: Time.parse('2025-12-31 23:59:59'),
          days_until_expiry: 400,
          status: :valid
        }
      ]
    end

    before do
      allow(checker).to receive(:check!).and_return(certs)
      allow(checker).to receive(:by_status).and_return({
                                                         valid: certs,
                                                         expiring_soon: [],
                                                         expired: []
                                                       })
      allow(checker).to receive(:has_issues?).and_return(false)
    end

    it 'formats expiry date correctly' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Expires: 2025-12-31')
    end

    it 'includes separator line' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('─' * 80)
    end

    it 'shows certificate count in summary' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('Total: 1 certificate installed locally')
    end

    it 'shows tip about API certificates' do
      output = capture_output { cli.certificate('check') }

      expect(output).to include('💡 Tip: These are certificates INSTALLED ON YOUR MAC')
      expect(output).to include('To see all certificates in My Signer API, run: mysigner certificates')
    end
  end
end
