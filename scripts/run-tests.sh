#!/usr/bin/env bash
#
# run-tests.sh — one entry point for every test and check in scripts/.
#
# CI calls this with a suite name and contributors run the same command, so the
# list of tests lives in one place. Before this the list existed only as
# workflow steps, and scripts/test-hermes-plugin.py was never run by any of them.
#
# Suites, and the workflow that runs each one:
#   checks   consistency checks and small regression tests   check-tools.yml
#   outputs  regenerate every tool's output and verify it     check-tools.yml
#   install  installer behaviour, and `bash -n` on scripts    test-install.yml
#   roster   lint and originality across the whole roster     lint-agents.yml
#
# Usage:
#   ./scripts/run-tests.sh                   every suite (about 8 minutes)
#   ./scripts/run-tests.sh checks install    only the named suites
#   ./scripts/run-tests.sh --fast            skip the slow tests (under a minute)
#   ./scripts/run-tests.sh --list            print the registered tests and exit
#   ./scripts/run-tests.sh --drift=advisory  passed through to test-convert-outputs.sh
#   ./scripts/run-tests.sh --verbose         print every test's output, not only failures
#
# Every scripts/test-* and scripts/check-* file must be registered in TESTS or
# listed in HELPERS with the reason it is not run directly. An unregistered file
# fails the run, so a new test cannot land without CI running it.
#
# A failing test does not stop the run: every selected test runs, then the
# summary names the failures and the exit status is 1. Runs on bash 3.2 (macOS)
# and 5 (Linux).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# suite|speed|name|command
# `name` is the file under scripts/ (or a label). An empty `command` runs the
# file with bash or python3; otherwise `command` is eval'd from the repo root.
# `slow` marks anything over ~15s; --fast skips those.
# shellcheck disable=SC2016  # $OUTPUTS_ARGS is meant to expand when eval'd
TESTS=(
  'checks|fast|check-divisions.sh|'
  'checks|fast|check-runbooks.sh|'
  'checks|fast|check-tools.sh|'
  'checks|fast|check-hermes-config-rewrite.sh|'
  'checks|fast|check-hermes-plugin.py|'
  'checks|fast|test-hermes-plugin.py|hermes_plugin_runtime'
  'checks|slow|test-convert-frontmatter.sh|'
  'checks|fast|test-convert-slug-collisions.sh|'
  'checks|fast|test-convert-symlink-output.sh|'
  'checks|fast|test-convert-parallel-failure.sh|'
  'checks|fast|test-convert-fence-model.sh|'
  'checks|fast|test-frontmatter-closing.sh|'
  'checks|fast|test-lint-fences.sh|'
  'checks|fast|test-folded-frontmatter.sh|'
  'checks|fast|test-lint-qwen-placeholders.sh|'
  'outputs|slow|test-convert-outputs.sh|bash scripts/test-convert-outputs.sh $OUTPUTS_ARGS'
  'install|fast|shell syntax (bash -n)|shell_syntax'
  'install|slow|test-install.sh|'
  'install|slow|test-agent-selection.sh|'
  'install|fast|test-cli-usage.sh|'
  'install|fast|test-install-openclaw-registration.sh|'
  'install|fast|test-install-link-ownership.sh|'
  'install|fast|test-install-parallel-logs.sh|'
  'install|fast|test-install-hermes-destination.sh|'
  'install|fast|test-install-conversion-failure.sh|'
  'install|fast|test-install-all-path-collision.sh|'
  'install|fast|test-install-selection-completeness.sh|'
  'install|fast|test-install-continue-after-failure.sh|'
  'roster|slow|lint-agents.sh|'
  'roster|slow|check-agent-originality.sh|'
)

# name|reason — scripts/test-* and scripts/check-* files that are not run directly.
HELPERS=(
  'check-hermes-config-rewrite.py|driven by check-hermes-config-rewrite.sh'
)

ALL_SUITES="checks outputs install roster"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

# --- commands that are more than "run this file" ------------------------------

# The router's runtime tests need a built plugin. Build one into a temp dir so
# the run never touches the generated output in integrations/.
hermes_plugin_runtime() {
  local out status
  out="$(mktemp -d "${TMPDIR:-/tmp}/agency-hermes-runtime.XXXXXX")" || return 1
  bash scripts/convert.sh --tool hermes --out "$out" \
    && AGENCY_HERMES_PLUGIN="$out/hermes/agency-agents-router/__init__.py" \
      python3 scripts/test-hermes-plugin.py
  status=$?
  rm -rf "$out"
  return $status
}

