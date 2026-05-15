#!/usr/bin/env bash
# bp_smoke.sh — CLI surface test for the bp RPN calculator.
#
# Per CLAUDE.md: CLI surface gets a Bash test in the master `./test` runner.
# Tests both ARGV-token and stdin forms; covers number parsing, arithmetic,
# the headline IEEE754-disruption demo, the no-silent-rounding error path,
# stack ops, and combinatorial functions.
#
# Run from repo root via ./test (which sets BP_BIN). Standalone:
#   BP_BIN=./result/bin/bp ./tests/cli/bp_smoke.sh

set -u  # NOT errexit — tests need to capture non-zero exits explicitly

BP="${BP_BIN:-./result/bin/bp}"
if [[ ! -x "$BP" ]]; then
	echo "FAIL: bp binary not found at $BP — run nix build first" >&2
	exit 1
fi

failures=0
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1" >&2; failures=$((failures + 1)); }

# Helper: assert `bp ARGS` produces stdout EXACTLY $expected.
assert_argv() {
	local desc="$1"
	local expected="$2"
	shift 2
	local actual
	actual=$("$BP" "$@" 2>/dev/null)
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc — expected '$expected', got '$actual'"
	fi
}

# Helper: assert stdin form produces stdout EXACTLY $expected.
assert_stdin() {
	local desc="$1"
	local expected="$2"
	local input="$3"
	local actual
	actual=$(echo "$input" | "$BP" 2>/dev/null)
	if [[ "$actual" == "$expected" ]]; then
		pass "$desc"
	else
		fail "$desc — expected '$expected', got '$actual'"
	fi
}

# Helper: assert `bp ARGS` exits NON-ZERO (with whatever rc).
assert_argv_fails() {
	local desc="$1"
	shift
	"$BP" "$@" >/dev/null 2>&1
	local rc=$?
	if (( rc != 0 )); then
		pass "$desc"
	else
		fail "$desc — expected non-zero exit, got 0"
	fi
}

echo "=== bp CLI smoke test ==="

# Basic literals.
assert_argv "literal integer" "42" 42
assert_argv "literal decimal" "3.14" 3.14
assert_argv "literal negative" "-7" -7

# Arithmetic.
assert_argv "1 + 2" "3" 1 2 +
assert_argv "5 - 3" "2" 5 3 -
assert_argv "6 * 7" "42" 6 7 '*'
assert_argv "1 / 4" "0.25" 1 4 /
assert_argv "8 % 3" "2" 8 3 %
assert_argv "2 ^ 10" "1024" 2 10 '^'

# Headline IEEE754 disruption demo.
assert_argv "0.1 + 0.2 == 0.3 (exact via CLI)" "0.3" 0.1 0.2 +
assert_argv "(0.1+0.2)-0.3 == 0 (the proof)" "0" 0.1 0.2 + 0.3 -

# Non-terminating div errors out.
assert_argv_fails "22/7 errors (no silent rounding)" 22 7 /

# Stack ops.
assert_argv "dup makes 5 5 → 25" "25" 5 dup '*'
assert_argv "swap reverses 3 5 → 5/3 errors but order matters" "5" 3 5 swap drop

# Combinatorial.
assert_argv "5! = 120" "120" 5 factorial
assert_argv "5! via ! alias" "120" 5 '!'
assert_argv "fib(10) = 55" "55" 10 fib
assert_argv "fib(100) = the 21-digit value" "354224848179261915075" 100 fib
assert_argv "binomial(50, 25)" "126410606437752" 50 25 binomial

# Number theory.
assert_argv "gcd(48, 18) = 6" "6" 48 18 gcd
assert_argv "lcm(4, 6) = 12" "12" 4 6 lcm
assert_argv "isqrt(100) = 10" "10" 100 isqrt
assert_argv "sqrt alias" "10" 100 sqrt

# Sign / abs.
assert_argv "abs(-5) = 5" "5" -5 abs
assert_argv "neg(7) = -7" "-7" 7 neg

# Stdin form.
assert_stdin "stdin: 1 2 + → 3" "3" "1 2 +"
assert_stdin "stdin: multi-line OK" "12" "3 4
+ 5 +"
assert_stdin "stdin: the disruption demo" "0.3" "0.1 0.2 +"

# Larger numbers — confirm we route through tier-3 cleanly.
assert_argv "20! large value" "2432902008176640000" 20 factorial
assert_argv "35! × 24!" "6411185140617356991862832318891262798817305298993152000000000000" 35 factorial 24 factorial '*'

# --help and --about don't crash.
# Forth-style ':' definitions (Phase 2).
assert_argv "': square dup * ;' then 5 square → 25" "25" : square dup '*' ';' 5 square
assert_argv "': cube ... ;' composes existing user word" "27" \
	: square dup '*' ';' \
	: cube dup square '*' ';' \
	3 cube
assert_argv "literal in definition body — ': tau 6.28 ;'" "6.28" : tau 6.28 ';' tau
assert_argv "definition uses literal + builtin together" "10" \
	: ten 5 5 + ';' ten
assert_argv "definition shadows a builtin (override !)" "999" \
	: '!' drop 999 ';' 5 '!'
assert_argv "shadowed builtin's old binding survives in EARLIER definitions" "120" \
	: real-fact '!' ';' \
	: '!' drop 999 ';' \
	5 real-fact

# ':' / ';' error paths.
assert_argv_fails "unterminated ':' definition errors" : foo 5
assert_argv_fails "';' outside definition errors" 5 ';'
assert_argv_fails "nested ':' errors" : foo : bar ';' ';'
assert_argv_fails "compile-time unknown token errors" : foo zomgwtf ';' foo

# Stdin form definition + use.
assert_stdin "stdin: define + invoke" "100" \
	": square dup * ;
10 square"

"$BP" --help >/dev/null 2>&1 && pass "--help exits 0" || fail "--help"
"$BP" --about >/dev/null 2>&1 && pass "--about exits 0" || fail "--about"
"$BP" --version >/dev/null 2>&1 && pass "--version exits 0" || fail "--version"

# Unknown token errors.
assert_argv_fails "unknown token errors" zomg

echo
if (( failures == 0 )); then
	echo "bp_smoke: all checks passed"
	exit 0
fi
echo "bp_smoke: $failures failure(s)" >&2
exit 1
