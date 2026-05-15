// bp — RPN calculator atop the blip_mp C FFI.
//
// Forth-style RPN: tokens are whitespace-separated; numeric tokens push onto
// the stack, named tokens pop arg(s) and push result. ALL values are
// arbitrary-precision exact rationals (the M14 Fp type, base=decimal). NO
// floating point — every operation is bit-exact or errors out (e.g. 22/7
// can't terminate in decimal, so `22 7 /` errors). Scale is unbounded.
//
// Architecture: dogfoods include/blip_mp.h. Per CLAUDE.md a Zig CLI that
// imports the Zig core directly is forbidden — the CLI tool MUST go through
// the same C FFI that downstream consumers will use.
//
// Usage:
//   bp 35 factorial 24 factorial \*       # ARGV-each-token form
//   echo "0.1 0.2 +" | bp                 # stdin form (no args = read stdin)
//   bp --help / --about / --version
//
// i18n stub: see operator table OPS[] and the .name_<lang> alias slots
// (currently only English populated; future locales plug in here).

#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "blip_mp.h"

#define BP_VERSION "0.1.0"
#define BP_NAME    "bp"

// ── Locale / i18n stub ────────────────────────────────────────────────────
// Per CLAUDE.md CLI conventions: groundwork only, English populated, others
// stubbed. Locale detection lookup order: --lang flag → BP_LANG env var →
// LANG env var → "en" fallback.

static const char *bp_lang = "en";

static void detect_lang(int argc, char **argv) {
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--lang") == 0 && i + 1 < argc) {
			bp_lang = argv[i + 1];
			return;
		}
	}
	const char *env = getenv("BP_LANG");
	if (env) { bp_lang = env; return; }
	env = getenv("LANG");
	if (env) {
		// Truncate "en_US.UTF-8" → "en" by copying first 2 chars to a static.
		static char buf[4];
		buf[0] = env[0];
		buf[1] = env[1];
		buf[2] = 0;
		bp_lang = buf;
		return;
	}
	// Default already "en".
}

// ── Stack of Fp handles ───────────────────────────────────────────────────
// Each entry is heap-allocated via blip_mp_fp_create and owned by the stack
// until explicitly popped. On error or exit we drain whatever's left.

typedef struct {
	blip_mp_fp_t **data;
	size_t len;
	size_t cap;
} Stack;

static Stack S = {0};

static int stack_push(blip_mp_fp_t *fp) {
	if (S.len == S.cap) {
		size_t new_cap = S.cap ? S.cap * 2 : 16;
		blip_mp_fp_t **new_data = realloc(S.data, new_cap * sizeof *new_data);
		if (!new_data) return -1;
		S.data = new_data;
		S.cap = new_cap;
	}
	S.data[S.len++] = fp;
	return 0;
}

static blip_mp_fp_t *stack_pop(void) {
	if (S.len == 0) return NULL;
	return S.data[--S.len];
}

static blip_mp_fp_t *stack_peek(size_t depth_from_top) {
	if (depth_from_top >= S.len) return NULL;
	return S.data[S.len - 1 - depth_from_top];
}

static void stack_drain(void) {
	while (S.len > 0) blip_mp_fp_destroy(stack_pop());
	free(S.data);
	S.data = NULL;
	S.cap = 0;
}

// ── Helpers ───────────────────────────────────────────────────────────────

static void die(const char *msg) {
	fprintf(stderr, "bp: error: %s\n", msg);
	stack_drain();
	exit(2);
}

static void die_op(const char *op, const char *msg, int rc) {
	fprintf(stderr, "bp: %s: %s (rc=%d)\n", op, msg, rc);
	stack_drain();
	exit(2);
}

// Pop one argument; die if stack empty.
static blip_mp_fp_t *pop1(const char *op) {
	blip_mp_fp_t *x = stack_pop();
	if (!x) die_op(op, "stack underflow (need 1 arg)", 0);
	return x;
}

// Pop two arguments. Returns top in *b, second in *a (so for "a b op",
// b is the rightmost / top-of-stack, a is below).
static void pop2(const char *op, blip_mp_fp_t **a, blip_mp_fp_t **b) {
	*b = stack_pop();
	*a = stack_pop();
	if (!*a || !*b) {
		if (*b) blip_mp_fp_destroy(*b);
		if (*a) blip_mp_fp_destroy(*a);
		die_op(op, "stack underflow (need 2 args)", 0);
	}
}

