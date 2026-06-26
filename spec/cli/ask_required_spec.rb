# frozen_string_literal: true

require 'spec_helper'

# ask_required must behave like ask() interactively, but fail LOUD in a
# non-TTY context (CI, pipes, `< /dev/null`) instead of letting Thor's ask
# silently return '' on EOF — which otherwise surfaces as a confusing
# downstream error (e.g. an empty keystore password read as "wrong password").
RSpec.describe Mysigner::CLI do
  subject(:cli) { described_class.new([], {}, {}) }

  describe '#ask_required' do
    context 'when a terminal is attached' do
      before { allow($stdin).to receive(:tty?).and_return(true) }

      it 'delegates to ask() and returns the answer' do
        expect(cli).to receive(:ask).with('Keystore password:', echo: false).and_return('s3cret')
        expect(cli.send(:ask_required, 'Keystore password:', 'hint', echo: false)).to eq('s3cret')
      end
    end

    context 'when no terminal is attached (non-interactive)' do
      before do
        allow($stdin).to receive(:tty?).and_return(false)
        allow(cli).to receive(:say)   # swallow the hint line
        allow(cli).to receive(:error) # swallow the error line
      end

      it 'never calls ask (does not consume EOF)' do
        expect(cli).not_to receive(:ask)
        expect { cli.send(:ask_required, 'Version code:', 'hint') }.to raise_error(SystemExit)
      end

      it 'exits non-zero' do
        expect { cli.send(:ask_required, 'Version code:', 'pass --version-code') }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      it 'surfaces the actionable hint' do
        expect(cli).to receive(:say).with('pass --version-code', :yellow)
        expect { cli.send(:ask_required, 'Version code:', 'pass --version-code') }.to raise_error(SystemExit)
      end
    end
  end
end
