#!/usr/bin/env bash
# Run smoke and offline integration checks without accessing DockerLabs.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

PASSED=0
FAILED=0
CURRENT_TEST='Setup'
REPORT_DONE=0
# Each assertion groups commands; all failures trigger a visible failure and summary.
test_pass() {
  printf '  [PASS] %s\n' "$1"
  PASSED=$((PASSED + 1))
  CURRENT_TEST='Unfinished check after previous PASS'
}
test_start() {
  CURRENT_TEST="$1"
  printf '  [TEST] %s\n' "$CURRENT_TEST"
}
report_summary() {
  local result="$1"
  (( REPORT_DONE == 0 )) || return 0
  REPORT_DONE=1
  if (( result != 0 )); then
    printf '  [FAIL] %s\n' "$CURRENT_TEST" >&2
    FAILED=$((FAILED + 1))
  fi
  printf '\n==============================================\n'
  printf 'Tests: %d | Passed: %d | Failed: %d\n' "$((PASSED + FAILED))" "$PASSED" "$FAILED"
  if (( FAILED == 0 )); then printf 'FINAL RESULT: PASS\n'; else printf 'FINAL RESULT: FAIL\n'; fi
  printf '==============================================\n'
}
cleanup_paths=()
cleanup() {
  local path
  for path in "${cleanup_paths[@]}"; do rm -rf -- "$path"; done
}
trap 'status=$?; report_summary "$status"; cleanup' EXIT
printf '\nDockerLabCTL — Tests (offline)\n\n'
test_start 'Basic CLI smoke checks'

bash -n dockerlabctl.sh
bash dockerlabctl.sh --help | grep -q 'DockerLabCTL'
if bash dockerlabctl.sh list --sort nope >/dev/null 2>&1; then
  echo 'Expected invalid sort to fail' >&2; exit 1
fi
test_pass 'Reject invalid sort key'
if bash dockerlabctl.sh info >/dev/null 2>&1; then
  echo 'Expected missing machine name to fail' >&2; exit 1
fi
test_pass 'Reject missing required machine name'
tmpdir="$(mktemp -d)"
cleanup_paths+=("$tmpdir")
bash dockerlabctl.sh local -o "$tmpdir" | grep -q 'Local entries: 0'
if bash dockerlabctl.sh link Example --slug example >/dev/null 2>&1; then
  echo 'Expected removed --slug option to fail' >&2; exit 1
fi
test_pass 'Reject removed --slug option'
if ! grep -q '^readonly CACHE_TTL=86400$' dockerlabctl.sh; then
  echo 'Expected 24-hour catalog cache' >&2; exit 1
fi
test_pass '24-hour catalog cache'
if ! grep -Fqx 'CACHE_FILE="$CACHE_DIR/catalog"' dockerlabctl.sh; then
  echo 'Expected cache filename to be catalog' >&2; exit 1
fi
test_pass 'Cache filename is catalog'
for obsolete in listar buscar enlace descargar aleatoria locales --dificultad --categoria --colorear --descripcion --autor --limite --destino --actualizar --sobrescribir --forzar --ayuda; do
  if bash dockerlabctl.sh "$obsolete" >/dev/null 2>&1; then
    echo "Expected obsolete Spanish CLI alias to fail: $obsolete" >&2; exit 1
  fi
done
test_pass 'Reject obsolete Spanish CLI aliases' 
test_pass 'Basic CLI smoke checks' 
rm -rf -- "$tmpdir"

