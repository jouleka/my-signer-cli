# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe 'mysigner tracks', type: :cli do
  let(:cli) { Mysigner::CLI.new }
  let(:config) { instance_double(Mysigner::Config) }
  let(:client) { instance_double(Mysigner::Client) }
  let(:api_url) { 'https://mysigner.dev' }
  let(:api_token) { 'sk_test_abc123xyz' }
  let(:org_id) { '123' }
  let(:package_name) { 'com.example.myapp' }

  def capture_stdout
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  before do
    allow(Mysigner::Config).to receive(:new).and_return(config)
    allow(Mysigner::Client).to receive(:new).and_return(client)
    allow(cli).to receive(:exit)
    cli.options = {}
  end

  describe 'when not logged in' do
    before do
      allow(config).to receive(:exists?).and_return(false)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(nil)
      allow(config).to receive(:api_token).and_return(nil)
      allow(config).to receive(:organization_id).and_return('123')
      allow(config).to receive(:current_organization_id).and_return('123')
      allow(config).to receive(:user_email).and_return(nil)
      allow(client).to receive(:get).and_return({ data: { 'tracks' => [] } })
    end

    it 'shows error message' do
      output = capture_stdout { cli.tracks(package_name) }
      expect(output).to include('Not logged in')
    end

    it 'suggests login command' do
      output = capture_stdout { cli.tracks(package_name) }
      expect(output).to include('mysigner login')
    end

    it 'exits with code 1' do
      expect(cli).to receive(:exit).with(1)
      cli.tracks(package_name)
    end
  end

  describe 'when logged in' do
    before do
      allow(config).to receive(:exists?).and_return(true)
      allow(config).to receive(:load)
      allow(config).to receive(:api_url).and_return(api_url)
      allow(config).to receive(:api_token).and_return(api_token)
      allow(config).to receive(:organization_id).and_return(org_id)
      allow(config).to receive(:current_organization_id).and_return(org_id)
      allow(config).to receive(:user_email).and_return('test@example.com')
    end

    describe 'tracks command' do
      describe 'when package_name is missing' do
        it 'shows usage error' do
          output = capture_stdout { cli.tracks }
          expect(output).to include('Usage: mysigner tracks PACKAGE_NAME')
        end

        it 'shows example' do
          output = capture_stdout { cli.tracks }
          expect(output).to include('mysigner tracks com.example.myapp')
        end

        it 'shows tip about listing apps' do
          output = capture_stdout { cli.tracks }
          expect(output).to include('mysigner apps --platform android')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.tracks
        end
      end

      describe 'when no tracks found' do
        let(:empty_response) do
          {
            data: {
              'package_name' => package_name,
              'tracks' => []
            }
          }
        end

        before do
          allow(client).to receive(:get).and_return(empty_response)
        end

        it 'shows header' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Google Play Tracks')
          expect(output).to include(package_name)
        end

        it 'shows no tracks message' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('No tracks found')
        end

        it 'shows sync suggestion' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('mysigner sync android')
        end

        it 'does not exit with error' do
          expect(cli).not_to receive(:exit)
          cli.tracks(package_name)
        end
      end

      describe 'list tracks with data' do
        let(:tracks_response) do
          {
            data: {
              'package_name' => package_name,
              'tracks' => [
                {
                  'id' => 1,
                  'track_name' => 'production',
                  'status' => 'completed',
                  'releases' => [
                    {
                      'status' => 'completed',
                      'versionCodes' => %w[100 101]
                    }
                  ],
                  'updated_at' => '2024-01-15T10:30:00Z'
                },
                {
                  'id' => 2,
                  'track_name' => 'beta',
                  'status' => 'inProgress',
                  'releases' => [
                    {
                      'status' => 'draft',
                      'versionCodes' => ['102']
                    }
                  ],
                  'updated_at' => '2024-01-14T08:00:00Z'
                }
              ]
            }
          }
        end

        before do
          allow(client).to receive(:get).and_return(tracks_response)
        end

        it 'shows header with package name' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Google Play Tracks')
          expect(output).to include(package_name)
        end

        it 'fetches tracks from API' do
          expect(client).to receive(:get).with(
            "/api/v1/organizations/#{org_id}/android_apps/package/#{package_name}/tracks"
          )
          cli.tracks(package_name)
        end

        it 'shows track names' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('production')
          expect(output).to include('beta')
        end

        it 'shows track status' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Status: completed')
          expect(output).to include('Status: inProgress')
        end

        it 'shows version codes' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('100, 101')
          expect(output).to include('102')
        end

        it 'shows release status' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Release status: completed')
          expect(output).to include('Release status: draft')
        end

        it 'shows updated timestamp' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Updated: 2024-01-15')
        end

        it 'shows total count' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Total: 2 track(s)')
        end
      end

      describe 'with sort option' do
        let(:tracks_response) do
          {
            data: {
              'package_name' => package_name,
              'tracks' => [
                { 'id' => 1, 'track_name' => 'production', 'status' => 'completed', 'releases' => [] },
                { 'id' => 2, 'track_name' => 'alpha', 'status' => 'completed', 'releases' => [] },
                { 'id' => 3, 'track_name' => 'beta', 'status' => 'completed', 'releases' => [] }
              ]
            }
          }
        end

        before do
          allow(client).to receive(:get).and_return(tracks_response)
          cli.options = { sort: true }
        end

        it 'sorts tracks alphabetically' do
          output = capture_stdout { cli.tracks(package_name) }
          alpha_pos = output.index('alpha')
          beta_pos = output.index('beta')
          prod_pos = output.index('production')
          expect(alpha_pos).to be < beta_pos
          expect(beta_pos).to be < prod_pos
        end
      end

      describe 'when app not found' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::NotFoundError.new('Android app not found')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Android app not found')
        end

        it 'shows helpful tips' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('mysigner apps --platform android')
          expect(output).to include('mysigner android add')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.tracks(package_name)
        end
      end

      describe 'when API fails' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::ClientError.new('Connection failed')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.tracks(package_name) }
          expect(output).to include('Failed to fetch tracks')
          expect(output).to include('Connection failed')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.tracks(package_name)
        end
      end
    end

    describe 'track command (single track)' do
      let(:track_name) { 'production' }

      describe 'when arguments are missing' do
        it 'shows usage error when no args' do
          output = capture_stdout { cli.track }
          expect(output).to include('Usage: mysigner track PACKAGE_NAME TRACK_NAME')
        end

        it 'shows usage error when only package provided' do
          output = capture_stdout { cli.track(package_name) }
          expect(output).to include('Usage: mysigner track PACKAGE_NAME TRACK_NAME')
        end

        it 'shows examples' do
          output = capture_stdout { cli.track }
          expect(output).to include('mysigner track com.example.myapp production')
          expect(output).to include('mysigner track com.example.myapp beta')
        end

        it 'shows common track names' do
          output = capture_stdout { cli.track }
          expect(output).to include('production, beta, alpha, internal')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.track
        end
      end

      describe 'show track details' do
        let(:track_response) do
          {
            data: {
              'id' => 1,
              'track_name' => 'production',
              'status' => 'completed',
              'releases' => [
                {
                  'status' => 'completed',
                  'versionCodes' => %w[100 101],
                  'name' => '1.0.0',
                  'releaseNotes' => [
                    { 'language' => 'en-US', 'text' => 'Bug fixes and improvements' }
                  ],
                  'userFraction' => 0.5
                }
              ],
              'updated_at' => '2024-01-15T10:30:00Z'
            }
          }
        end

        before do
          allow(client).to receive(:get).and_return(track_response)
        end

        it 'shows track header' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Track: production')
          expect(output).to include('Package: com.example.myapp')
        end

        it 'fetches track from API' do
          expect(client).to receive(:get).with(
            "/api/v1/organizations/#{org_id}/android_apps/package/#{package_name}/tracks/#{track_name}"
          )
          cli.track(package_name, track_name)
        end

        it 'shows track name' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Track Name: production')
        end

        it 'shows track status' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Status: completed')
        end

        it 'shows last updated' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Last Updated: 2024-01-15')
        end

        it 'shows releases section' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Releases:')
          expect(output).to include('Release 1:')
        end

        it 'shows release status' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Status: completed')
        end

        it 'shows version codes' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Version Codes: 100, 101')
        end

        it 'shows release name' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Name: 1.0.0')
        end

        it 'shows release notes' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Release Notes:')
          expect(output).to include('[en-US]')
          expect(output).to include('Bug fixes')
        end

        it 'shows rollout percentage' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Rollout: 50.0%')
        end
      end

      describe 'track with no releases' do
        let(:track_response) do
          {
            data: {
              'id' => 1,
              'track_name' => 'alpha',
              'status' => 'draft',
              'releases' => [],
              'updated_at' => '2024-01-15T10:30:00Z'
            }
          }
        end

        before do
          allow(client).to receive(:get).and_return(track_response)
        end

        it 'shows no releases message' do
          output = capture_stdout { cli.track(package_name, 'alpha') }
          expect(output).to include('No releases found in this track')
        end
      end

      describe 'when app not found' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::NotFoundError.new('Android app not found')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Android app not found')
        end

        it 'shows helpful tips' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('mysigner apps --platform android')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.track(package_name, track_name)
        end
      end

      describe 'when track not found' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::NotFoundError.new('Track not found')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.track(package_name, 'nonexistent') }
          expect(output).to include('Track not found')
        end

        it 'shows helpful tips' do
          output = capture_stdout { cli.track(package_name, 'nonexistent') }
          expect(output).to include('mysigner tracks')
          expect(output).to include('production, beta, alpha, internal')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.track(package_name, 'nonexistent')
        end
      end

      describe 'when API fails' do
        before do
          allow(client).to receive(:get).and_raise(
            Mysigner::ClientError.new('Connection timeout')
          )
        end

        it 'shows error message' do
          output = capture_stdout { cli.track(package_name, track_name) }
          expect(output).to include('Failed to fetch track')
          expect(output).to include('Connection timeout')
        end

        it 'exits with code 1' do
          expect(cli).to receive(:exit).with(1)
          cli.track(package_name, track_name)
        end
      end
    end
  end

  describe 'help text' do
    it 'tracks command has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help tracks]) }
      expect(help_output).to include('List Google Play tracks')
    end

    it 'track command has description' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help track]) }
      expect(help_output).to include('Show details for a specific Google Play track')
    end

    it 'tracks shows sort option' do
      help_output = capture_stdout { Mysigner::CLI.start(%w[help tracks]) }
      expect(help_output).to include('--sort')
    end
  end

  describe 'integration tests' do
    it 'requires login for tracks' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['tracks', 'com.example.app']) }
      expect(output).to include('Not logged in')
    end

    it 'requires login for track' do
      allow(Mysigner::Config).to receive(:new).and_call_original
      config_file = Mysigner::Config::CONFIG_FILE
      allow(File).to receive(:exist?).with(config_file).and_return(false)

      output = capture_stdout { Mysigner::CLI.start(['track', 'com.example.app', 'production']) }
      expect(output).to include('Not logged in')
    end
  end
end