shell_syntax() {
  local f status=0
  for f in scripts/*.sh; do
    bash -n "$f" || { echo "syntax error: $f"; status=1; }
  done
  [[ $status -eq 0 ]] && echo "All scripts/*.sh parse with $(bash -c 'echo "$BASH_VERSION"')."
  return $status
}

# --- registry check -----------------------------------------------------------

registered_names() {
  local entry suite speed name
  for entry in "${TESTS[@]}"; do
    IFS='|' read -r suite speed name _ <<< "$entry"
    printf '%s\n' "$name"
  done
  for entry in "${HELPERS[@]}"; do printf '%s\n' "${entry%%|*}"; done
}

check_registry() {
  local names f name errors=0
  names="$(registered_names)"
  for f in scripts/test-* scripts/check-*; do
    [[ -f "$f" ]] || continue
    # A here-string, not a pipe: grep -q exits at the first match and would
    # leave the writer to die of SIGPIPE, which pipefail reports as a failure.
    if ! grep -qxF -- "${f#scripts/}" <<< "$names"; then
      echo "ERROR $f is not registered in scripts/run-tests.sh."
      echo "      Add it to TESTS so CI runs it, or to HELPERS with the reason it does not run directly."
      errors=$((errors + 1))
    fi
  done
  while IFS= read -r name; do
    case "$name" in *.sh|*.py) ;; *) continue ;; esac
    [[ -f "scripts/$name" ]] || {
      echo "ERROR scripts/run-tests.sh registers $name, which does not exist."
      errors=$((errors + 1))
    }
  done <<< "$names"
  [[ $errors -eq 0 ]] && echo "Every scripts/test-* and scripts/check-* file is registered."
  [[ $errors -eq 0 ]]
}

# --- arguments ----------------------------------------------------------------

SUITES=""
FAST=false
LIST=false
VERBOSE=false
OUTPUTS_ARGS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    checks|outputs|install|roster) SUITES="$SUITES $1" ;;
    --fast)      FAST=true ;;
    --list)      LIST=true ;;
    -v|--verbose) VERBOSE=true ;;
    --drift=*)
      # shellcheck disable=SC2034  # read by the eval'd test-convert-outputs.sh command
      OUTPUTS_ARGS="$1" ;;
    -h|--help)   usage; exit 0 ;;
    *)
      echo "Unknown option or suite: $1" >&2
      echo "" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done
[[ -n "$SUITES" ]] || SUITES=" $ALL_SUITES"

selected() {  # selected <suite> <speed>
  case "$SUITES " in *" $1 "*) ;; *) return 1 ;; esac
  ! { $FAST && [[ "$2" == slow ]]; }
}

if $LIST; then
  for entry in "${TESTS[@]}"; do
    IFS='|' read -r suite speed name _ <<< "$entry"
    selected "$suite" "$speed" && printf '%-8s %-5s %s\n' "$suite" "$speed" "$name"
  done
  exit 0
fi

# --- run ----------------------------------------------------------------------

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agency-run-tests.XXXXXX")"
trap 'rm -rf "$LOG_DIR"' EXIT
IN_ACTIONS=false
[[ "${GITHUB_ACTIONS:-}" == true ]] && IN_ACTIONS=true

passed=0
failed=0
failures=""
count=0
run_start=$SECONDS

# report <name> <status> <seconds> <log>
report() {
  local name="$1" status="$2" secs="$3" log="$4"
  if [[ $status -eq 0 ]]; then
    passed=$((passed + 1))
    if $IN_ACTIONS; then
      echo "::group::ok   $name (${secs}s)"
      cat "$log"
      echo "::endgroup::"
    else
      printf '  ok   %s (%ss)\n' "$name" "$secs"
      $VERBOSE && sed 's/^/       /' "$log"
    fi
  else
    failed=$((failed + 1))
    failures="$failures$name (exit $status)"$'\n'
    $IN_ACTIONS && echo "::error title=$name failed::exit $status — its output follows"
    printf '  FAIL %s (%ss, exit %s)\n' "$name" "$secs" "$status"
    sed 's/^/       /' "$log"
  fi
}

echo "Running:$SUITES$($FAST && echo ' (fast)')"
echo "  bash $BASH_VERSION, $(python3 --version 2>&1)"
echo ""

log="$LOG_DIR/registry.log"
check_registry > "$log" 2>&1
report "registry: every test is registered" $? 0 "$log"

for entry in "${TESTS[@]}"; do
  IFS='|' read -r suite speed name cmd <<< "$entry"
  selected "$suite" "$speed" || continue
  if [[ -z "$cmd" ]]; then
    case "$name" in
      *.py) cmd="python3 scripts/$name" ;;
      *)    cmd="bash scripts/$name" ;;
    esac
  fi
  count=$((count + 1))
  log="$LOG_DIR/$count.log"
  [[ -t 1 ]] && ! $IN_ACTIONS && printf '  ...  %s\r' "$name"
  start=$SECONDS
  ( eval "$cmd" ) < /dev/null > "$log" 2>&1
  status=$?
  [[ -t 1 ]] && ! $IN_ACTIONS && printf '\033[K'
  report "$name" "$status" $((SECONDS - start)) "$log"
done

elapsed=$((SECONDS - run_start))
echo ""
echo "Results: $passed passed, $failed failed ($((elapsed / 60))m $((elapsed % 60))s)."
if [[ $failed -gt 0 ]]; then
  echo "Failed:"
  printf '%s' "$failures" | sed 's/^/  /'
  exit 1
fi
echo "PASSED"
