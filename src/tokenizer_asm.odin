#+private file
package main

import "core:slice"

Asm_Tokenizer :: struct {
    using tokenizer: Tokenizer,
}

Asm_Token_Config :: struct {
    instructions: []string,
    directives: []string,
    directive_start_char: u8,
    macro_start_char: u8,
    registers: []string,
}

Token :: struct {
    using token: Basic_Token,

    variant: union {
        Operation,
        Punctuation,
    },
}

@(private)
tokenize_arm :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenize_asm(buffer, starting_offset, TOKEN_CFG_ARM)
}

@(private)
tokenize_x86 :: proc(buffer: ^Buffer, starting_offset := 0) {
    tokenize_asm(buffer, starting_offset, TOKEN_CFG_X86)
}

tokenize_asm :: proc(buffer: ^Buffer, starting_offset := 0, token_config: Asm_Token_Config) {
    // TODO TODO TODO

    tokenizer: Asm_Tokenizer
    tokenizer.buf = buffer.text
    tokenizer.starting_offset = starting_offset

    for {
        token := get_next_token(&tokenizer, token_config)
        if token.kind == .EOF do break

        save_token(buffer, &tokenizer, token)
    }
}


get_next_token :: proc(t: ^Asm_Tokenizer, token_config: Asm_Token_Config) -> (token: Token) {
    skip_whitespaces(t)

    token.start = t.offset
    token.kind = .EOF
    if is_eof(t) do return

    if (is_alpha(t) || is_char(t, '_')) {
        parse_identifier(t, &token, token_config)
    } else if is_number(t) {
        parse_number(t, &token)
    } else {
        switch t.buf[t.offset] {
        case token_config.directive_start_char:
            token.kind = .Directive
            t.offset += 1
            token.text = read_word(t)
            // TODO?
        case token_config.macro_start_char:
            token.kind = .Builtin_Function
            t.offset += 1
            token.text = read_word(t)
            // TODO?
        case '\t': parse_tab(t, &token)

        case '\'': fallthrough
        case '"':  fallthrough
        case '`':  parse_string_literal(t, &token)

        case '.':  token.kind = .Punctuation; token.variant = .Dot; t.offset += 1
        case ',':  token.kind = .Punctuation; token.variant = .Comma;         t.offset += 1
        case '{':  token.kind = .Punctuation; token.variant = .Brace_Left;    t.offset += 1
        case '}':  token.kind = .Punctuation; token.variant = .Brace_Right;   t.offset += 1
        case '[':  token.kind = .Punctuation; token.variant = .Bracket_Left;  t.offset += 1
        case ']':  token.kind = .Punctuation; token.variant = .Bracket_Right; t.offset += 1
        case '(':  token.kind = .Punctuation; token.variant = .Paren_Left;    t.offset += 1
        case ')':  token.kind = .Punctuation; token.variant = .Paren_Right;   t.offset += 1
        case '$':  token.kind = .Punctuation; token.variant = .Dollar_Sign;   t.offset += 1
        case '\n': token.kind = .Punctuation; token.variant = .Newline;       t.offset += 1
        case '/':
            if len(t.buf) > t.offset + 1 {
                if t.buf[t.offset + 1] == '/' {
                    t.offset += 1
                    parse_comment(t, &token)
                } else if t.buf[t.offset + 1] == '*' {
                    t.offset += 1
                    parse_multiline_comment(t, &token)
                }
            }
        case ';': parse_comment(t, &token)
        case:
            token.kind = .Identifier; t.offset += 1
        }
    }

    token.length = t.offset - token.start

    return
}

parse_comment :: proc(t: ^Asm_Tokenizer, token: ^Token) {
    token.kind = .Comment
    t.offset += 1
    for !is_eof(t) && !is_newline(t) {
        t.offset += 1
    }
}

parse_multiline_comment :: proc(t: ^Asm_Tokenizer, token: ^Token) {
    token.kind = .Comment
    t.offset += 1
    found_star := false
    for !is_eof(t) {
        if found_star && is_char(t, '/') {
            t.offset += 1
            break
        }
        found_star = is_char(t, '*')
        t.offset += 1
    }
}

