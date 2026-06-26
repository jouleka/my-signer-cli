# frozen_string_literal: true

require 'faraday'
require 'json'

module Mysigner
  module Upload
    # Drives Apple's REST API directly to submit a freshly-uploaded build
    # for App Store review in `--local-only` mode. Replaces the historical
    # "submit-for-review is not automated" hand-off banner.
    #
    # The vault-mode submit path (Mysigner::Upload::AppStoreSubmission +
    # AppStoreAutomation) calls MySigner-internal endpoints; in local-only
    # we cannot — the whole point of local-only is no server round-trip. So
    # we re-implement just the App Store Connect REST calls a submission
    # actually needs, using the same JWT the AscRestUploader already minted.
    #
    # Flow (per https://developer.apple.com/documentation/appstoreconnectapi):
    #   1. POLL  /v1/builds?filter[app]=…&filter[version]=…   until processingState == VALID
    #   2. FIND  /v1/apps/<id>/appStoreVersions?filter[versionString]=…
    #      or CREATE /v1/appStoreVersions when none exists in PREPARE_FOR_SUBMISSION
    #   3. PATCH /v1/appStoreVersions/<v_id>/relationships/build  (attach build)
    #   4a. POST  /v1/reviewSubmissions                            (create submission container)
    #   4b. POST  /v1/reviewSubmissionItems                        (attach the version)
    #   4c. PATCH /v1/reviewSubmissions/<id> {submitted: true}     (flip to submitted)
    #
    # WHY 4a/4b/4c instead of the older POST /v1/appStoreVersionSubmissions:
    # Apple deprecated `appStoreVersionSubmissions` in favour of the
    # `reviewSubmissions` choreography. The old endpoint silently 4xx's for
    # apps onboarded after the cut-over, so we use the modern path
    # unconditionally — it works for all apps regardless of vintage.
    #
    # Returns the submission id (String). Raises a typed error on each
    # foreseeable failure so the CLI rescue can give a one-line, actionable
    # hint without parsing Apple's raw error bodies.
    class AscSubmitter
      APPLE_ASC_BASE = 'https://api.appstoreconnect.apple.com'

      # 30 minutes is the working ceiling for build processing on Apple's
      # side. Most builds finish in <10 minutes but occasional Apple-side
      # backlogs push past 15. Beyond 30 the user almost certainly wants to
      # walk away rather than keep the CLI blocked.
      DEFAULT_PROCESSING_TIMEOUT = 30 * 60
      DEFAULT_PROCESSING_POLL_INTERVAL = 30

      # Raised when /v1/builds never reports processingState == VALID
      # within @processing_timeout. The build is still on Apple's side; the
      # user can re-run `mysigner submit` later once processing completes.
      class BuildProcessingTimeoutError < StandardError; end

      # Raised when the only existing appStoreVersion for this marketing
      # version is already READY_FOR_SALE (released). We refuse to silently
      # auto-create a new version on the user's behalf — bumping the
      # marketing version is a scope decision they own.
      class VersionAlreadyReleasedError < StandardError; end

      # Raised when an appStoreVersion already exists for this marketing
      # version but is in an in-flight state where we can neither edit it
      # nor create a sibling (Apple rejects POST /v1/appStoreVersions with
      # RELATIONSHIP.INVALID in that case). The message names the actual
      # Apple state and the next user action (wait, cancel, or bump
      # MARKETING_VERSION) so the CLI rescue can stay one-line.
      class VersionInFlightError < StandardError; end

      # Raised when Apple rejects any step of the submit-for-review
      # choreography (reviewSubmissions / reviewSubmissionItems / PATCH
      # submitted=true). The message carries Apple's verbatim error body so
      # the user can act — usually the cause is missing metadata
      # (description, screenshots, what's new).
      class SubmissionRejectedError < StandardError; end

      # Raised on any other unexpected non-2xx response from Apple. Carries
      # the HTTP status + body so failures surface loud (Rule 12). `status`
      # and `retry_after` are exposed so the poll loop can branch on 429s
      # without re-parsing the message string.
      class AppleApiError < StandardError
        attr_reader :status, :retry_after

        def initialize(message, status: nil, retry_after: nil)
          super(message)
          @status = status
          @retry_after = retry_after
        end
      end

      def initialize(jwt:, apple_app_id:, cf_bundle_version:, cf_bundle_short_version_string:,
                     platform: 'IOS',
                     processing_timeout: DEFAULT_PROCESSING_TIMEOUT,
                     processing_poll_interval: DEFAULT_PROCESSING_POLL_INTERVAL,
                     logger: $stderr)
        @jwt = jwt
        @apple_app_id = apple_app_id.to_s
        @cf_bundle_version = cf_bundle_version.to_s
        @cf_bundle_short_version_string = cf_bundle_short_version_string.to_s
        @platform = platform.to_s
        @processing_timeout = processing_timeout
        @processing_poll_interval = processing_poll_interval
        @logger = logger
      end

      # Drives steps 1–4 end-to-end and returns the submission id on success.
      def submit!
        build_id = wait_for_build_valid!
        version_id = find_or_create_app_store_version!
        attach_build!(version_id, build_id)
        submit_for_review_via_review_submissions!(version_id)
      end

      private

      # Step 1 — poll /v1/builds until the matching build is processed.
      # Apple's /v1/builds returns ALL builds for the app paginated; the
      # filter[version]= keyword filters server-side on CFBundleVersion (the
      # `version` attribute, despite the name). filter[app]= scopes to one app.
      # processingState transitions: PROCESSING → VALID (good) | INVALID (bad).
      #
      # Resilience: transient Faraday errors (connection failed, timeout) and
      # AppleApiError (e.g. 429 Too Many Requests, 5xx) are swallowed PER
      # ITERATION — the only exit conditions are VALID (success), INVALID
      # (typed error), or the wall-clock deadline (BuildProcessingTimeoutError).
      # WHY: the 30-minute poll spans real network flakiness and Apple's
      # rate limiter; one blip should not abort an otherwise healthy wait.
      def wait_for_build_valid!
        deadline = monotonic_now + @processing_timeout
        last_state = nil

        loop do
          state, build_id, sleep_interval = poll_once(last_state)
          return build_id if state == 'VALID'

          if state == 'INVALID'
            raise AppleApiError,
                  "Apple marked build #{@cf_bundle_version} as INVALID during processing. " \
                  'Check App Store Connect for the diagnostic message.'
          end

          last_state = state if state

          if monotonic_now >= deadline
            raise BuildProcessingTimeoutError,
                  "Apple did not finish processing build #{@cf_bundle_version} within " \
                  "#{@processing_timeout / 60} minutes. " \
                  'Re-run `mysigner submit` once it shows as Ready to Submit in App Store Connect.'
          end

          sleep sleep_interval
        end
      end

      # One poll iteration. Returns [state, build_id, sleep_interval].
      # `state` may be nil when (a) the GET raised transiently or (b) Apple
      # returned an empty data array — both are "keep waiting" from the loop's
      # POV. Transient errors are logged here so the caller stays linear.
      def poll_once(last_state)
        builds = apple_get_json('/v1/builds',
                                params: { 'filter[app]' => @apple_app_id,
                                          'filter[version]' => @cf_bundle_version })
        match = Array(builds['data']).first
        if match
          state = match.dig('attributes', 'processingState')
          if state != last_state && state != 'VALID'
            log("[mysigner] App Store Connect: build #{@cf_bundle_short_version_string} (#{@cf_bundle_version}) processingState=#{state}")
          end
          [state, match['id'], @processing_poll_interval]
        else
          log("[mysigner] App Store Connect: waiting for build #{@cf_bundle_version} to appear (Apple may still be ingesting)...")
          [nil, nil, @processing_poll_interval]
        end
      rescue AppleApiError => e
        interval = retry_after_for(e)
        log "[mysigner] poll attempt failed: #{e.class.name}: #{e.message} — retrying in #{interval}s"
        [nil, nil, interval]
      rescue Faraday::Error => e
        log "[mysigner] poll attempt failed: #{e.class.name}: #{e.message} — retrying in #{@processing_poll_interval}s"
        [nil, nil, @processing_poll_interval]
      end

      # Returns the sleep interval to use after a transient error. Honours
      # Apple's `Retry-After` header (seconds) on 429 responses; otherwise
      # falls back to the configured poll interval.
      def retry_after_for(error)
        if error.status == 429 && error.retry_after
          [error.retry_after.to_i, @processing_poll_interval].max
        else
          @processing_poll_interval
        end
      end

      # Step 2 — find an existing appStoreVersion for this marketing version
      # that's still mutable (PREPARE_FOR_SUBMISSION), or create one.
      #
      # When a version exists in an in-flight state, posting to
      # /v1/appStoreVersions returns Apple's RELATIONSHIP.INVALID error
      # ("a duplicate appStoreVersion already exists") — useless for the
      # CLI user. We pre-empt that by raising a typed error per state with
      # an actionable next step, so the rescue chain can stay one-line.
      def find_or_create_app_store_version!
        existing = apple_get_json("/v1/apps/#{@apple_app_id}/appStoreVersions",
                                  params: { 'filter[versionString]' => @cf_bundle_short_version_string })
        versions = Array(existing['data'])
        prepare = versions.find { |v| v.dig('attributes', 'appStoreState') == 'PREPARE_FOR_SUBMISSION' }
        return prepare['id'] if prepare

        if versions.any? { |v| v.dig('attributes', 'appStoreState') == 'READY_FOR_SALE' }
          raise VersionAlreadyReleasedError,
                "App Store version #{@cf_bundle_short_version_string} is already released (READY_FOR_SALE). " \
                'Bump MARKETING_VERSION in Xcode (e.g. 1.0 → 1.0.1), re-archive, and re-run.'
        end

        in_flight = versions.find { |v| IN_FLIGHT_STATES.include?(v.dig('attributes', 'appStoreState')) }
        if in_flight
          state = in_flight.dig('attributes', 'appStoreState')
          raise VersionInFlightError,
                "App Store version #{@cf_bundle_short_version_string} is in state #{state} — " \
                "cannot create or edit it. #{action_for_in_flight_state(state)}"
        end

        # No editable version exists — create a fresh one. POST returns 201
        # with the new resource in `data`.
        body = {
          data: {
            type: 'appStoreVersions',
            attributes: {
              versionString: @cf_bundle_short_version_string,
              platform: @platform
            },
            relationships: {
              app: { data: { type: 'apps', id: @apple_app_id } }
            }
          }
        }
        created = apple_post_json('/v1/appStoreVersions', body: body, expected_status: 201)
        created.dig('data', 'id')
      end

      # WHY this list, not just "anything that isn't PREPARE_FOR_SUBMISSION":
      # we enumerate the known in-flight states explicitly so an Apple-side
      # state addition doesn't get silently lumped into a generic bucket. If
      # a new state appears in the wild we'll fall through to the POST and
      # surface Apple's raw error — louder than silently mis-categorising.
      IN_FLIGHT_STATES = %w[
        WAITING_FOR_REVIEW
        IN_REVIEW
        PENDING_DEVELOPER_RELEASE
        PROCESSING_FOR_APP_STORE
        DEVELOPER_REJECTED
        REJECTED
        METADATA_REJECTED
        INVALID_BINARY
        WAITING_FOR_EXPORT_COMPLIANCE
        ACCEPTED
      ].freeze
      private_constant :IN_FLIGHT_STATES

      # Per-state next-step copy. The CLI surfaces these verbatim, so each
      # line must be self-contained and actionable.
      def action_for_in_flight_state(state)
        case state
        when 'WAITING_FOR_REVIEW', 'IN_REVIEW', 'PROCESSING_FOR_APP_STORE', 'ACCEPTED'
          'Wait for Apple to finish review, then re-run. To cancel and resubmit, ' \
          "cancel the review in App Store Connect (Apps → your app → 'Cancel')."
        when 'PENDING_DEVELOPER_RELEASE'
          'The build is approved and waiting for you to release it manually in ' \
          'App Store Connect. No re-submit is needed; release it there.'
        when 'WAITING_FOR_EXPORT_COMPLIANCE'
          'Provide export-compliance answers in App Store Connect, then re-run.'
        when 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'
          'Bump MARKETING_VERSION in Xcode (e.g. 1.0 → 1.0.1), fix the rejection ' \
          'cause in App Store Connect, re-archive, and re-run.'
        else
          'Resolve the version state in App Store Connect, then re-run.'
        end
      end

      # Step 3 — attach the processed build to the appStoreVersion via the
      # build relationship. PATCH returns 204 No Content on success.
      def attach_build!(version_id, build_id)
        body = { data: { type: 'builds', id: build_id } }
        apple_patch_json("/v1/appStoreVersions/#{version_id}/relationships/build",
                         body: body, expected_status: 204)
      end

      # Step 4 — drive Apple's modern 3-call submit-for-review choreography:
      #   (a) POST /v1/reviewSubmissions          → create a submission container
      #   (b) POST /v1/reviewSubmissionItems      → attach the appStoreVersion
      #   (c) PATCH /v1/reviewSubmissions/<id>    → flip submitted=true
      #
      # WHY 3 calls instead of the legacy one: see class docstring. We map
      # every 4xx in any of the three to SubmissionRejectedError so the CLI
      # rescue contract stays identical — the typed-error surface didn't
      # change, only the wire shape did.
      def submit_for_review_via_review_submissions!(version_id)
        submission_id = create_review_submission!
        create_review_submission_item!(submission_id: submission_id, version_id: version_id)
        finalize_review_submission!(submission_id)
        submission_id
      end

      # (a) Create the submission container scoped to this app + platform.
      def create_review_submission!
        body = {
          data: {
            type: 'reviewSubmissions',
            attributes: { platform: @platform },
            relationships: {
              app: { data: { type: 'apps', id: @apple_app_id } }
            }
          }
        }
        created = apple_post_json('/v1/reviewSubmissions',
                                  body: body,
                                  expected_status: 201,
                                  rejection_class: SubmissionRejectedError)
        created.dig('data', 'id')
      end

      # (b) Attach the appStoreVersion to the submission. Apple returns 201
      # on success.
      def create_review_submission_item!(submission_id:, version_id:)
        body = {
          data: {
            type: 'reviewSubmissionItems',
            relationships: {
              reviewSubmission: { data: { type: 'reviewSubmissions', id: submission_id } },
              appStoreVersion: { data: { type: 'appStoreVersions', id: version_id } }
            }
          }
        }
        apple_post_json('/v1/reviewSubmissionItems',
                        body: body,
                        expected_status: 201,
                        rejection_class: SubmissionRejectedError)
      end

      # (c) Flip `submitted` to true. Apple returns 200 with the updated
      # resource on success.
      def finalize_review_submission!(submission_id)
        body = {
          data: {
            type: 'reviewSubmissions',
            id: submission_id,
            attributes: { submitted: true }
          }
        }
        apple_patch_json("/v1/reviewSubmissions/#{submission_id}",
                         body: body,
                         expected_status: 200,
                         rejection_class: SubmissionRejectedError)
      end

      def apple_get_json(path, params: {})
        resp = http_conn.get(path) do |req|
          params.each { |k, v| req.params[k.to_s] = v }
          req.headers['Authorization'] = "Bearer #{@jwt}"
        end
        ensure_2xx!(resp, method: :GET, path: path)
        parse_json(resp.body)
      end

      def apple_post_json(path, body:, expected_status: 201, rejection_class: AppleApiError)
        resp = http_conn.post(path) do |req|
          req.headers['Authorization'] = "Bearer #{@jwt}"
          req.headers['Content-Type'] = 'application/json'
          req.body = JSON.generate(body)
        end
        ensure_status!(resp, expected_status, method: :POST, path: path, rejection_class: rejection_class)
        resp.status == 204 ? {} : parse_json(resp.body)
      end

      def apple_patch_json(path, body:, expected_status: 204, rejection_class: AppleApiError)
        resp = http_conn.patch(path) do |req|
          req.headers['Authorization'] = "Bearer #{@jwt}"
          req.headers['Content-Type'] = 'application/json'
          req.body = JSON.generate(body)
        end
        ensure_status!(resp, expected_status, method: :PATCH, path: path, rejection_class: rejection_class)
        resp.status == 204 ? {} : parse_json(resp.body)
      end

      def http_conn
        @http_conn ||= Faraday.new(url: APPLE_ASC_BASE) do |f|
          # Explicit timeouts so a stalled Apple connection can't hang the
          # 30-minute poll loop forever (the per-request rescue only fires on
          # an actual error, not a silent stall).
          f.options.timeout = 60
          f.options.open_timeout = 10
          f.adapter Faraday.default_adapter
        end
      end

      def ensure_2xx!(resp, method:, path:)
        return if resp.status.between?(200, 299)

        raise apple_api_error_for(resp, method: method, path: path)
      end

      def ensure_status!(resp, expected, method:, path:, rejection_class: AppleApiError)
        return if resp.status == expected

        raise apple_api_error_for(resp, method: method, path: path) if rejection_class == AppleApiError

        raise rejection_class, "Apple #{method} #{path} returned #{resp.status}: #{resp.body}"
      end

      # Bundles HTTP status + Retry-After onto the exception so the poll
      # loop can branch on 429s without re-parsing strings.
      def apple_api_error_for(resp, method:, path:)
        AppleApiError.new(
          "Apple #{method} #{path} returned #{resp.status}: #{resp.body}",
          status: resp.status,
          retry_after: resp.headers && resp.headers['Retry-After']
        )
      end

      def parse_json(body)
        return {} if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        {}
      end

      def log(message)
        return unless @logger

        @logger.respond_to?(:puts) ? @logger.puts(message) : warn(message)
      end

      # `Process.clock_gettime(CLOCK_MONOTONIC)` is immune to wall-clock
      # adjustments (NTP, DST) — the right primitive for "how long has X
      # been running" timeouts.
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
