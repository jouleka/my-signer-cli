# frozen_string_literal: true

require_relative '../integration_helper'
require 'mysigner/cli'
require 'stringio'
require 'benchmark'

# DESTRUCTIVE: this spec actually builds an iOS archive and uploads it to
# TestFlight. It consumes real ASC API quota, creates a real (processing)
# build in your developer account, and takes 5–15 minutes. Intended for
# release-time smoke testing only — not on every commit.
#
# Double gate: requires the :integration tag AND `INTEGRATION_DESTRUCTIVE=1`.
# Without the env var, every example here skips with a loud message.
#
# Required ENV (in addition to the read-only integration vars):
#   MYSIGNER_TEST_IOS_PROJECT_PATH  /abs/path/to/an/ios/project
#   INTEGRATION_DESTRUCTIVE=1       acknowledge that real uploads will happen
#
# Cleanup: after the upload, the spec attempts to expire the build via
# the ASC API (`asc/builds/:id/expire`). If cleanup fails, you'll need to
# manually expire the build in App Store Connect → TestFlight.
RSpec.describe 'ship testflight (DESTRUCTIVE — real upload)', :integration, :destructive do
  let(:project_path) { ENV.fetch('MYSIGNER_TEST_IOS_PROJECT_PATH', nil) }
  let(:client) { integration_client }

  before do
    skip 'Skipping destructive test. Set INTEGRATION_DESTRUCTIVE=1 to run a real TestFlight upload.' unless ENV['INTEGRATION_DESTRUCTIVE'] == '1'
    skip 'MYSIGNER_TEST_IOS_PROJECT_PATH not set' if project_path.nil? || project_path.empty?
    skip "Project path does not exist: #{project_path}" unless Dir.exist?(project_path)
  end

  def capture_cli(argv)
    out = StringIO.new
    orig_out = $stdout
    $stdout = out
    begin
      Dir.chdir(project_path) { Mysigner::CLI.start(argv) }
    rescue SystemExit
      # Thor may exit; keep capturing output we already have.
    ensure
      $stdout = orig_out
    end
    out.string
  end

  it 'builds, exports, and uploads to TestFlight, then expires the build' do
    # Run the full ship pipeline. This is allowed to take a long time.
    output = nil
    elapsed = Benchmark.realtime do
      output = capture_cli(%w[ship testflight])
    end

    # The CLI prints a success banner if all three phases (build, export,
    # upload) complete. We DO NOT make this test parse a build ID — too
    # brittle across CLI versions. Instead, query the API after upload to
    # find the freshest TestFlight build for the org and expire it.
    expect(output).to match(/Ship Succeeded|Upload (?:complete|succeeded|finished)/i),
                      "Expected a success banner in output. Output:\n#{output}"
    expect(elapsed).to be < (20 * 60), 'Ship took longer than 20 minutes'

    # Best-effort cleanup: find the most recent build and try to expire it.
    # We don't fail the test if cleanup fails — manual cleanup is acceptable.
    begin
      builds = client.get("/api/v1/organizations/#{integration_org_id}/builds")[:data]
      build = builds['data']&.first || builds['builds']&.first
      if build && build['id']
        warn "[cleanup] expiring build id=#{build['id']} version=#{build['version']}"
        client.post(
          "/api/v1/organizations/#{integration_org_id}/builds/#{build['id']}/expire",
          body: {}
        )
      end
    rescue StandardError => e
      warn "[cleanup] expire failed: #{e.message} — expire manually in App Store Connect"
    end
  end
end