test_start 'Offline catalog and local progress checks'
root="$(mktemp -d)"
cleanup_paths+=("$root")
export XDG_CACHE_HOME="$root/cache"
mkdir -p "$XDG_CACHE_HOME/dockerlabs-bash"
output="$root/labs"
mkdir -p "$output"
cat > "$XDG_CACHE_HOME/dockerlabs-bash/catalog" <<'JSON'
{
  "updated_at": 1760000000,
  "machines": [
    {"id": 3, "name": "Beta Fixture", "difficulty": "Hard", "category": "Hacking Web", "author": "Author B", "date": "2026", "description": "Test SQL injection", "search_text": "Beta Fixture Test SQL injection"},
    {"id": 1, "name": "Analyst", "difficulty": "Easy", "category": "Hacking API", "author": "Author A", "date": "2026", "description": "Test JWT", "search_text": "Analyst Test JWT"},
    {"id": 2, "name": "Gamma Fixture", "difficulty": "Medium", "category": "Hacking Web", "author": "Author C", "date": "2026", "description": "Test XXE", "search_text": "Gamma Fixture Test XXE"}
  ]
}
JSON
# All catalog operations use the fresh fixture cache, not the network.
cli() { bash dockerlabctl.sh "$@" -o "$output"; }
fail() { echo "    Reason: $*" >&2; exit 1; }
assert_json() {
  local actual="$1" expr="$2"
  jq -e "$expr" <<< "$actual" >/dev/null || fail "JSON assertion failed: $expr"
}
all="$(cli list --json)"
assert_json "$all" 'length == 3 and .[0].name == "Analyst"'
test_pass 'Catalog list sorted by ID'
limited="$(cli list --json --limit 2)"
assert_json "$limited" 'length == 2 and .[1].name == "Gamma Fixture"'
test_pass 'JSON result limit'
by_name="$(cli name analyst --json)"
assert_json "$by_name" 'length == 1 and .[0].id == 1'
test_pass 'Search by name'
by_search="$(cli search sql --json)"
assert_json "$by_search" 'length == 1 and .[0].name == "Beta Fixture"'
test_pass 'Search across metadata'
by_difficulty="$(cli list -d medium --json)"
assert_json "$by_difficulty" 'length == 1 and .[0].id == 2'
test_pass 'Difficulty filter'
by_category="$(cli list -c "Hacking Web" --json)"
assert_json "$by_category" 'length == 2'
test_pass 'Category filter'
by_author="$(cli list -a "Author A" --json)"
assert_json "$by_author" 'length == 1 and .[0].id == 1'
test_pass 'Author filter'
by_sort="$(cli list -s difficulty --json)"
assert_json "$by_sort" '.[0].difficulty == "Easy" and .[2].difficulty == "Hard"'
test_pass 'Difficulty sort'
random_json="$(cli random --json -d easy)"
assert_json "$random_json" 'type == "array" and length == 1 and .[0].name == "Analyst"'
test_pass 'Random selection with one candidate'
cli search Analyst -t -b >/dev/null
test_pass 'Description and bold output'
cli list -r >/dev/null
test_pass 'Colored catalog output'

# Grouped short flags must work in any order, including the originally reported command.
cli name -b Analyst -rt >/dev/null
test_pass 'Grouped -rt with name -b Analyst'
# When the fixture has no matching name, no-match is allowed; -rt must still parse.
no_match_output="$(cli name -b api -rt 2>&1)" || no_match_code=$?
[[ $no_match_output != *'Unknown option'* ]] || fail 'Grouped -rt was rejected'
test_pass 'Original -b api -rt syntax is recognized'
cli search Analyst -tr >/dev/null
test_pass 'Grouped short flags in reverse order -tr'
cli search Analyst -brt >/dev/null
test_pass 'Grouped -brt (bold, color, description)'
group_attached="$(cli list -rdmedium --json)"
assert_json "$group_attached" 'length == 1 and .[0].name == "Gamma Fixture"'
test_pass 'Grouped flag with attached argument -rdmedium'
group_separate="$(cli list -rd medium --json)"
assert_json "$group_separate" 'length == 1 and .[0].name == "Gamma Fixture"'
test_pass 'Grouped flag with separate argument -rd medium'
group_completed="$(cli list -rpno --json)"
assert_json "$group_completed" 'length == 3'
test_pass 'Grouped -rpno (catalog completion filter)'
if cli list -rx >/dev/null 2>&1; then
  fail 'Unknown clustered flag -x must be rejected'