parse_number :: proc(t: ^Asm_Tokenizer, token: ^Token) {
    is_decimal_number_continuation :: proc(t: ^Asm_Tokenizer) -> bool {
        return is_number(t) || is_char(t, '.') || is_char(t, '-') ||
            is_char(t, 'e') || is_char(t, 'E') || is_char(t, 'i') ||
            is_char(t, 'j') || is_char(t, 'k')
    }

    token.kind = .Number
    t.offset += 1
    if is_eof(t) do return

    if is_decimal_number_continuation(t) || is_char(t, '_') {
        decimal_point_found := false
        scientific_notation_found := false

        for !is_eof(t) && (is_decimal_number_continuation(t) || is_char(t, '_')) {
            if is_char(t, '.') {
                // break early for range operation (..< or ..=)
                b1, b2: byte
                ok: bool

                b1, ok = peek_byte(t, 1)
                if !ok do break

                if b1 == '.' {
                    b2, ok = peek_byte(t, 2)
                    if !ok do break
                    if b2 == '<' || b2 == '=' do break
                }

                if decimal_point_found do break
                decimal_point_found = true
            } else if is_char(t, 'i') || is_char(t, 'j') || is_char(t, 'k') {
                // imaginary or quaternion
                t.offset += 1
                break
            } else if is_char(t, 'e') || is_char(t, 'E') {
                if scientific_notation_found || !decimal_point_found do break
                scientific_notation_found = true
            } else if is_char(t, '-') {
                // negative exponent in scientific notation
                if !scientific_notation_found do break
                prev_byte, _ := peek_byte(t, -1)
                if prev_byte != 'e' || prev_byte != 'E' do break
            }

            t.offset += 1
        }
    } else if is_hex_prefix(t) || is_char(t, 'H') || is_char(t, 'X') {
        t.offset += 1
        for !is_eof(t) && (is_hex(t) || is_char(t, '_')) do t.offset += 1
    } else if is_char(t, 'o') {
        t.offset += 1
        for !is_eof(t) && (is_octal(t) || is_char(t, '_')) do t.offset += 1
    } else if is_char(t, 'b') {
        t.offset += 1
        for !is_eof(t) && (is_char(t, '0') || is_char(t, '1') || is_char(t, '_')) do t.offset += 1
    }
}

parse_string_literal :: proc(t: ^Asm_Tokenizer, token: ^Token) {
    delimiter := t.buf[t.offset]

    if delimiter == '`' {
        token.kind = .String_Raw
        t.offset += 1
        for !is_eof(t) && !is_char(t, '`') do t.offset += 1
    } else {
        token.kind = .String_Literal
        escape_found := false
        t.offset += 1

        for !is_eof(t) && !is_char(t, '\n') {
            if is_char(t, delimiter) && !escape_found do break
            escape_found = !escape_found && is_char(t, '\\')
            t.offset += 1
        }
    }

    if is_eof(t) do return
    t.offset += 1
}

parse_tab :: proc(t: ^Tokenizer, token: ^Token) {
    token.kind = .Punctuation
    token.variant = .Tab
    t.offset += 1
    for !is_eof(t) && is_char(t, '\t') do t.offset += 1
}

parse_identifier :: proc(t: ^Asm_Tokenizer, token: ^Token, token_config: Asm_Token_Config) {
    token.kind = .Identifier
    token.text = read_word(t)

    switch {
    case slice.contains(token_config.instructions,  token.text): token.kind = .Keyword
    case slice.contains(token_config.directives,   token.text): token.kind = .Directive
    case slice.contains(token_config.registers, token.text): token.kind = .Type
    }
}

// ARM
TOKEN_CFG_ARM := Asm_Token_Config {
    instructions = ARM_INSTRS,
    directives = []string {},
    directive_start_char = '.',
    macro_start_char = '#',
    registers = ARM_REGS,
}

