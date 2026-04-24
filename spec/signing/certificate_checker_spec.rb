# frozen_string_literal: true

require 'spec_helper'
require 'mysigner/signing/certificate_checker'
require 'tempfile'

RSpec.describe Mysigner::Signing::CertificateChecker do
  let(:checker) { described_class.new }

  describe '#check!' do
    context 'with valid certificates' do
      let(:security_output) do
        <<~OUTPUT
          1) ABC123 "Apple Development: John Doe (ABCD123456)"
          2) DEF456 "Apple Distribution: John Doe (ABCD123456)"
             2 valid identities found
        OUTPUT
      end

      let(:cert1_pem) do
        <<~PEM
          -----BEGIN CERTIFICATE-----
          MIIFakeDataHere==
          -----END CERTIFICATE-----
        PEM
      end

      let(:future_year) { Date.today.year + 2 }
      let(:past_year) { Date.today.year - 2 }
      let(:openssl_output1) { "notAfter=Dec 31 23:59:59 #{future_year} GMT" }
      let(:openssl_output2) { "notAfter=Jun 15 23:59:59 #{past_year} GMT" }

      before do
        # Stub security find-identity
        allow(Open3).to receive(:capture3).with('security find-identity -v -p codesigning')
                                          .and_return([security_output, '', double(success?: true)])

        # Stub security find-certificate for cert 1
        allow(Open3).to receive(:capture3).with('security find-certificate -c "Apple Development: John Doe (ABCD123456)" -p')
                                          .and_return([cert1_pem, '', double(success?: true)])

        # Stub security find-certificate for cert 2
        allow(Open3).to receive(:capture3).with('security find-certificate -c "Apple Distribution: John Doe (ABCD123456)" -p')
                                          .and_return([cert1_pem, '', double(success?: true)])

        # Stub openssl for both certs
        allow(Open3).to receive(:capture3).with(/openssl x509/)
                                          .and_return([openssl_output1, '',
                                                       double(success?: true)], [openssl_output2, '', double(success?: true)])

        # Stub Tempfile
        tempfile1 = double('tempfile1', write: nil, close: nil, path: '/tmp/cert1.pem', unlink: nil)
        tempfile2 = double('tempfile2', write: nil, close: nil, path: '/tmp/cert2.pem', unlink: nil)
        allow(Tempfile).to receive(:new).and_return(tempfile1, tempfile2)
      end

      it 'finds all certificates' do
        certs = checker.check!
        expect(certs.count).to eq(2)
      end

      it 'parses certificate names' do
        certs = checker.check!
        expect(certs[0][:name]).to eq('Apple Development: John Doe (ABCD123456)')
        expect(certs[1][:name]).to eq('Apple Distribution: John Doe (ABCD123456)')
      end

      it 'extracts team IDs' do
        certs = checker.check!
        expect(certs[0][:team_id]).to eq('ABCD123456')
        expect(certs[1][:team_id]).to eq('ABCD123456')
      end

      it 'determines certificate types' do
        certs = checker.check!
        expect(certs[0][:type]).to eq('Development')
        expect(certs[1][:type]).to eq('Distribution')
      end

      it 'calculates days until expiry' do
        certs = checker.check!
        expect(certs[0][:days_until_expiry]).to be > 0
      end

      it 'determines status based on expiry' do
        certs = checker.check!
        # First cert expires in the future (valid)
        expect(certs[0][:status]).to eq(:valid)
      end
    end

    context 'with expiring soon certificate' do
      let(:security_output) do
        '1) ABC123 "Apple Development: Test (TEAM123)"'
      end

      before do
        allow(Open3).to receive(:capture3).with('security find-identity -v -p codesigning')
                                          .and_return([security_output, '', double(success?: true)])

        allow(Open3).to receive(:capture3).with('security find-certificate -c "Apple Development: Test (TEAM123)" -p')
                                          .and_return(["-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----", '',
                                                       double(success?: true)])

        # Certificate expiring in 15 days
        future_date = (Time.now + (15 * 86_400)).strftime('%b %d %H:%M:%S %Y GMT')
        allow(Open3).to receive(:capture3).with(/openssl x509/)
                                          .and_return(["notAfter=#{future_date}", '', double(success?: true)])

        tempfile = double('tempfile', write: nil, close: nil, path: '/tmp/cert.pem', unlink: nil)
        allow(Tempfile).to receive(:new).and_return(tempfile)
      end

      it 'marks certificate as expiring soon' do
        certs = checker.check!
        expect(certs[0][:status]).to eq(:expiring_soon)
      end

      it 'calculates correct days until expiry' do
        certs = checker.check!
        expect(certs[0][:days_until_expiry]).to be_between(14, 16)
      end
    end

    context 'with expired certificate' do
      let(:security_output) do
        '1) ABC123 "Apple Development: Expired (TEAM123)"'
      end

      before do
        allow(Open3).to receive(:capture3).with('security find-identity -v -p codesigning')
                                          .and_return([security_output, '', double(success?: true)])

        allow(Open3).to receive(:capture3).with('security find-certificate -c "Apple Development: Expired (TEAM123)" -p')
                                          .and_return(["-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----", '',
                                                       double(success?: true)])

        # Certificate expired 30 days ago
        past_date = (Time.now - (30 * 86_400)).strftime('%b %d %H:%M:%S %Y GMT')
        allow(Open3).to receive(:capture3).with(/openssl x509/)
                                          .and_return(["notAfter=#{past_date}", '', double(success?: true)])

        tempfile = double('tempfile', write: nil, close: nil, path: '/tmp/cert.pem', unlink: nil)
        allow(Tempfile).to receive(:new).and_return(tempfile)
      end

      it 'marks certificate as expired' do
        certs = checker.check!
        expect(certs[0][:status]).to eq(:expired)
      end

      it 'calculates negative days until expiry' do
        certs = checker.check!
        expect(certs[0][:days_until_expiry]).to be < 0
      end
    end

    context 'with no certificates' do
      before do
        allow(Open3).to receive(:capture3).with('security find-identity -v -p codesigning')
                                          .and_return(['0 valid identities found', '', double(success?: true)])
      end

      it 'returns empty array' do
        certs = checker.check!
        expect(certs).to be_empty
      end
    end

    context 'when security command fails' do
      before do
        allow(Open3).to receive(:capture3).with('security find-identity -v -p codesigning')
                                          .and_return(['', 'Error: unable to access keychain', double(success?: false)])
      end

      it 'raises CheckError' do
        expect do
          checker.check!
        end.to raise_error(Mysigner::Signing::CertificateChecker::CheckError, /Failed to query certificates/)
      end
    end

    context 'when certificate details cannot be fetched' do
      let(:security_output) do
        '1) ABC123 "Apple Development: Test (TEAM123)"'
      end

      before do
        allow(Open3).to receive(:capture3).with('security find-identity -v -p codesigning')
                                          .and_return([security_output, '', double(success?: true)])

        # Certificate not found
        allow(Open3).to receive(:capture3).with('security find-certificate -c "Apple Development: Test (TEAM123)" -p')
                                          .and_return(['', 'Not found', double(success?: false)])
      end

      it 'skips certificate with missing details' do
        certs = checker.check!
        expect(certs).to be_empty
      end
    end
  end

  describe '#by_status' do
    before do
      checker.instance_variable_set(:@certificates, [
                                      { name: 'Cert 1', status: :valid },
                                      { name: 'Cert 2', status: :valid },
                                      { name: 'Cert 3', status: :expiring_soon },
                                      { name: 'Cert 4', status: :expired }
                                    ])
    end

    it 'groups certificates by status' do
      by_status = checker.by_status

      expect(by_status[:valid].count).to eq(2)
      expect(by_status[:expiring_soon].count).to eq(1)
      expect(by_status[:expired].count).to eq(1)
    end
  end

  describe '#has_issues?' do
    context 'with all valid certificates' do
      before do
        checker.instance_variable_set(:@certificates, [
                                        { name: 'Cert 1', status: :valid },
                                        { name: 'Cert 2', status: :valid }
                                      ])
      end

      it 'returns false' do
        expect(checker.has_issues?).to be false
      end
    end

    context 'with expiring soon certificate' do
      before do
        checker.instance_variable_set(:@certificates, [
                                        { name: 'Cert 1', status: :valid },
                                        { name: 'Cert 2', status: :expiring_soon }
                                      ])
      end

      it 'returns true' do
        expect(checker.has_issues?).to be true
      end
    end

    context 'with expired certificate' do
      before do
        checker.instance_variable_set(:@certificates, [
                                        { name: 'Cert 1', status: :valid },
                                        { name: 'Cert 2', status: :expired }
                                      ])
      end

      it 'returns true' do
        expect(checker.has_issues?).to be true
      end
    end
  end

  describe 'certificate type detection' do
    it 'detects development certificates' do
      expect(checker.send(:determine_cert_type, 'Apple Development: John Doe')).to eq('Development')
    end

    it 'detects distribution certificates' do
      expect(checker.send(:determine_cert_type, 'Apple Distribution: Company')).to eq('Distribution')
    end

    it 'detects Developer ID certificates' do
      expect(checker.send(:determine_cert_type, 'Developer ID Application: Company')).to eq('Developer ID')
    end

    it 'returns Unknown for unrecognized types' do
      expect(checker.send(:determine_cert_type, 'Random Certificate')).to eq('Unknown')
    end
  end

  describe 'team ID extraction' do
    it 'extracts team ID from certificate name' do
      expect(checker.send(:extract_team_id, 'Apple Development: John Doe (ABCD123456)')).to eq('ABCD123456')
    end

    it 'returns nil for certificates without team ID' do
      expect(checker.send(:extract_team_id, 'Apple Development: John Doe')).to be_nil
    end
  end

  describe 'status determination' do
    it 'returns valid for certificates expiring in more than 30 days' do
      expect(checker.send(:determine_status, 90)).to eq(:valid)
    end

    it 'returns expiring_soon for certificates expiring in less than 30 days' do
      expect(checker.send(:determine_status, 15)).to eq(:expiring_soon)
      expect(checker.send(:determine_status, 1)).to eq(:expiring_soon)
    end

    it 'returns expired for already expired certificates' do
      expect(checker.send(:determine_status, -1)).to eq(:expired)
      expect(checker.send(:determine_status, -30)).to eq(:expired)
    end
  end
end