fi
test_pass 'Reject unknown short flag inside cluster'


cli info 1 | grep 'Analyst' >/dev/null || fail 'info by ID'
test_pass 'Info lookup by ID'
cli link 1 | grep '/analyst.zip' >/dev/null || fail 'link by ID'
test_pass 'Archive URL lookup'
if cli progress done 'Analyst' --local >/dev/null 2>&1; then fail 'removed --local must be rejected'; fi
test_pass 'Reject removed --local option'
if cli progress fetch all 'Analyst' >/dev/null 2>&1; then fail 'fetch all with extra names must be rejected'; fi
test_pass 'Reject fetch all with machine name'
if cli progress push all 'Analyst' >/dev/null 2>&1; then fail 'push all with extra names must be rejected'; fi
test_pass 'Reject push all with machine name'
if cli progress done 'Analyst' -p >/dev/null 2>&1; then fail '-p should require authenticated cookie'; fi
test_pass 'Remote push requires authentication'
cli progress done 'Analyst' > /dev/null
grep -q 'Analyst' <<< "$(cli progress list)" || fail 'progress list'
test_pass 'Mark machine locally'
[[ $(cli progress list local) == *Analyst* ]] || fail 'explicit local list must show Analyst'
test_pass 'Explicit local progress list'
if cli progress list something >/dev/null 2>&1; then fail 'invalid progress list mode should be rejected'; fi
test_pass 'Reject invalid progress list mode'
if cli progress list both >/dev/null 2>&1; then fail 'compare listing should require authentication'; fi
test_pass 'Comparison list requires authentication'
done_records="$(cli list -p yes --json)"
assert_json "$done_records" 'length == 1 and .[0].name == "Analyst"'
test_pass 'Filter completed machines'
undone_records="$(cli list -p no --json)"
assert_json "$undone_records" 'length == 2'
test_pass 'Filter unfinished machines'
cli progress undone 'Analyst' > /dev/null
assert_json "$(cli list -p yes --json)" 'length == 0'
test_pass 'Unmark machine locally'
# Local command must not require a remote catalog.
touch "$output/example.zip"
grep -q 'example' <<< "$(cli local)" || fail 'local ZIP listing'
test_pass 'List ZIPs without network'
cli progress done all > /dev/null
grep -q 'YES' <<< "$(cli local)" || fail 'progress done all'
test_pass 'Mark all local machines'
cli progress undone all > /dev/null
grep -q 'No' <<< "$(cli local)" || fail 'progress undone all'
test_pass 'Unmark all local machines'
# -p with an unknown local archive must fail before any website changes.
if cli progress done all -p --cookie-file '$root/cookie' >/dev/null 2>&1; then fail 'unknown local machine with -p must fail'; fi
test_pass 'Reject unknown machine before remote mutation'
cli remove example --yes > /dev/null 2>&1
[[ ! -e $output/example.zip ]] || fail 'remove local ZIP'
test_pass 'Remove downloaded ZIP'
# Completed offline catalog suite.

test_start 'Mock profile integration checks'
# Simulate the authenticated webpage and both completion APIs without network.
mkdir -p "$root/mock-bin"
cat > "$root/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
config='' output='' data='' url='' method=GET
while (( $# )); do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --data-binary) data="$2"; shift 2 ;;
    --url) url="$2"; shift 2 ;;
    --request) method="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -f $config ]] || exit 8
grep -F 'cookie = "session=test-session; cf_clearance=test-clearance"' "$config" >/dev/null || exit 9
if [[ $url == 'https://dockerlabs.es/' ]]; then
  printf '<html><head><meta name="csrf-token" content="test-token"></head></html>\n' > "$output"