ARM_INSTRS :: []string{
    "add", "ads", "adc", "adcs", "qadd", "qdadd",
    "adr",
    "sub", "subs", "sbc", "sbcs", "rsb", "rsbs", "rsc", "rscs", "qsub", "qdsub",
    // prefixes for parallel instrs: s, q, sh, u, uq, uh
    "add16", "sadd16", "qadd16", "shadd16", "uadd16", "uqadd16", "uhadd16",
    "sub16", "ssub16", "qsub16", "shsub16", "usub16", "uqsub16", "uhsub16",
    "add8", "sadd8", "qadd8", "shadd8", "uadd8", "uqadd8", "uhadd8",
    "sub8", "ssub8", "qsub8", "shsub8", "usub8", "uqsub8", "uhsub8",
    "asx", "sasx", "qasx", "shasx", "uasx", "uqasx", "uhasx",
    "sax", "ssax", "qsax", "shsax", "usax", "uqsax", "uhasx",
    "usad8", "usada8",
    "ssat", "ssat16", "usat", "usat16",
    "mul", "muls", "mla", "mlas",
    "umull", "umulls", "umlal", "umlals",
    "umaal",
    "smull", "smulls", "smlal", "smlals",
    // TODO smlal/smul/smla variants
    "smuad", "smuadx", "smlad", "smladx",
    "smlald", "smlaldx", "smusd", "smusdx",
    "smlsd", "smlsdx", "smlsld", "smlsldx",
    "smmul", "smmulr", "smmla", "smmlar", "smmls", "smmlsr",
    "mia", "miaph", // TODO: mia variants
    "sdiv", "udiv",
    "mov", "movs", "mvn", "mvns",
    "movt", "mra", "mar",
    "asr", "asrs", "lsl", "lsls",
    "lsr", "lsrs", "ror", "rors",
    "rrx", "rrxs",
    "clz",
    "cmp", "cmn",
    "tst", "teq",
    "and", "ands", "eor", "eors",
    "orr", "orrs", "orn", "orns",
    "bic", "bics",
    "bfc", "bfi", "sbfx", "ubfx",
    "pkhbt", "pkhtb",
    "sxth", "sxtb16", "sxtb",
    "uxth", "uxtb16", "uxtb",
    "sxtah", "sxtab16", "sxtab",
    "uxtah", "uxtab16", "uxtab",
    "rbit", "rev", "rev16", "revsh",
    "sel",
    "b", "beq", "bne", "bcs", "bhs", "bcc", "blo", "bmi", "bpl", "bvs", "bvc", "bhi", "bls", "bge", "blt", "bgt", "ble",
    "bl", "bleq", "blne", "blcs", "blhs", "blcc", "bllo", "blmi", "blpl", "blvs", "blvc", "blhi", "blls", "blge", "bllt", "blgt", "blle",
    "bx", "bxeq", "bxne", "bxcs", "bxhs", "bxcc", "bxlo", "bxmi", "bxpl", "bxvs", "bxvc", "bxhi", "bxls", "bxge", "bxlt", "bxgt", "bxle",
    "blx", "blxeq", "blxne", "blxcs", "blxhs", "blxcc", "blxlo", "blxmi", "blxpl", "blxvs", "blxvc", "blxhi", "blxls", "blxge", "blxlt", "blxgt", "blxle",
    "bxj",
    "cbz", "cbnz", "tbb", "tbh",
    "mrs", "msr",
    "cpsid", "cpsie", "cps", "setend",
    "ldr", "ldrb", "ldrsb", "ldrh", "ldrsh",
    "ldrt", "ldrbt", "ldrsbt", "ldrht", "ldrsht",
    "str", "strb", "strh",
    "strt", "strbt", "strht",
    "ldrd", "strd",
    "pld", "pli", "pldw",
    "ldm", "ldmia", "ldmib", "ldmda", "ldmdb", "ldmfd", "pop",
    "stm", "stmia", "stmib", "stmda", "stmdb", "stmfd", "push",
    "ldrex", "ldrexh", "ldrexb", "ldrexd",
    "strex", "strexh", "strexb", "strexd",
    "clrex",
    "cdp", "cdp2",
    "mrc", "mrc2", "mrrc", "mrrc2",
    "mcr", "mcr2", "mcrr", "mcrr2",
    "ldc", "ldc2", "stc", "stc2",
    "swp", "swpb",
    "srs", "srsia", "srsib", "srsda", "srsdb", "srsfd",
    "rfe", "rfeia", "rfeib", "rfeda", "rfedb", "rfefd",
    "eret",
    "bkpt",
    "smc",
    "svc",
    "nop",
    "dbg", "dmb", "dsb", "isb", "sev", "wfe", "wfi", "yield",
}

