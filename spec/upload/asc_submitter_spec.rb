# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'json'
require 'stringio'
require 'mysigner/upload/asc_submitter'

# mysigner-22 follow-up — drives Apple's REST API directly in local-only mode
# so users get the full "ship appstore" experience (upload + submit) without
# any MySigner-server round-trip. The four-step sequence (poll → version →
# attach → submit) is what every regression here would silently undo.
#
# Phase 8 follow-up: the "submit" step is the modern 3-call reviewSubmissions
# choreography (POST /v1/reviewSubmissions → POST /v1/reviewSubmissionItems
# → PATCH /v1/reviewSubmissions/<id>). Tests below stub all three.
RSpec.describe Mysigner::Upload::AscSubmitter do
  let(:jwt) { 'eyJ.fake.jwt' }
  let(:apple_app_id) { '1234567890' }
  let(:cf_bundle_version) { '17' }
  let(:cf_bundle_short_version_string) { '1.0.2' }
  let(:base) { 'https://api.appstoreconnect.apple.com' }
  let(:silent_logger) { StringIO.new }

  # Stubs the modern 3-call submit flow with a successful path returning
  # the given submission id. Spec helpers below compose this with the
  # build-poll + version-attach stubs to keep individual examples readable.
  def stub_review_submission_happy(submission_id:)
    stub_request(:post, "#{base}/v1/reviewSubmissions")
      .to_return(status: 201, body: { 'data' => { 'id' => submission_id } }.to_json)
    stub_request(:post, "#{base}/v1/reviewSubmissionItems")
      .to_return(status: 201, body: { 'data' => { 'id' => 'ITEM_ID' } }.to_json)
    stub_request(:patch, "#{base}/v1/reviewSubmissions/#{submission_id}")
      .to_return(status: 200, body: { 'data' => { 'id' => submission_id } }.to_json)
  end

  def submitter(**overrides)
    described_class.new(
      jwt: jwt,
      apple_app_id: apple_app_id,
      cf_bundle_version: cf_bundle_version,
      cf_bundle_short_version_string: cf_bundle_short_version_string,
      # Tighten the polling so timeout specs finish in <1s without
      # introducing real wall-clock waits.
      processing_timeout: 0.05,
      processing_poll_interval: 0,
      logger: silent_logger,
      **overrides
    )
  end

  describe '#http_conn timeouts' do
    # The submitter drives a 30-minute poll loop against Apple. A stalled
    # connection that accepts but never responds must not hang the CLI
    # indefinitely — the Faraday connection needs explicit timeouts.
    it 'sets an explicit request timeout on the Apple connection' do
      expect(submitter.send(:http_conn).options.timeout).to be > 0
    end

    it 'sets an explicit open (connect) timeout on the Apple connection' do
      expect(submitter.send(:http_conn).options.open_timeout).to be > 0
    end
  end

  describe '#submit!' do
    # Happy path: build is already VALID, an editable appStoreVersion exists,
    # attach + submit both succeed. This is the most common shape because the
    # uploader returns after altool exits, by which time small builds often
    # finish processing within a few seconds.
    it 'returns the submission id on the happy path (build VALID, version PREPARE_FOR_SUBMISSION)' do
      # Step 1
      stub_request(:get, "#{base}/v1/builds")
        .with(query: { 'filter[app]' => apple_app_id, 'filter[version]' => cf_bundle_version })
        .to_return(status: 200, body: {
          'data' => [{
            'id' => 'BUILD_ID',
            'attributes' => { 'processingState' => 'VALID' }
          }]
        }.to_json)

      # Step 2 — existing PREPARE_FOR_SUBMISSION version
      stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
        .with(query: { 'filter[versionString]' => cf_bundle_short_version_string })
        .to_return(status: 200, body: {
          'data' => [{
            'id' => 'VERSION_ID',
            'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' }
          }]
        }.to_json)

      # Step 3 — attach build
      stub_request(:patch, "#{base}/v1/appStoreVersions/VERSION_ID/relationships/build")
        .with(body: { data: { type: 'builds', id: 'BUILD_ID' } }.to_json)
        .to_return(status: 204, body: '')

      # Step 4 — modern 3-call reviewSubmissions choreography
      stub_review_submission_happy(submission_id: 'SUBMISSION_ID')

      expect(submitter.submit!).to eq('SUBMISSION_ID')
    end

    it 'drives the 3-call reviewSubmissions choreography with the right payloads' do
      # WHY this spec: the wire shape Apple expects is unforgiving. Each of
      # the three calls must reference the prior resource's id correctly,
      # else Apple silently 4xx's with cryptic errors. Lock the shape.
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json)
      stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
        .with(query: hash_including({}))
        .to_return(status: 200, body: {
          'data' => [{ 'id' => 'VER', 'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }]
        }.to_json)
      stub_request(:patch, "#{base}/v1/appStoreVersions/VER/relationships/build").to_return(status: 204, body: '')

      # (a) Create reviewSubmissions container — must reference the app + platform
      create_sub = stub_request(:post, "#{base}/v1/reviewSubmissions")
                   .with(body: hash_including(
                     'data' => hash_including(
                       'type' => 'reviewSubmissions',
                       'attributes' => hash_including('platform' => 'IOS'),
                       'relationships' => hash_including(
                         'app' => { 'data' => { 'type' => 'apps', 'id' => apple_app_id } }
                       )
                     )
                   ))
                   .to_return(status: 201, body: { 'data' => { 'id' => 'RS_ID' } }.to_json)

      # (b) Attach the appStoreVersion to the submission
      attach_item = stub_request(:post, "#{base}/v1/reviewSubmissionItems")
                    .with(body: hash_including(
                      'data' => hash_including(
                        'type' => 'reviewSubmissionItems',
                        'relationships' => hash_including(
                          'reviewSubmission' => { 'data' => { 'type' => 'reviewSubmissions', 'id' => 'RS_ID' } },
                          'appStoreVersion' => { 'data' => { 'type' => 'appStoreVersions', 'id' => 'VER' } }
                        )
                      )
                    ))
                    .to_return(status: 201, body: { 'data' => { 'id' => 'ITEM_ID' } }.to_json)

      # (c) Flip submitted=true
      finalize = stub_request(:patch, "#{base}/v1/reviewSubmissions/RS_ID")
                 .with(body: hash_including(
                   'data' => hash_including(
                     'type' => 'reviewSubmissions',
                     'id' => 'RS_ID',
                     'attributes' => hash_including('submitted' => true)
                   )
                 ))
                 .to_return(status: 200, body: { 'data' => { 'id' => 'RS_ID' } }.to_json)

      expect(submitter.submit!).to eq('RS_ID')
      expect(create_sub).to have_been_requested
      expect(attach_item).to have_been_requested
      expect(finalize).to have_been_requested
    end

    it 'polls /v1/builds until processingState == VALID' do
      # Two PROCESSING responses then VALID — proves we don't short-circuit
      # on the first non-VALID response, which would race the build into the
      # submit before Apple has accepted it.
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(
          { status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'PROCESSING' } }] }.to_json },
          { status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'PROCESSING' } }] }.to_json },
          { status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json }
        )

      stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
        .with(query: hash_including({}))
        .to_return(status: 200, body: {
          'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }]
        }.to_json)
      stub_request(:patch, "#{base}/v1/appStoreVersions/V/relationships/build").to_return(status: 204, body: '')
      stub_review_submission_happy(submission_id: 'S')

      submitter(processing_timeout: 5, processing_poll_interval: 0).submit!

      # Three polls happened — drift here would mean we either skipped the
      # processing wait or polled too aggressively.
      expect(WebMock).to have_requested(:get, "#{base}/v1/builds")
        .with(query: hash_including({})).times(3)
    end

    it 'raises BuildProcessingTimeoutError when the build never reaches VALID within the timeout' do
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'PROCESSING' } }] }.to_json)

      expect { submitter.submit! }
        .to raise_error(described_class::BuildProcessingTimeoutError, /did not finish processing/)
    end

    it 'raises BuildProcessingTimeoutError when /v1/builds keeps returning an empty data array' do
      # Apple sometimes takes a minute to surface a freshly-uploaded build
      # at all (it's been received but not yet indexed). Treat that the same
      # as PROCESSING from a timeout perspective.
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [] }.to_json)

      expect { submitter.submit! }
        .to raise_error(described_class::BuildProcessingTimeoutError)
    end

    it 'creates a new appStoreVersion when none exists for the marketing version' do
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json)

      # No existing versions at all
      stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [] }.to_json)

      # The submitter should POST /v1/appStoreVersions with the right payload
      # shape — getting any of these wrong is what Apple's "ENTITY_ERROR"
      # responses come back as.
      create_stub = stub_request(:post, "#{base}/v1/appStoreVersions")
                    .with(body: hash_including(
                      'data' => hash_including(
                        'type' => 'appStoreVersions',
                        'attributes' => hash_including(
                          'versionString' => cf_bundle_short_version_string,
                          'platform' => 'IOS'
                        ),
                        'relationships' => hash_including(
                          'app' => { 'data' => { 'type' => 'apps', 'id' => apple_app_id } }
                        )
                      )
                    ))
                    .to_return(status: 201, body: { 'data' => { 'id' => 'NEW_V' } }.to_json)

      stub_request(:patch, "#{base}/v1/appStoreVersions/NEW_V/relationships/build").to_return(status: 204, body: '')
      stub_review_submission_happy(submission_id: 'S')

      submitter.submit!

      expect(create_stub).to have_been_requested
    end

    it 'raises VersionAlreadyReleasedError when the only existing version is READY_FOR_SALE' do
      # WHY this is an explicit error class: silently auto-creating a NEW
      # marketing version (e.g. 1.0 → 1.0.1) is a scope decision the user
      # owns, not the CLI. Surfacing this case lets the user bump the
      # version in Xcode and re-run.
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json)

      stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
        .with(query: hash_including({}))
        .to_return(status: 200, body: {
          'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'READY_FOR_SALE' } }]
        }.to_json)

      expect { submitter.submit! }
        .to raise_error(described_class::VersionAlreadyReleasedError, /bump MARKETING_VERSION/i)
    end

    it 'raises SubmissionRejectedError carrying Apple\'s error body verbatim when /v1/reviewSubmissions returns non-201' do
      # Apple rejects with a 409 + JSON body when required metadata (description,
      # what's new, screenshots) is missing. We surface that body verbatim so
      # the user can act without having to chase API docs. Lock that we map
      # rejections at the first call (POST /v1/reviewSubmissions).
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json)
      stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
        .with(query: hash_including({}))
        .to_return(status: 200, body: {
          'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }]
        }.to_json)
      stub_request(:patch, "#{base}/v1/appStoreVersions/V/relationships/build").to_return(status: 204, body: '')

      apple_body = {
        'errors' => [
          { 'status' => '409',
            'code' => 'ENTITY_ERROR.REQUIRED',
            'title' => 'A relationship value is required',
            'detail' => 'You must provide a value for the relationship \'whatsNew\'.' }
        ]
      }.to_json
      stub_request(:post, "#{base}/v1/reviewSubmissions")
        .to_return(status: 409, body: apple_body)

      expect { submitter.submit! }
        .to raise_error(described_class::SubmissionRejectedError, /whatsNew/)
    end

    it 'raises SubmissionRejectedError when PATCH /v1/reviewSubmissions/<id> (submitted=true) returns non-200' do
      # Lock the rejection contract for the LAST step of the choreography
      # too — Apple often only catches metadata gaps when you flip submitted
      # to true, after the first two calls have already succeeded.
      stub_request(:get, "#{base}/v1/builds")
        .with(query: hash_including({}))
        .to_return(status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json)
      stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
        .with(query: hash_including({}))
        .to_return(status: 200, body: {
          'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }]
        }.to_json)
      stub_request(:patch, "#{base}/v1/appStoreVersions/V/relationships/build").to_return(status: 204, body: '')
      stub_request(:post, "#{base}/v1/reviewSubmissions")
        .to_return(status: 201, body: { 'data' => { 'id' => 'RS' } }.to_json)
      stub_request(:post, "#{base}/v1/reviewSubmissionItems")
        .to_return(status: 201, body: { 'data' => { 'id' => 'ITEM' } }.to_json)
      stub_request(:patch, "#{base}/v1/reviewSubmissions/RS")
        .to_return(status: 422, body: { 'errors' => [{ 'detail' => 'Screenshots required' }] }.to_json)

      expect { submitter.submit! }
        .to raise_error(described_class::SubmissionRejectedError, /Screenshots required/)
    end

    # Phase 8 Fix 2 — broader in-flight state coverage.
    # WHY: previously every state except PREPARE_FOR_SUBMISSION and
    # READY_FOR_SALE fell through to POST /v1/appStoreVersions, which Apple
    # rejected with a cryptic RELATIONSHIP.INVALID. We now pre-empt with a
    # typed VersionInFlightError naming the state + next action.
    describe 'in-flight appStoreVersion handling' do
      before do
        stub_request(:get, "#{base}/v1/builds")
          .with(query: hash_including({}))
          .to_return(status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json)
      end

      it 'raises VersionInFlightError when the version is WAITING_FOR_REVIEW' do
        # Most common in-flight state — user submitted, Apple hasn't started
        # reviewing yet. Message must name the state and tell the user to
        # wait or cancel.
        stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
          .with(query: hash_including({}))
          .to_return(status: 200, body: {
            'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'WAITING_FOR_REVIEW' } }]
          }.to_json)

        expect { submitter.submit! }
          .to raise_error(
            described_class::VersionInFlightError,
            /WAITING_FOR_REVIEW.*(wait|cancel)/im
          )
      end

      it 'raises VersionInFlightError when the version is REJECTED' do
        # User got rejected, tried to re-submit without bumping
        # MARKETING_VERSION. We tell them to bump.
        stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
          .with(query: hash_including({}))
          .to_return(status: 200, body: {
            'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'REJECTED' } }]
          }.to_json)

        expect { submitter.submit! }
          .to raise_error(
            described_class::VersionInFlightError,
            /REJECTED.*MARKETING_VERSION/im
          )
      end

      it 'raises VersionInFlightError when the version is PENDING_DEVELOPER_RELEASE' do
        # Apple approved; user needs to release manually. No re-submit needed.
        stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
          .with(query: hash_including({}))
          .to_return(status: 200, body: {
            'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'PENDING_DEVELOPER_RELEASE' } }]
          }.to_json)

        expect { submitter.submit! }
          .to raise_error(
            described_class::VersionInFlightError,
            /PENDING_DEVELOPER_RELEASE.*release/im
          )
      end
    end

    # Phase 8 Fix 3 — poll resilience against transient errors / rate limits.
    # WHY: the 30-minute poll spans real network flakiness and Apple's rate
    # limiter. One blip should not abort an otherwise healthy wait. Only the
    # wall-clock deadline (BuildProcessingTimeoutError) should end the loop
    # other than success.
    describe 'poll resilience' do
      it 'retries on transient Faraday::ConnectionFailed and eventually returns VALID' do
        # Sequence: ConnectionFailed → ConnectionFailed → VALID.
        # If the submitter aborted on the first error, this test would
        # raise that error from submit! — instead, it should reach the
        # third response and succeed.
        stub_request(:get, "#{base}/v1/builds")
          .with(query: hash_including({}))
          .to_raise(Faraday::ConnectionFailed.new('dns failure'))
          .then.to_raise(Faraday::ConnectionFailed.new('socket reset'))
          .then.to_return(status: 200, body: {
            'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }]
          }.to_json)
        stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
          .with(query: hash_including({}))
          .to_return(status: 200, body: {
            'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }]
          }.to_json)
        stub_request(:patch, "#{base}/v1/appStoreVersions/V/relationships/build").to_return(status: 204, body: '')
        stub_review_submission_happy(submission_id: 'S')

        expect(submitter(processing_timeout: 5, processing_poll_interval: 0).submit!).to eq('S')
      end

      it 'retries on 429 Too Many Requests and respects Retry-After header before the next poll' do
        # First poll → 429 with Retry-After: 0 (avoid wall-clock waits in the
        # test). Second poll → VALID. Verifies the AppleApiError carries
        # status + retry_after, and that we don't bail out of the loop.
        stub_request(:get, "#{base}/v1/builds")
          .with(query: hash_including({}))
          .to_return(
            { status: 429, headers: { 'Retry-After' => '0' }, body: { 'errors' => [{ 'detail' => 'rate limited' }] }.to_json },
            { status: 200, body: { 'data' => [{ 'id' => 'BID', 'attributes' => { 'processingState' => 'VALID' } }] }.to_json }
          )
        stub_request(:get, "#{base}/v1/apps/#{apple_app_id}/appStoreVersions")
          .with(query: hash_including({}))
          .to_return(status: 200, body: {
            'data' => [{ 'id' => 'V', 'attributes' => { 'appStoreState' => 'PREPARE_FOR_SUBMISSION' } }]
          }.to_json)
        stub_request(:patch, "#{base}/v1/appStoreVersions/V/relationships/build").to_return(status: 204, body: '')
        stub_review_submission_happy(submission_id: 'S')

        expect(submitter(processing_timeout: 5, processing_poll_interval: 0).submit!).to eq('S')
      end

      it 'still raises BuildProcessingTimeoutError when transient errors persist past the deadline' do
        # The deadline must be the only loop exit other than VALID/INVALID,
        # even when every iteration is a transient failure.
        stub_request(:get, "#{base}/v1/builds")
          .with(query: hash_including({}))
          .to_raise(Faraday::ConnectionFailed.new('boom'))

        expect { submitter.submit! }
          .to raise_error(described_class::BuildProcessingTimeoutError)
      end
    end
  end
end