elif [[ $url == *'/api/completed_machines/'* ]]; then
  grep -F 'header = "X-CSRFToken: test-token"' "$config" >/dev/null || exit 10
  if [[ $url != */Analyst ]]; then value=false; elif [[ -n ${MOCK_REMOTE:-} ]]; then value="$MOCK_REMOTE"; else value="$(cat "${MOCK_STATE_FILE}")"; fi
  printf '{"completed":%s}\n' "$value" > "$output"
elif [[ $url == *'/api/toggle_completed_machine' ]]; then
  grep -F 'header = "X-CSRFToken: test-token"' "$config" >/dev/null || exit 10
  [[ -f ${data#@} ]] || exit 11
  jq -e '.machine_name == "Analyst"' "${data#@}" >/dev/null || exit 11
  if [[ $(cat "${MOCK_STATE_FILE}") == true ]]; then value=false; else value=true; fi
  value="${MOCK_TOGGLED:-$value}"
  printf '%s' "$value" > "${MOCK_STATE_FILE}"
  printf '{"success":true,"completed":%s}\n' "$value" > "$output"
else
  exit 12
fi
printf '%s' "${MOCK_HTTP_STATUS:-200}"
MOCK
chmod +x "$root/mock-bin/curl"
printf '%s\n' 'Cookie: session=test-session; cf_clearance=test-clearance' > "$root/cookie"
chmod 600 "$root/cookie"
export MOCK_STATE_FILE="$root/remote-state"
printf false > "$MOCK_STATE_FILE"
profile_cli() { PATH="$root/mock-bin:$PATH" bash dockerlabctl.sh progress "$@" -o "$output" --cookie-file "$root/cookie"; }
profile_cli done 'Analyst' -p | grep -q 'local + website' || fail '-p automatic CSRF + completion'
test_pass 'Automatic CSRF and -p remote update'
# Read-only remote listing and comparison must not change local or remote state.
remote_before="$(cat "$MOCK_STATE_FILE")"
remote_output="$(profile_cli list remote)"; [[ $remote_output == *Analyst* ]] || fail "remote listing should show completed Analyst: $remote_output"
test_pass 'List completed machines from profile'
compare_out="$(profile_cli list both)"
grep -q 'Analyst' <<< "$compare_out" || fail 'comparison must show Analyst'
grep -q 'Differences: 0' <<< "$compare_out" || fail 'matching local and profile states should have zero differences'
test_pass 'Compare matching local and profile progress'
[[ $(cat "$MOCK_STATE_FILE") == "$remote_before" ]] || fail 'read-only listing changed profile state'
test_pass 'Remote progress listing does not modify profile'
cli progress undone Analyst >/dev/null
compare_out="$(profile_cli list both)"
grep -q 'DIFFERENT' <<< "$compare_out" || fail 'comparison must show remote-only completion'
grep -q 'Differences: 1' <<< "$compare_out" || fail 'comparison difference count must be 1'
test_pass 'Detect completed remotely but not locally'
[[ $(profile_cli list remote) == *Analyst* ]] || fail 'remote list should ignore local state'
test_pass 'Remote progress listing ignores local marks'
[[ $(cat "$MOCK_STATE_FILE") == true ]] || fail 'remote list changed profile status'
profile_cli done Analyst -p >/dev/null
printf false > "$MOCK_STATE_FILE"
compare_out="$(profile_cli list both)"
grep -q 'DIFFERENT' <<< "$compare_out" || fail 'comparison must show local-only completion'
grep -q 'Differences: 1' <<< "$compare_out" || fail 'comparison difference count must be 1'
test_pass 'Detect completed locally but not remotely'
profile_cli list remote | grep -q 'Total: 0' || fail 'empty remote profile should list no completed machines'
test_pass 'List profile with no completed machines'
if MOCK_HTTP_STATUS=403 profile_cli list remote >/dev/null 2>&1; then fail 'remote status failure must fail listing'; fi
test_pass 'Reject remote listing when profile API returns HTTP error'
printf true > "$MOCK_STATE_FILE"
profile_cli done 'Analyst' --push | grep -q 'local + website' || fail '--push alias should work'
test_pass '--push long alias'
grep -Fqx analyst "$output/.dockerlabs-done" || fail 'local state not updated'
test_pass 'Authenticated mark updates local state'
profile_cli done 'Analyst' -p | grep -q 'local + website' || fail 'repeat done should be safe'
profile_cli done 'Analyst' -p | grep 'already true' >/dev/null || fail 'no toggling of already completed'
test_pass 'Idempotent remote done'
profile_cli fetch 'Analyst' | grep -q 'Fetched' || fail 'fetch both completed'
test_pass 'Fetch remote state'
if profile_cli fetch 'Analyst' -p >/dev/null 2>&1; then fail '-p should be rejected for progress fetch'; fi
test_pass 'Reject -p with fetch'
profile_cli undone 'Analyst' -p | grep -q 'local + website' || fail '-p undone remote'
test_pass 'Authenticated remote undone'
# Remote-only completion must be imported into local progress.
printf true > "$MOCK_STATE_FILE"
cli progress undone 'Analyst' > /dev/null
profile_cli fetch 'Analyst' > /dev/null
grep -Fqx analyst "$output/.dockerlabs-done" || fail 'remote-only completion was not imported'
test_pass 'Fetch remote-only completion'
# Local-only completion must be cleared because the website is authoritative.
printf false > "$MOCK_STATE_FILE"
profile_cli fetch 'Analyst' > /dev/null
[[ $(cat "$MOCK_STATE_FILE") == false ]] || fail 'sync should not modify website completion'
if grep -Fqx analyst "$output/.dockerlabs-done"; then fail 'local completion should be cleared by website sync'; fi
test_pass 'Remote priority clears local-only completion'
# Repeating sync must not toggle an already completed machine.
profile_cli fetch 'Analyst' > /dev/null
[[ $(cat "$MOCK_STATE_FILE") == false ]] || fail 'repeat sync changed website completion state'
if MOCK_HTTP_STATUS=403 profile_cli done 'Analyst' -p > /dev/null 2>&1; then
  fail 'remote HTTP 403 must fail'
fi
chmod 644 "$root/cookie"
if profile_cli done 'Analyst' -p > /dev/null 2>&1; then
  fail 'insecure cookie permissions must be rejected'
fi
chmod 600 "$root/cookie"
# Missing CSRF must fail closed, not mutate local progress.
# Local updates must not touch the website even if a cookie exists.
profile_cli done 'Analyst' > /dev/null
[[ $(cat "$MOCK_STATE_FILE") == false ]] || fail 'default done must remain local-only'
profile_cli push 'Analyst' | grep -q 'Pushed' || fail 'push should use local completion'
[[ $(cat "$MOCK_STATE_FILE") == true ]] || fail 'push failed to mark remote'
test_pass 'Push local completion remotely'
profile_cli undone 'Analyst' > /dev/null
[[ $(cat "$MOCK_STATE_FILE") == true ]] || fail 'default undone must remain local-only'
profile_cli push 'Analyst' > /dev/null
[[ $(cat "$MOCK_STATE_FILE") == false ]] || fail 'push failed to unmark remote'
test_pass 'Push local uncompletion remotely'
# Remote failure during explicit -p must leave local state unchanged.
if MOCK_HTTP_STATUS=403 profile_cli done 'Analyst' -p > /dev/null 2>&1; then fail 'remote error on -p should fail'; fi
if grep -Fqx analyst "$output/.dockerlabs-done"; then fail 'failed -p changed local progress'; fi
# Removed sync and -s shorthand are rejected.
if profile_cli sync 'Analyst' >/dev/null 2>&1; then fail 'old sync should be rejected'; fi
test_pass 'Reject removed sync command'
if profile_cli done 'Analyst' -s >/dev/null 2>&1; then fail 'old -s should be rejected'; fi
test_pass 'Reject removed -s progress flag'
# Deprecated command checks are reported individually above.
# Completed profile mock suite.