ARM_REGS :: []string{
    "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "sp", "fp", "lr", "pc",
    "r8_fiq", "r9_fiq", "r10_fiq", "r11_fiq", "r12_fiq", "r13_fiq", "r14_fiq",
    "sp_fiq", "lr_fiq",
    "r13_irq", "sp_irq", "r14_irq", "lr_irq",
    "r13_svc", "sp_svc", "r14_svc", "lr_svc",
    "r13_undef", "sp_undef", "r14_undef", "lr_undef",
    "r13_abt", "sp_abt", "r14_abt", "lr_abt",
    "cpsr", "cpsr_fsxc", "cpsr_f", "cpsr_fs", "cpsr_fsx", "cpsr_s", "cpsr_sx", "cpsr_sxc", "cpsr_x", "cpsr_xc", "cpsr_c",
    "spsr", "spsr_fiq", "spsr_irq", "spsr_svc", "spsr_undef", "spsr_abt",
    "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9", "p10", "p11", "p12", "p13", "p14", "p15",
    "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8", "c9", "c10", "c11", "c12", "c13", "c14", "c15",
    // TODO
}


// x86
TOKEN_CFG_X86 := Asm_Token_Config {
    instructions = X86_INSTRS,
    directives = NASM_DIRECTIVES,
    directive_start_char = '+',
    macro_start_char = '%',
    registers = X86_REGS,
}