// Convert an Fp value (assumed to be a non-negative integer fitting in u32)
// to u32 for ops like factorial / fibonacci. Errors on non-integer or out-of-range.
static uint32_t fp_to_u32(blip_mp_fp_t *fp, const char *op) {
	int32_t scale = blip_mp_fp_get_scale(fp);
	blip_mp_t *m = blip_mp_fp_get_mantissa(fp);
	// canonicalize first so trailing zeros in mantissa don't mask integer-ness
	int rc = blip_mp_fp_canonicalize(fp);
	if (rc != BLIP_MP_OK) die_op(op, "canonicalize failed", rc);
	scale = blip_mp_fp_get_scale(fp);
	if (scale < 0) die_op(op, "argument must be a non-negative integer", 0);
	if (blip_mp_sign(m) < 0) die_op(op, "argument must be non-negative", 0);
	// Lift mantissa by 10^scale to get the integer value, but for our use
	// scale=0 after canonicalize is the common case.
	if (scale == 0) {
		uint64_t v;
		rc = blip_mp_get_u64(m, &v);
		if (rc != BLIP_MP_OK) die_op(op, "argument doesn't fit in u64", rc);
		if (v > UINT32_MAX) die_op(op, "argument exceeds u32 range", 0);
		return (uint32_t)v;
	}
	// scale > 0: e.g. 5 × 10^2 = 500. Multiply mantissa accordingly.
	// Build a scratch Mp with the lifted value and read it back.
	blip_mp_t *lifted = blip_mp_create();
	if (!lifted) die_op(op, "OOM", 0);
	blip_mp_t *ten = blip_mp_create();
	blip_mp_t *acc = blip_mp_create();
	if (!ten || !acc) die_op(op, "OOM", 0);
	blip_mp_set_i64(ten, 10);
	blip_mp_set_i64(acc, 1);
	for (int32_t i = 0; i < scale; i++) blip_mp_mul(acc, acc, ten);
	blip_mp_mul(lifted, m, acc);
	uint64_t v;
	rc = blip_mp_get_u64(lifted, &v);
	blip_mp_destroy(ten);
	blip_mp_destroy(acc);
	blip_mp_destroy(lifted);
	if (rc != BLIP_MP_OK) die_op(op, "lifted argument doesn't fit in u64", rc);
	if (v > UINT32_MAX) die_op(op, "argument exceeds u32 range", 0);
	return (uint32_t)v;
}

// Wrap a fresh Mp result as an Fp (scale=0, base=decimal) for stack push.
static blip_mp_fp_t *mp_to_fp(blip_mp_t *src) {
	blip_mp_fp_t *out = blip_mp_fp_create();
	if (!out) return NULL;
	// Get bytes of src and stuff into out's mantissa via FFI.
	const uint8_t *bytes = blip_mp_bytes(src);
	size_t blen = blip_mp_byte_len(src);
	blip_mp_t *m = blip_mp_fp_get_mantissa(out);
	if (bytes && blen) blip_mp_set_bytes(m, bytes, blen);
	// Set Fp's scale=0, base=decimal via setI64 dance: re-init via set_i64(0)
	// then overwrite the mantissa. Actually simpler: use set_i64 with 0 to
	// initialize, then setBytes on the mantissa.
	// (The mantissa setBytes above already did the assignment; the create()
	// gave us scale=0, base=decimal defaults.)
	return out;
}

// ── Operator implementations ─────────────────────────────────────────────

static int op_add(const char *name) {
	blip_mp_fp_t *a, *b;
	pop2(name, &a, &b);
	blip_mp_fp_t *r = blip_mp_fp_create();
	int rc = blip_mp_fp_add(r, a, b);
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	if (rc != BLIP_MP_OK) { blip_mp_fp_destroy(r); die_op(name, "add failed", rc); }
	stack_push(r);
	return 0;
}

static int op_sub(const char *name) {
	blip_mp_fp_t *a, *b;
	pop2(name, &a, &b);
	blip_mp_fp_t *r = blip_mp_fp_create();
	int rc = blip_mp_fp_sub(r, a, b);
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	if (rc != BLIP_MP_OK) { blip_mp_fp_destroy(r); die_op(name, "sub failed", rc); }
	stack_push(r);
	return 0;
}

