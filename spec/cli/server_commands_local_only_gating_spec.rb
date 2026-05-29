# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

# Every SERVER command in the local-only audit (see Task 9 of the
# persistent local-only mode plan) must call exit_unless_local_supported!
# before touching any MySigner API, so users in local-only mode get a
# clean explanation instead of the generic "Not logged in" error.

SERVER_COMMAND_INVOCATIONS = [
  %w[login],
  %w[switch],
  %w[orgs],
  %w[sync],
  %w[apps],
  %w[devices],
  %w[device add 00008110-001A2B3C4D5E6F70],
  %w[device update 1234567890],
  %w[certificates],
  %w[certificate download 1],
  %w[profiles],
  %w[profile download 1],
  %w[profile delete 1],
  %w[bundleid list],
  %w[app-groups],
  %w[app-group list],
  %w[merchant-ids],
  %w[merchant-id list],
  %w[tracks com.example.app],
  %w[track com.example.app internal],
  %w[release list],
  %w[keystore list],
  %w[gp-credential list],
  %w[submit],
  # 0.3.1 — android dispatcher: init/add/list register or read MySigner
  # records (list is documented as an alias for `apps --platform android`).
  # Only `build` is purely local. Before 0.3.1 these slipped past the gate
  # and `android add` crashed with NoMethodError on the nil client.
  %w[android init],
  %w[android add com.example.foo],
  %w[android list]
].freeze

RSpec.describe 'Server-only commands in --local-only mode' do
  before { ENV.delete('MYSIGNER_LOCAL_ONLY') }
  after  { ENV.delete('MYSIGNER_LOCAL_ONLY') }

  SERVER_COMMAND_INVOCATIONS.each do |argv|
    it "`mysigner #{argv.join(' ')}` exits cleanly with the local-only explanation" do
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'

      out = StringIO.new
      $stdout = out
      exit_code = begin
        Mysigner::CLI.start(argv)
        0
      rescue SystemExit => e
        e.status
      ensure
        $stdout = STDOUT
      end

      expect(exit_code).to eq(2),
                           "expected exit 2 (server-command-in-local-only-mode), got #{exit_code} for " \
                           "`mysigner #{argv.join(' ')}`. Output:\n#{out.string}"
      expect(out.string).to include("isn't available in local-only mode"),
                            'missing the exit_unless_local_supported! banner for ' \
                            "`mysigner #{argv.join(' ')}`. Output:\n#{out.string}"
    end
  end
end

# Inverse coverage (Rule 9): LOCAL commands must continue to work when
# local-only mode is active. Catches the regression where someone
# accidentally adds a gate to a LOCAL command. version/help/tree are
# pure-info commands with no side effects; `device detect` and
# `certificate check` exercise the per-action LOCAL exceptions inside
# dispatchers that gate other actions.
LOCAL_COMMAND_INVOCATIONS = [
  %w[version],
  %w[help],
  %w[tree],
  %w[device detect],
  %w[certificate check],
  # 0.3.1 — `android build` is the only LOCAL android action; the rest are
  # gated in the SERVER block above. Catches a regression where someone
  # widens the gate whitelist past `build` / `help`.
  %w[android help]
].freeze

RSpec.describe 'Local commands still work in --local-only mode' do
  before { ENV.delete('MYSIGNER_LOCAL_ONLY') }
  after  { ENV.delete('MYSIGNER_LOCAL_ONLY') }

  LOCAL_COMMAND_INVOCATIONS.each do |argv|
    it "`mysigner #{argv.join(' ')}` does NOT print the local-only block message" do
      ENV['MYSIGNER_LOCAL_ONLY'] = '1'

      out = StringIO.new
      $stdout = out
      exit_code = begin
        Mysigner::CLI.start(argv)
        0
      rescue SystemExit => e
        e.status
      rescue StandardError
        # The command may error for unrelated reasons (no project in CWD,
        # no keystore in keychain, etc.) — that's fine. The point is the
        # gate banner should NOT appear.
        nil
      ensure
        $stdout = STDOUT
      end

      expect(out.string).not_to include("isn't available in local-only mode"),
                                "`mysigner #{argv.join(' ')}` was accidentally gated. Output:\n#{out.string}"
      expect(exit_code).not_to eq(2),
                               "`mysigner #{argv.join(' ')}` exited 2 (the gate exit code) when it should not. " \
                               "Output:\n#{out.string}"
    end
  end
end