X86_INSTRS :: []string{
    // x86
    "mov", "aaa", "aad", "aam", "aas", "adc", "add", "and", "call", "cbw",
    "clc", "cld", "cli", "cmc", "cmp", "cmpsb", "cmpsw", "cwd",
    "daa", "das", "dec", "div", "esc", "hlt", "idiv", "imul", "in",
    "inc", "int", "into", "iret", "ja", "jae", "jb", "jbe", "jc", "je", "jg",
    "jge", "jl", "jle", "jna", "jnae", "jnb", "jnbe", "jnc", "jne", "jng",
    "jnge", "jnl", "jnle", "jno", "jnp", "jns", "jnz", "jo", "jp", "jpe",
    "jpo", "js", "jz", "jcxz", "jmp", "lahf", "lds", "lea", "les", "lock",
    "lodsb", "lodsw", "loop", "loope", "loopne", "loopnz", "loopz", "movsb",
    "movsw", "mul", "neg", "nop", "or", "pop", "popf", "push", "pushf",
    "rcl", "rcr", "rep", "repe", "repne", "repnz", "repz", "ret", "retn",
    "retf", "rol", "ror", "sahf", "sal", "sar", "sbb", "scasb", "scasw",
    "shl", "shr", "stc", "std", "sti", "stosb", "stosw", "sub", "test",
    "wait", "xchg", "xlat", "xor",

    "bound", "enter", "ins", "leave", "outs", "popa", "pusha",
    "arpl", "clts", "lar", "lgdt", "lidt", "lldt", "lmsw", "loadall", "lsl",
    "ltr", "sgdt", "sidt", "sldt", "smsw", "str", "verr", "verw",

    "bsf", "bsr", "bt", "btc", "btr", "bts", "cdq", "cmpsd", "cwde", "insd",
    "iret", "iretd", "iretf", "jecxz", "lfs", "lgs", "lss", "lodsd", "loopw",
    "loopew", "loopnew", "loopnzw", "loopzw", "loopd", "looped", "loopned",
    "loopnzd", "loopzd", "cr", "tr", "dr", "movsd", "movsx", "movzx",
    "outsd", "popad", "popfd", "pushad", "pushfd", "scasd", "seta", "setae",
    "setb", "setbe", "setc", "sete", "setg", "setge", "setl", "setle",
    "setna", "setnae", "setnb", "setnbe", "setnc", "setne", "setng",
    "setnge", "setnl", "setnle", "setno", "setnp", "setns", "setnz",
    "seto", "setp", "setpe", "setpo", "sets", "setz", "shdl", "shrd", "stosd",

    "bswap", "cmpxchg", "invd", "invlpg", "wbinvd", "xadd",
    "cpuid", "cmpxchg8b", "rdmsr", "rdtsc", "wrmsr", "rsm",
    "rdpmc", "syscall", "sysret",

    "cmova", "cmovae", "cmovb", "cmovbe", "cmovc", "cmove", "cmovg",
    "cmovge", "cmovl", "cmovle", "cmovna", "cmovnae", "cmovnb", "cmovnbe",
    "cmovnc", "cmovne", "cmovng", "cmovnge", "cmovnle", "cmovno", "cmovpn",
    "cmovns", "cmovnz", "cmovo", "cmovp", "cmovpe", "cmovpo", "cmovs", "cmovz",
    "sysenter", "sysexit", "ud2",

    "maskmovq", "movntps", "movntq",
    "prefetch0", "prefetch1", "prefetch2", "prefetchnta",
    "sfence",
    "clflush", "lfence", "maskmovdqu", "mfence",
    "movntdq", "movntdi", "movntpd", "pause",
    "monitor", "mwait",

    "cdqe", "cqo", "cmpsq", "cmpxchg16b", "iretq", "jrcxz", "lodsq",
    "movsdx", "popfq", "pushfq", "rdtscp", "scasq", "stosq", "swapgs",

    "clgi", "invlpga", "skinit", "stgi", "vmload", "vmmcall", "vmrun",
    "vmsave", "vmptrdl", "vmptrst", "vmclear", "vmread", "vmwrite",
    "vmcall", "vmlaunch", "vmresume", "vmxoff", "vmxon",

    "lzcnt", "popcnt", "bextr", "blcfill", "blci", "blcic", "blcmask", "blcs", "blsfill", "blsic", "tlmskc", "tzmsk",

    // x87
    "f2xm1", "fabs", "fadd", "faddp", "fbld", "fbstp", "fchs", "fclex",
    "fcom", "fcomp", "fcompp", "fdecstp", "fdisi", "fdiv", "fvidp", "fdivr",
    "fdivrp", "feni", "ffree", "fiadd", "ficom", "ficomp", "fidiv", "fidivr",
    "fild", "fimul", "fincstp", "finit", "fist", "fistp", "fisub", "fisubr",
    "fld", "fld1", "fldcw", "fldenv", "fldenvw", "fldl2e", "fldl2t",
    "fldlg2", "fldln2", "fldpi", "fldz", "fmul", "fmulp", "fnclex", "fndisi",
    "fneni", "fninit", "fnop", "fnsave", "fnsavenew", "fnstcw", "fnstenv",
    "fnstenvw", "fnstsw", "fpatan", "fprem", "fptan", "frndint", "frstor",
    "frstorw", "fsave", "fsavew", "fscale", "fsqrt", "fst", "fstcw",
    "fstenv", "fstenvw", "fstp", "fstpsw", "fsub", "fsubp", "fsubr",
    "fsubrp", "ftst", "fwait", "fxam", "fxch", "fxtract", "fyl2x", "fyl2xp1",
    "fsetpm",
    "fcos", "fldenvd", "fsaved", "fstenvd", "fprem1", "frstord",
    "fsin", "fsincos", "fstenvd", "fucom", "fucomp", "fucompp",
    "fcmovb", "fcmovbe", "fcmove", "fcmove", "fcmovnb", "fcmovnbe",
    "fcmovne", "fcmovnu", "fcmovu",
    "fcomi", "fcomip", "fucomi", "fucomip",
    "fxrstor", "fxsave", "fisttp", "ffreep",

    // SIMD
    "emms", "movd", "movq", "packssdw", "packsswb", "packuswb", "paddb",
    "paddw", "paddd", "paddsb", "paddsw", "paddusb", "paddusw",
    "pand", "pandn", "por", "pxor", "pcmpeqb", "pcmpeqw", "pcmpeqd",
    "pcmpgtb", "pcmpgtw", "pcmpgtd", "pmaddwd", "pmulhw", "pmullw",
    "psllw", "pslld", "psllq", "psrad", "psraw", "psrlw", "psrld", "psrlq",
    "psubb", "psubw", "psubd", "psubsb", "psubsw", "psubusb", "punpckhbw",
    "punpckhwd", "punpckhdq", "punkcklbw", "punpckldq", "punpcklwd",
    "paveb", "paddsiw", "pmagw", "pdistib", "psubsiw", "pmwzb", "pmulhrw",
    "pmvnzb", "pmvlzb", "pmvgezb", "pmulhriw", "pmachriw",
    "femms", "pavgusb", "pf2id", "pfacc", "pfadd", "pfcmpeq", "pfcmpge",
    "pfcmpgt", "pfmax", "pfmin", "pfmul", "pfrcp", "pfrcpit1", "pfrcpit2",
    "pfrsqit1", "pfrsqrt", "pfsub", "pfsubr", "pi2fd", "pmulhrw",
    "prefetch", "prefetchw",
    "pf2iw", "pfnacc", "pfpnacc", "pi2fw", "pswapd", "pfrsqrtv", "pfrcpv",
    "addps", "addss", "cmpps", "cmpss", "comiss", "cvtpi2ps", "cvtps2pi",
    "cvtsi2ss", "cvtss2si", "cvttps2pi", "cvttss2si", "divps", "divss",
    "ldmxcsr", "maxps", "maxss", "minps", "minss", "movaps", "movhlps",
    "movhps", "movlhps", "movlps", "movmskps", "movntps", "movss", "movups",
    "mulps", "mulss", "rcpps", "rcpss", "rsqrtps", "rsqrtss", "shufps",
    "sqrtps", "sqrtss", "stmxcsr", "subps", "subss", "ucomiss",
    "unpckhps", "unpcklps",
    "andnps", "andps", "orps", "pavgb", "pavgw", "pextrw", "pinsrw",
    "pmaxsw", "pmaxub", "pminsw", "pminub", "pmovmskb", "pmulhuw", "psadbw",
    "pshufw", "xorps",
    "movups", "movss", "movlps", "movhlps", "movlps", "unpcklps", "unpckhps",
    "movhps", "movlhps", "prefetchnta", "prefetch0", "prefetch1",
    "prefetch2", "nop", "movaps", "cvtpi2ps", "cvtsi2ss", "cvtps2pi",
    "cvttss2si", "cvtps2pi", "cvtss2si", "ucomiss", "comiss", "sqrtps",
    "sqrtss", "rsqrtps", "rsqrtss", "rcpps", "andps", "orps", "xorps",
    "addps", "addss", "mulps", "mulss", "subps", "subss", "minps", "minss",
    "divps", "divss", "maxps", "maxss", "pshufw", "ldmxcsr", "stmxcsr",
    "sfence", "cmpps", "cmpss", "pinsrw", "pextrw", "shufps", "pmovmskb",
    "pminub", "pmaxub", "pavgb", "pavgw", "pmulhuw", "movntq", "pminsw",
    "pmaxsw", "psadbw", "maskmovq",
    "addpd", "addsd", "addnpd", "cmppd", "cmpsd",
    "addpd", "addsd", "andnpd", "andpd", "cmppd", "cmpsd", "comisd",
    "cvtdq2pd", "cvtdq2ps", "cvtpd2dq", "cvtpd2pi", "cvtpd2ps", "cvtpi2pd",
    "cvtps2dq", "cvtps2pd", "cvtsd2si", "cvtsd2ss", "cvtsi2sd", "cvtss2sd",
    "cvttpd2dq", "cvttpd2pi", "cvttps2dq", "cvttsd2si", "divpd", "divsd",
    "maxpd", "maxsd", "minpd", "minsd", "movapd", "movhpd", "movlpd",
    "movmskpd", "movsd", "movupd", "mulpd", "mulsd", "orpd", "shufpd",
    "sqrtpd", "sqrtsd", "subpd", "subsd", "ucomisd", "unpckhpd", "unpcklpd",
    "xorpd",
    "movdq2q", "movdqa", "movdqu", "movq2dq",
    "paddq", "psubq", "pmuludq",
    "pshufhw", "pshuflw", "pshufd", "pslldq", "psrldq",
    "punpckhqdq", "punpcklqdq",
    "addsubpd", "addsubps", "haddpd", "haddps", "hsubpd", "hsubps",
    "movddup", "movshdup", "movsldu", "lddqu",
    "psignw", "psignd", "psignb", "pshufb", "pmulhrsw", "pmaddubsw",
    "phsubw", "phsubsw", "phsubd", "phaddw", "phaddsw", "phaddd",
    "palignr", "pabsw", "pabsd", "pabsb",
    "dpps", "dppd", "blendps", "blendpd", "blendvps", "blendvpd",
    "roundps", "roundss", "roundpd", "roundsd", "insertps", "extractps",
    "mpsadbw", "phminposuw", "pmulld", "pmuldq", "pblendvb", "pblendw",
    "pminsb", "pmaxsb", "pminuw", "pmaxuw", "pminud", "pmaxud",
    "pminsd", "pmaxsd", "pinsrb", "pinsrd", "pinsrq",
    "pextrb", "pextrw", "pextrd", "pextrq",
    "pmovsxbw", "pmovzxbw", "pmovsxbd", "pmovzxbd", "pmovsxbq", "pmovzxbq",
    "pmovsxwd", "pmovzxwd", "pmovsxwq", "pmovzxwq", "pmovsxdq", "pmovzxdq",
    "ptest", "pcmpeqq", "packusdw", "movntdqa",
    "extrq", "insertq", "movntsd", "movntss",
    "crc32", "pcmpestri", "pcmpestrm", "pcmpistri", "pcmpistrm", "pcmpgtq",
    "vfmaddpd", "vfmaddps", "vfmaddsd", "vfmaddss", "vfmaddsubpd",
    "vfmaddsubps", "vfmsubaddpd", "vfmsubaddps", "vfmsubpd", "vfmsubps",
    "vfmsubsd", "vfmsubss", "vfnmaddpd", "vfnmaddps", "vfnmaddsd",
    "vfnmaddss", "vfnmsubps", "vfnmsubsd", "vfnmsubss",
    // TODO (sio): AVX/AVX2/AVX-512? those look to be missing, at least

    // crypto
    "aesenc", "aesenclast", "aesdec", "aesdeclast",
    "aeskeygenassist", "aesimc",
    "sha1rnds4", "sha1nexte", "sha1msg1", "sha1msg2",
    "sha256rnds2", "sha256msg1", "sha256msg2",

    // undocumented
    "aam", "aad", "salc", "icebp", "loadall", "loadalld", "udl",
}