static int op_mul(const char *name) {
	blip_mp_fp_t *a, *b;
	pop2(name, &a, &b);
	blip_mp_fp_t *r = blip_mp_fp_create();
	int rc = blip_mp_fp_mul(r, a, b);
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	if (rc != BLIP_MP_OK) { blip_mp_fp_destroy(r); die_op(name, "mul failed", rc); }
	stack_push(r);
	return 0;
}

static int op_div(const char *name) {
	blip_mp_fp_t *a, *b;
	pop2(name, &a, &b);
	blip_mp_fp_t *r = blip_mp_fp_create();
	int rc = blip_mp_fp_div_exact(r, a, b);
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	if (rc == BLIP_MP_ERR_NON_TERMINATING) {
		blip_mp_fp_destroy(r);
		die_op(name, "result has no terminating decimal expansion (use precision-budget div in a future version)", rc);
	}
	if (rc != BLIP_MP_OK) { blip_mp_fp_destroy(r); die_op(name, "div failed", rc); }
	stack_push(r);
	return 0;
}

static int op_neg(const char *name) {
	blip_mp_fp_t *x = pop1(name);
	blip_mp_t *xm = blip_mp_fp_get_mantissa(x);
	blip_mp_t *negated = blip_mp_create();
	int rc = blip_mp_neg(negated, xm);
	if (rc != BLIP_MP_OK) { blip_mp_fp_destroy(x); blip_mp_destroy(negated); die_op(name, "neg failed", rc); }
	// Build new Fp with negated mantissa, same scale.
	blip_mp_fp_t *r = blip_mp_fp_create();
	int32_t scale = blip_mp_fp_get_scale(x);
	const uint8_t *bytes = blip_mp_bytes(negated);
	size_t blen = blip_mp_byte_len(negated);
	blip_mp_t *rm = blip_mp_fp_get_mantissa(r);
	if (bytes && blen) blip_mp_set_bytes(rm, bytes, blen);
	// Apply scale by re-setting via set_i64 + manual scale adjust isn't exposed;
	// for now negation only preserves scale via direct mantissa overwrite —
	// the create() default scale=0 only matches integers. For non-zero scale
	// we need a setter. Use the (mantissa=0, scale=scale, base=decimal) trick:
	blip_mp_fp_set_i64(r, 0, scale, BLIP_MP_FP_BASE_DECIMAL);
	if (bytes && blen) blip_mp_set_bytes(blip_mp_fp_get_mantissa(r), bytes, blen);
	blip_mp_destroy(negated);
	blip_mp_fp_destroy(x);
	stack_push(r);
	return 0;
}

static int op_abs(const char *name) {
	blip_mp_fp_t *x = pop1(name);
	if (blip_mp_sign(blip_mp_fp_get_mantissa(x)) >= 0) {
		stack_push(x);
		return 0;
	}
	// Negate.
	stack_push(x);
	op_neg(name);
	return 0;
}

// Stack manipulation Forth ops.
static int op_dup(const char *name) {
	(void)name;
	blip_mp_fp_t *top = stack_peek(0);
	if (!top) die_op("dup", "stack empty", 0);
	blip_mp_fp_t *copy = blip_mp_fp_create();
	const uint8_t *bytes = blip_mp_bytes(blip_mp_fp_get_mantissa(top));
	size_t blen = blip_mp_byte_len(blip_mp_fp_get_mantissa(top));
	int32_t scale = blip_mp_fp_get_scale(top);
	blip_mp_fp_set_i64(copy, 0, scale, BLIP_MP_FP_BASE_DECIMAL);
	if (bytes && blen) blip_mp_set_bytes(blip_mp_fp_get_mantissa(copy), bytes, blen);
	stack_push(copy);
	return 0;
}

static int op_drop(const char *name) {
	(void)name;
	blip_mp_fp_t *x = stack_pop();
	if (!x) die_op("drop", "stack empty", 0);
	blip_mp_fp_destroy(x);
	return 0;
}

static int op_swap(const char *name) {
	(void)name;
	if (S.len < 2) die_op("swap", "need 2 elements on stack", 0);
	blip_mp_fp_t *tmp = S.data[S.len - 1];
	S.data[S.len - 1] = S.data[S.len - 2];
	S.data[S.len - 2] = tmp;
	return 0;
}

