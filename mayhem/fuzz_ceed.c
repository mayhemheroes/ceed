/*
 * mayhem/fuzz_ceed.c — in-process libFuzzer harness for the Ceed compiler.
 *
 * Ceed is a batch compiler: main() picks an output backend (elf_init / pe_init),
 * calls cmplr_init(), reads the source program from stdin via the flex scanner,
 * and drives yyparse(). The grammar's top rule runs emit_code() (the code
 * generator) and then free_sym() on the AST. This harness exercises that exact
 * path (lexer -> parser -> code generator into the fixed CODE/RDATA buffers)
 * against fuzzer-supplied source, which is where the interesting memory work
 * lives (emit8/16/32 bounds checks, add_str string handling, the AST walk).
 *
 * Two upstream design facts force a little glue, all of it additive:
 *
 *  1. The compiler reads the program from stdin. We instead hand the bytes to
 *     flex with yy_scan_bytes() so the whole thing runs in-process.
 *
 *  2. The compiler REPORTS ERRORS BY CALLING exit(-1) (unknown character,
 *     unimplemented "loop", CODE/RDATA size overflow, missing entry point, ...).
 *     In a one-shot process that is fine; for in-process fuzzing it would kill
 *     the worker on the first malformed input. We link with `-Wl,--wrap=exit`
 *     (set in mayhem/build.sh) and turn a mid-run exit() into a longjmp back
 *     here, so an ordinary compile error just ends the iteration.
 *
 * Because upstream tears down state by exiting the process, it never frees its
 * per-compilation allocations on an error path (the bison parse stack and any
 * partially-built AST). When we longjmp out instead of exiting, those show up
 * as leaks, so LeakSanitizer is disabled for this batch target via a weak
 * __asan_default_options baked into the binary (Mayhem owns the runtime
 * ASAN_OPTIONS, which does not override the baked default). ASan's checks
 * and UBSan remain on and halting — a real out-of-bounds write into the CODE or
 * RDATA buffer (or any UB) is still caught.
 *
 * The upstream CODE/RDATA position counters are file-static in ceedcmpl.c; we
 * compile that translation unit with `-Dstatic=` (in build.sh) so the harness
 * can reset them between iterations. No upstream source is modified.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <setjmp.h>

#include "ceed.h"

/* flex-generated entry points (from lex.yy.c). */
typedef struct yy_buffer_state *YY_BUFFER_STATE;
YY_BUFFER_STATE yy_scan_bytes(const char *bytes, int len);
void yy_delete_buffer(YY_BUFFER_STATE b);
extern int yylineno;

/* bison-generated parser (from ceed.tab.c). */
int yyparse(void);

/* Upstream compiler state we need to touch. `code`/`code_pos`/`rdata_pos` are
 * file-static in ceedcmpl.c and only visible because that TU is built with
 * -Dstatic= ; `rdata`, `ei` and `func` are already extern via ceed.h. */
extern u32 code_pos;
extern u32 rdata_pos;
extern pu8 code;
extern pu8 rdata;

/* Baked LSan opt-out (see file header). The base fuzzing engine ships a WEAK
 * __asan_default_options; we provide a STRONG definition so ours wins the link
 * and detect_leaks=0 is the compiled-in default (Mayhem's runtime ASAN_OPTIONS
 * does not clear a baked default, so no ASAN_OPTIONS is needed in the Mayhemfile). */
const char *__asan_default_options(void)
{
    return "detect_leaks=0";
}

/* exit() interception (linked via -Wl,--wrap=exit). */
extern void __real_exit(int status) __attribute__((noreturn));
static jmp_buf g_exit_jmp;
static volatile int g_in_run;

void __wrap_exit(int status)
{
    if (g_in_run) {
        g_in_run = 0;
        longjmp(g_exit_jmp, status ? status : 1);
    }
    __real_exit(status);
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    YY_BUFFER_STATE buf = NULL;
    int i;

    if (size > (1u << 20))      /* keep inputs bounded (CODE buffer is 1MB) */
        return 0;

    /* Reset the global compiler state that main()/cmplr_init() assume is
     * fresh at process start. code_pos MUST be zeroed before cmplr_init()
     * (which does code_pos += 0x80 for the injected itoa/atoi stubs). */
    for (i = 0; i < 26; i++)
        func[i] = 0;
    func[0] = -1;
    code_pos = 0;
    rdata_pos = 0;
    yylineno = 1;
    code = NULL;
    rdata = NULL;
    ei = NULL;

    g_in_run = 1;
    if (setjmp(g_exit_jmp) == 0) {
        elf_init();                 /* select the ELF backend + emit_* helpers */
        cmplr_init();               /* allocate CODE/RDATA, install stubs */
        buf = yy_scan_bytes((const char *)data, (int)size);
        yyparse();                  /* lex -> parse -> emit_code -> free_sym */
    }
    g_in_run = 0;

    /* Tear down this iteration's allocations. On the success path the AST was
     * already freed by the grammar action; on an exit()/longjmp path the AST +
     * bison stack leak (see file header — LSan off for this target), but the
     * large CODE/RDATA/exe-info buffers are reclaimed here every iteration. */
    if (buf)
        yy_delete_buffer(buf);
    free(code);
    code = NULL;
    free(rdata);
    rdata = NULL;
    free(ei);
    ei = NULL;

    return 0;
}