NASM_DIRECTIVES :: []string{
    "extern", "global", "section", "segment", "_start", ".text", ".data", ".bss", ".COMMON",
    "db", "dw", "dd", "dq", "dt", "ddq", "do",
    "resb", "resh", "resd",
    "equ",
}

X86_REGS :: []string {
    "al", "ah", "bl", "bh", "cl", "ch", "dl", "dh",
    "bpl", "sil", "dil", "spl",
    "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b",
    "cw", "sw", "tw", "fp_ds", "fp_opc", "fp_ip", "fp_dp", "fp_cs",
    "cs", "ss", "ds", "es", "fs", "gs", "gdtr", "idtr", "tr", "ldtr",
    "ax", "bx", "cx", "dx", "bp", "si", "r8w", "r9w", "r10w", "r11w", "di", "sp", "r12w", "r13w", "r14w", "r15w", "ip",
    "eax", "ebx", "ecx", "edx", "ebp", "esi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d", "eip", "edi", "esp", "eflags", "mxcsr",
    "mm0", "mm1", "mm2", "mm3", "mm4", "mm5", "mm6", "mm7",
    "rax", "rbx", "rcx", "rdx", "rbp", "rsi", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rdi", "rsp", "rip", "rflags",
    "cr0", "cr1", "cr2", "cr3", "cr4", "cr5", "cr6", "cr7", "cr8", "cr9", "cr10", "cr11", "cr12", "cr13", "cr14", "cr15", "msw",
    "dr0", "dr1", "dr2", "dr3", "dr4", "dr5", "dr6", "dr7", "dr8", "dr9", "dr10", "dr11", "dr12", "dr13", "dr14", "dr15",
    "st0", "st1", "st2", "st3", "st4", "st5", "st6", "st7",
    "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", "xmm8","xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15",
    "ymm0", "ymm1", "ymm2", "ymm3", "ymm4", "ymm5", "ymm6", "ymm7", "ymm8", "ymm9", "ymm10", "ymm11", "ymm12", "ymm13", "ymm14", "ymm15",
    "zmm0", "zmm1", "zmm2", "zmm3", "zmm4", "zmm5", "zmm6", "zmm7", "zmm8", "zmm9", "zmm10", "zmm11", "zmm12", "zmm13", "zmm14", "zmm15",
    "zmm16", "zmm17", "zmm18", "zmm19", "zmm20", "zmm21", "zmm22", "zmm23", "zmm24", "zmm25", "zmm26", "zmm27", "zmm28", "zmm29", "zmm30", "zmm31",
}