// Combinatorial ops.
static int op_factorial(const char *name) {
	blip_mp_fp_t *x = pop1(name);
	uint32_t n = fp_to_u32(x, name);
	blip_mp_fp_destroy(x);
	blip_mp_t *r = blip_mp_create();
	int rc = blip_mp_factorial(r, n);
	if (rc != BLIP_MP_OK) { blip_mp_destroy(r); die_op(name, "factorial failed", rc); }
	stack_push(mp_to_fp(r));
	blip_mp_destroy(r);
	return 0;
}

static int op_fibonacci(const char *name) {
	blip_mp_fp_t *x = pop1(name);
	uint32_t n = fp_to_u32(x, name);
	blip_mp_fp_destroy(x);
	blip_mp_t *r = blip_mp_create();
	int rc = blip_mp_fibonacci(r, n);
	if (rc != BLIP_MP_OK) { blip_mp_destroy(r); die_op(name, "fibonacci failed", rc); }
	stack_push(mp_to_fp(r));
	blip_mp_destroy(r);
	return 0;
}

static int op_binomial(const char *name) {
	blip_mp_fp_t *kfp, *nfp;
	pop2(name, &nfp, &kfp);
	uint32_t k = fp_to_u32(kfp, name);
	uint32_t n = fp_to_u32(nfp, name);
	blip_mp_fp_destroy(kfp);
	blip_mp_fp_destroy(nfp);
	blip_mp_t *r = blip_mp_create();
	int rc = blip_mp_binomial(r, n, k);
	if (rc != BLIP_MP_OK) { blip_mp_destroy(r); die_op(name, "binomial failed", rc); }
	stack_push(mp_to_fp(r));
	blip_mp_destroy(r);
	return 0;
}

static int op_isqrt(const char *name) {
	blip_mp_fp_t *x = pop1(name);
	int32_t scale = blip_mp_fp_get_scale(x);
	if (scale != 0) { blip_mp_fp_destroy(x); die_op(name, "isqrt requires integer argument", 0); }
	blip_mp_t *xm = blip_mp_fp_get_mantissa(x);
	blip_mp_t *r = blip_mp_create();
	int rc = blip_mp_isqrt(r, xm);
	blip_mp_fp_destroy(x);
	if (rc != BLIP_MP_OK) { blip_mp_destroy(r); die_op(name, "isqrt failed", rc); }
	stack_push(mp_to_fp(r));
	blip_mp_destroy(r);
	return 0;
}

static int op_gcd(const char *name) {
	blip_mp_fp_t *a, *b;
	pop2(name, &a, &b);
	if (blip_mp_fp_get_scale(a) != 0 || blip_mp_fp_get_scale(b) != 0) {
		blip_mp_fp_destroy(a); blip_mp_fp_destroy(b);
		die_op(name, "gcd requires integer arguments", 0);
	}
	blip_mp_t *r = blip_mp_create();
	int rc = blip_mp_gcd(r, blip_mp_fp_get_mantissa(a), blip_mp_fp_get_mantissa(b));
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	if (rc != BLIP_MP_OK) { blip_mp_destroy(r); die_op(name, "gcd failed", rc); }
	stack_push(mp_to_fp(r));
	blip_mp_destroy(r);
	return 0;
}

static int op_lcm(const char *name) {
	blip_mp_fp_t *a, *b;
	pop2(name, &a, &b);
	if (blip_mp_fp_get_scale(a) != 0 || blip_mp_fp_get_scale(b) != 0) {
		blip_mp_fp_destroy(a); blip_mp_fp_destroy(b);
		die_op(name, "lcm requires integer arguments", 0);
	}
	blip_mp_t *r = blip_mp_create();
	int rc = blip_mp_lcm(r, blip_mp_fp_get_mantissa(a), blip_mp_fp_get_mantissa(b));
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	if (rc != BLIP_MP_OK) { blip_mp_destroy(r); die_op(name, "lcm failed", rc); }
	stack_push(mp_to_fp(r));
	blip_mp_destroy(r);
	return 0;
}

