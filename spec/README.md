# Test strategy

The CLI is tested in three tiers, each catching a different class of bug.
Most changes only need Tier 1 + 2; Tier 3 runs against real Apple/Google
infrastructure and is gated behind a paid developer account.

## Tier 1 — Unit specs (every commit)

`spec/cli/*.rb`, `spec/build/*.rb`, `spec/signing/*.rb`, `spec/upload/*.rb`,
`spec/cleanup/*.rb`.

Mocks `Mysigner::Client`, `Config`, and project-parser internals via
`instance_double`. ~1ms per example. Catches: command parsing, option
plumbing, scope/role gating, edge cases in detection/parsing logic.

```bash
bundle exec rspec
```

## Tier 2 — Fidelity specs (every commit, also fast)

These keep the unit specs from drifting away from how the backend actually
behaves.

### `spec/build/detector_edge_cases_spec.rb`

Realistic project layouts that aren't in the basic detector spec:
monorepos with multiple workspaces, ambiguous configs, native single-module
Android, framework-precedence cases.

### `spec/build/executor_spec.rb` — `#execute_with_output (private)` block

Direct tests of the xcodebuild streaming/log-capture layer. The build
runner uses `-quiet` plus a keyword filter; framework-loader errors and
license issues do not contain `error:` and previously slipped through to
silent failure. These specs prove the full output is always captured to
`<project>/build/last-build.log` and that the tail is dumped to the user
on failure.

### `spec/contract_spec.rb` + `spec/fixtures/api_responses/*.json`

WebMock against **real, captured** backend responses. Field renames or
removed keys in the MySigner API will trip these assertions even though
hand-crafted unit fixtures keep working.

#### Refreshing API fixtures

These responses get stale when the backend changes shape. To re-record:

1. Boot the backend locally:
   ```bash
   cd ../my-signer && bin/dev
   ```
2. Find or create a token with all scopes for a known org/user. Easiest:
   ```bash
   psql my_signer_development <<SQL
   INSERT INTO api_tokens (organization_id, user_id, name, scopes, token_digest, expires_at, created_at, updated_at)
   VALUES (
     <ORG_ID>, <USER_ID>, 'fixture-capture', 'read,write,admin',
     encode(sha256('mst_fixturecapture'::bytea), 'hex'),
     NOW() + interval '1 hour', NOW(), NOW()
   );
   SQL
   ```
   (Replace `<ORG_ID>` / `<USER_ID>` with real IDs. The plain token to send
   is `mst_fixturecapture`.)
3. Run `script/capture_api_fixtures.rb` (see the script in this directory)
   to hit each endpoint, scrub PII, and write to
   `spec/fixtures/api_responses/`.
4. **Inspect every diff** before committing — names, emails, UDIDs, and
   bundle IDs must be scrubbed. The capture script handles known cases but
   anything new (e.g. a new field that contains a personal name) must be
   added to its `SCRUBS` list.
5. Delete the temp token:
   ```sql
   DELETE FROM api_tokens WHERE name = 'fixture-capture';
   ```

## Tier 3 — Real-backend integration (opt-in, ENV-gated)

These run against a live MySigner backend over HTTP — no WebMock, no
fixtures. They catch issues the contract spec can't: backend code paths
that aren't covered by the captured fixtures, real auth / scope behavior,
network/retry behavior, and "is the prod API even up?" smoke. Excluded
from the default run.

### Read-only suite — runs anytime, never modifies state

`spec/integration/api_smoke_spec.rb`, `apps_spec.rb`, `credentials_spec.rb`

Required ENV:

```bash
export MYSIGNER_API_URL='http://localhost:3000'   # or https://... for prod
export MYSIGNER_API_TOKEN='mst_…your_token_here'
export MYSIGNER_USER_EMAIL='you@example.com'
```

The token only needs `read` scope. Generate one from the dashboard
(Settings → API tokens) or use `mysigner login` to set up local creds and
copy the token from `~/.mysigner/config.yml`.

To run:

```bash
bundle exec rspec --tag integration
# or, equivalently:
INTEGRATION=1 bundle exec rspec spec/integration/
```

Without the ENV vars, examples skip cleanly with a clear message — they
do NOT silently pass.

### CLI smoke against a real project (read-only)

`spec/integration/cli_smoke_spec.rb`

Runs `mysigner version`, `mysigner doctor`, and the project detector
against a real iOS project on disk. Doctor makes API calls but doesn't
modify state.

Additional ENV:

```bash
export MYSIGNER_TEST_IOS_PROJECT_PATH='/abs/path/to/your/ios/project'
```

Skipped automatically if the path isn't set.

### Destructive suite — DOUBLE-GATED

`spec/integration/destructive/ship_testflight_spec.rb`

Actually builds the iOS archive and uploads to TestFlight. Real upload,
real ASC quota, 5–15 minute runtime. Use only as a release-time smoke
test, not on every commit.

```bash
INTEGRATION_DESTRUCTIVE=1 \
  MYSIGNER_API_URL=https://app.mysigner.dev \
  MYSIGNER_API_TOKEN=mst_… \
  MYSIGNER_USER_EMAIL=you@example.com \
  MYSIGNER_TEST_IOS_PROJECT_PATH=~/path/to/project \
  bundle exec rspec --tag destructive
```

The spec makes a best-effort cleanup attempt via the API after upload
(expires the just-created build). If cleanup fails, you'll need to expire
the build manually in App Store Connect → TestFlight → Builds.

**Things still NOT wired up** (manual checklist on releases):

- Submit for App Store review (`mysigner submit`).
- Modify production listings or roll out to live release tracks.
- Android `mysigner ship internal` — same shape, needs an Android project
  on Play Console with internal-track access.

Things to **never** automate (manual checklist):

- Submit for App Store review (`mysigner submit`).
- Modify production listings or roll out to live release tracks.

## Running specific suites

```bash
# Everything
bundle exec rspec

# Just the contract spec
bundle exec rspec spec/contract_spec.rb

# Just detector edge cases
bundle exec rspec spec/build/detector_edge_cases_spec.rb

# All build-related specs
bundle exec rspec spec/build/

# All CLI command specs
bundle exec rspec spec/cli/
```
