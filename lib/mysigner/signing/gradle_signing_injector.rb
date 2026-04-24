# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Mysigner
  module Signing
    class GradleSigningInjector
      # Local variable is `aliasName` (not `keyAlias`) to avoid a Groovy
      # `with { }` scoping ambiguity: `keyAlias = keyAlias` would resolve the
      # RHS against the property being set (null at that point), silently
      # signing with the wrong alias.
      INIT_SCRIPT = <<~GROOVY
        allprojects {
          afterEvaluate { project ->
            if (!project.hasProperty('android')) return
            def storePw   = System.getenv('MYSIGNER_STORE_PASSWORD')
            def keyPw     = System.getenv('MYSIGNER_KEY_PASSWORD')
            def aliasName = System.getenv('MYSIGNER_KEY_ALIAS')
            def ksPath    = System.getenv('MYSIGNER_STORE_FILE')
            if (!storePw || !ksPath) return

            def existing = project.android.signingConfigs.findByName('release')
            def alreadyConfigured = existing != null && existing.storeFile != null
            if (alreadyConfigured) {
              println "MySigner: release signingConfig already set; skipping override."
              return
            }
            project.android.signingConfigs.maybeCreate('release').with {
              storeFile     = file(ksPath)
              storePassword = storePw
              keyAlias      = aliasName
              keyPassword   = keyPw
            }
            project.android.buildTypes.findByName('release')?.signingConfig =
              project.android.signingConfigs.getByName('release')
          }
        }
      GROOVY

      def initialize
        @tmpdir = nil
      end

      def write_init_script!
        @tmpdir = Dir.mktmpdir('mysigner-signing-')
        path = File.join(@tmpdir, 'init.gradle')
        File.write(path, INIT_SCRIPT)
        path
      end

      def env_vars(keystore_path:, store_password:, key_password:, key_alias:)
        {
          'MYSIGNER_STORE_FILE' => keystore_path,
          'MYSIGNER_STORE_PASSWORD' => store_password,
          'MYSIGNER_KEY_PASSWORD' => key_password,
          'MYSIGNER_KEY_ALIAS' => key_alias
        }
      end

      def cleanup!
        FileUtils.rm_rf(@tmpdir) if @tmpdir && Dir.exist?(@tmpdir)
        @tmpdir = nil
      end
    end
  end
end