static int op_mod(const char *name) {
	blip_mp_fp_t *a, *b;
	pop2(name, &a, &b);
	if (blip_mp_fp_get_scale(a) != 0 || blip_mp_fp_get_scale(b) != 0) {
		blip_mp_fp_destroy(a); blip_mp_fp_destroy(b);
		die_op(name, "% requires integer arguments", 0);
	}
	blip_mp_t *r = blip_mp_create();
	int rc = blip_mp_mod(r, blip_mp_fp_get_mantissa(a), blip_mp_fp_get_mantissa(b));
	blip_mp_fp_destroy(a);
	blip_mp_fp_destroy(b);
	if (rc != BLIP_MP_OK) { blip_mp_destroy(r); die_op(name, "mod failed", rc); }
	stack_push(mp_to_fp(r));
	blip_mp_destroy(r);
	return 0;
}

// Power: b a ^ → a^b. Uses repeated mul (so b must be a non-negative integer).
static int op_pow(const char *name) {
	blip_mp_fp_t *base, *exp;
	pop2(name, &base, &exp);
	uint32_t e = fp_to_u32(exp, name);
	blip_mp_fp_destroy(exp);
	// result = 1
	blip_mp_fp_t *result = blip_mp_fp_create();
	blip_mp_fp_set_i64(result, 1, 0, BLIP_MP_FP_BASE_DECIMAL);
	for (uint32_t i = 0; i < e; i++) {
		blip_mp_fp_t *next = blip_mp_fp_create();
		int rc = blip_mp_fp_mul(next, result, base);
		blip_mp_fp_destroy(result);
		if (rc != BLIP_MP_OK) {
			blip_mp_fp_destroy(next);
			blip_mp_fp_destroy(base);
			die_op(name, "mul during pow failed", rc);
		}
		result = next;
	}
	blip_mp_fp_destroy(base);
	stack_push(result);
	return 0;
}

// ── Op table ──────────────────────────────────────────────────────────────

typedef int (*op_fn)(const char *name);

typedef struct {
	const char *name_en;
	op_fn fn;
	const char *help;
	// i18n stub: future locales add .name_es, .name_fr, etc. here.
	// const char *name_es; const char *name_fr; ...
} Op;

static const Op OPS[] = {
	{"+", op_add, "(a b -- a+b)"},
	{"-", op_sub, "(a b -- a-b)"},
	{"*", op_mul, "(a b -- a*b)"},
	{"/", op_div, "(a b -- a/b — exact, errors if non-terminating decimal)"},
	{"%", op_mod, "(a b -- a mod b — integers only)"},
	{"^", op_pow, "(a b -- a^b — b must be non-negative integer)"},
	{"neg", op_neg, "(a -- -a)"},
	{"abs", op_abs, "(a -- |a|)"},
	{"dup", op_dup, "(a -- a a)"},
	{"drop", op_drop, "(a -- )"},
	{"swap", op_swap, "(a b -- b a)"},
	{"factorial", op_factorial, "(n -- n! — n must be non-negative integer)"},
	{"!", op_factorial, "(n -- n! — alias for factorial)"},
	{"fibonacci", op_fibonacci, "(n -- F(n) — fast-doubling)"},
	{"fib", op_fibonacci, "(n -- F(n) — alias)"},
	{"binomial", op_binomial, "(n k -- C(n,k))"},
	{"isqrt", op_isqrt, "(n -- floor(sqrt(n)) — integer only)"},
	{"sqrt", op_isqrt, "(n -- floor(sqrt(n)) — alias for isqrt)"},
	{"gcd", op_gcd, "(a b -- gcd(a,b))"},
	{"lcm", op_lcm, "(a b -- lcm(a,b))"},
	{NULL, NULL, NULL},
};

static int dispatch_op(const char *tok) {
	for (const Op *op = OPS; op->name_en; op++) {
		if (strcmp(tok, op->name_en) == 0) {
			return op->fn(tok);
		}
	}
	return -1; // unknown
}

// ── Token parsing ─────────────────────────────────────────────────────────

// Returns 1 if `tok` parses as a number literal (and pushes), 0 if not.
static int try_push_number(const char *tok) {
	if (!*tok) return 0;
	// Quick reject: must start with digit, '-', '+', or '.'
	if (!(isdigit((unsigned char)tok[0]) || tok[0] == '-' || tok[0] == '+' || tok[0] == '.')) {
		return 0;
	}
	// If "-" alone, that's the subtraction op, not a number.
	if ((tok[0] == '-' || tok[0] == '+') && tok[1] == 0) return 0;
	blip_mp_fp_t *fp = blip_mp_fp_create();
	if (!fp) die("OOM");
	int rc = blip_mp_fp_set_str(fp, tok, strlen(tok), BLIP_MP_FP_BASE_DECIMAL);
	if (rc != BLIP_MP_OK) {
		blip_mp_fp_destroy(fp);
		return 0;
	}
	stack_push(fp);
	return 1;
}

static void process_token(const char *tok) {
	if (!tok || !*tok) return;
	if (try_push_number(tok)) return;
	if (dispatch_op(tok) == 0) return;
	char buf[256];
	snprintf(buf, sizeof buf, "unknown token '%s'", tok);
	die(buf);
}

// ── Output ────────────────────────────────────────────────────────────────

static void print_top(void) {
	blip_mp_fp_t *top = stack_peek(0);
	if (!top) return;
	blip_mp_fp_canonicalize(top);
	size_t need = 0;
	int rc = blip_mp_fp_to_string_canonical(top, NULL, 0, &need);
	if (rc != BLIP_MP_OK && rc != BLIP_MP_ERR_BUFFER_TOO_SMALL) {
		die_op("print", "to_string failed", rc);
	}
	char *buf = malloc(need + 1);
	if (!buf) die("OOM");
	rc = blip_mp_fp_to_string_canonical(top, buf, need + 1, &need);
	if (rc != BLIP_MP_OK) { free(buf); die_op("print", "to_string failed", rc); }
	buf[need] = 0;
	puts(buf);
	free(buf);
}

// ── stdin reader ──────────────────────────────────────────────────────────

static void process_stdin(void) {
	char buf[4096];
	char tok[1024];
	size_t tok_len = 0;
	while (fgets(buf, sizeof buf, stdin)) {
		for (char *p = buf; *p; p++) {
			if (isspace((unsigned char)*p)) {
				if (tok_len > 0) {
					tok[tok_len] = 0;
					process_token(tok);
					tok_len = 0;
				}
			} else {
				if (tok_len + 1 >= sizeof tok) die("token too long");
				tok[tok_len++] = *p;
			}
		}
	}
	if (tok_len > 0) {
		tok[tok_len] = 0;
		process_token(tok);
	}
}

// ── Help / about / version ────────────────────────────────────────────────

static void print_about(void) {
	printf("%s %s — RPN arbitrary-precision exact-arithmetic calculator (blip_mp)\n", BP_NAME, BP_VERSION);
}

static void print_help(void) {
	print_about();
	printf("\nUsage:\n");
	printf("  %s TOKEN [TOKEN ...]   evaluate an RPN expression from argv\n", BP_NAME);
	printf("  %s                     read tokens from stdin (whitespace-separated)\n", BP_NAME);
	printf("  echo \"...\" | %s        pipe form\n", BP_NAME);
	printf("\nOptions:\n");
	printf("  --help     print this help\n");
	printf("  --about    one-line version + platform\n");
	printf("  --version  same as --about\n");
	printf("  --lang LC  override locale (default: detect from BP_LANG / LANG)\n");
	printf("\nOperators:\n");
	for (const Op *op = OPS; op->name_en; op++) {
		printf("  %-12s %s\n", op->name_en, op->help);
	}
	printf("\nExamples:\n");
	printf("  %s 35 factorial 24 factorial \\*\n", BP_NAME);
	printf("  echo \"0.1 0.2 +\" | %s\n", BP_NAME);
	printf("  %s 22 7 /         # error: non-terminating decimal\n", BP_NAME);
	printf("  %s 1 4 /          # ok: 0.25 (terminates)\n", BP_NAME);
	printf("\nAll arithmetic is BIT-EXACT — no IEEE754 rounding, no silent precision loss.\n");
}

// ── main ──────────────────────────────────────────────────────────────────

int main(int argc, char **argv) {
	detect_lang(argc, argv);
	// Suppress -Wunused-variable in builds where bp_lang isn't yet read by ops.
	(void)bp_lang;

	bool got_token = false;
	for (int i = 1; i < argc; i++) {
		const char *arg = argv[i];
		if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
			print_help();
			return 0;
		}
		if (strcmp(arg, "--about") == 0 || strcmp(arg, "--version") == 0) {
			print_about();
			return 0;
		}
		if (strcmp(arg, "--lang") == 0) {
			i++; // already consumed by detect_lang
			continue;
		}
		process_token(arg);
		got_token = true;
	}
	if (!got_token) {
		process_stdin();
	}
	print_top();
	stack_drain();
	return 0;
}
