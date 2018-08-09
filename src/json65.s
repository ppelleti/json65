        .macpack generic
        .include "zeropage.inc"
        .import saveeax
        .import negeax
        .import resteax
        .import callptr4
        .import decsp3
        .import incsp4

;; zero page locations
        state     = regbank
        strbuf    = regbank + 2
        inbuf     = regbank + 4
        inbuflast = tmp4         ; length - 1
        charidx   = tmp3         ; position in inbuf
        evtype    = tmp2         ; only used as an argument to call_callback
        esc_code  = tmp2         ; only used as an argument to lookup_escape
        tmp0      = sreg
        tmp5      = sreg+1
        long1     = regsave
        long2     = ptr1
;; zero page locations (for _j65_parse)
        jlen      = ptr3

;; character properties
        prop_ws   = %10000000   ; must be hi bit (we use bmi/bpl to test)
        prop_str  = %01000000
        prop_lit  = %00100000
        prop_int  = %00010000
        prop_num  = %00001000
        prop_sc   = %00000111   ; mask for structural character field

;; j65_event
.enum
        ; events
        J65_NULL        = 0
        J65_FALSE       = 1
        J65_TRUE        = 2
        J65_INTEGER     = 3        ; integer
        J65_NUMBER      = 4        ; string
        J65_STRING      = 5        ; string
        J65_KEY         = 6        ; string
        J65_START_OBJ   = 7
        J65_END_OBJ     = 8
        J65_START_ARRAY = 9
        J65_END_ARRAY   = 10
        ; errors
        J65_ILLEGAL_CHAR     = $80  ; integer (byte offset of error)
        J65_ILLEGAL_ESCAPE          ; integer (byte offset of error)
        J65_NESTING_TOO_DEEP        ; integer (byte offset of error)
        J65_STRING_TOO_LONG         ; integer (byte offset of error)
        J65_PARSE_ERROR             ; integer (byte offset of error)
        J65_EXPECTED_STRING         ; integer (byte offset of error)
        J65_EXPECTED_COLON          ; integer (byte offset of error)
        J65_EXPECTED_COMMA          ; integer (byte offset of error)
        J65_EXPECTED_OBJ_END        ; integer (byte offset of error)
        J65_EXPECTED_ARRAY_END      ; integer (byte offset of error)
.endenum

;; j65_status
.enum
        J65_DONE      = 0
        J65_WANT_MORE = 1
        J65_ERROR     = 2
.endenum

;; lexer state
.enum
        lex_ready
        lex_literal
        lex_string
        lex_str_escape
.endenum

;; parser state (should fit in 3 bits; otherwise need to change l_ready)
.enum
        par_ready
        par_ready_or_close_array
        par_key_or_close_object
        par_need_colon
        par_need_comma_or_close_array
        par_need_comma_or_close_object
        par_done
.endenum

;; structural characters (should fit in 3 bits)
.enum
        sc_none                 ; an illegal character
        sc_lsq                  ; [
        sc_lcur                 ; {
        sc_rsq                  ; ]
        sc_rcur                 ; }
        sc_colon                ; :
        sc_comma                ; ,
        sc_quote                ; "
.endenum

;; state variables
.struct st
        file_pos   .dword
        lexer_st   .byte
        parser_st  .byte
        parser_st2 .byte
        str_idx    .byte
        stack_idx  .byte
        flags      .byte
        stack_min  .byte
.endstruct

;; loads a with specified state variable.  clobbers y.
.macro getstate arg
        ldy #arg
        lda (state),y
.endmacro               ; getstate

;; stores a to specified state variable.  clobbers y.
.macro putstate arg
        ldy #arg
        sta (state),y
.endmacro               ; putstate

;; pushes regbank (caller-saved registers) onto 6502 stack
.macro save_regbank
        .repeat 6, i
        lda regbank+i
        pha
        .endrep
.endmacro               ; save_regbank

;; pops regbank (caller-saved registers) off of 6502 stack
.macro restore_regbank
        .repeat 6, i
        pla
        sta regbank+5-i
        .endrep
.endmacro               ; restore_regbank

        .code

;; void __fastcall__ j65_init(j65_state *s);
.proc _j65_init
        sta ptr1
        stx ptr1+1
        ldy #.sizeof(st) - 1
        lda #0
loop:   sta (ptr1),y
        dey
        bpl loop
        lda #par_done
        putstate st::parser_st2
        lda #$ff
        putstate st::stack_idx
        lda #.sizeof(st)
        putstate st::stack_min
        rts
.endproc                ; _j65_init

;; uint8_t __fastcall__ j65_parse(void *ctx, j65_callback cb,
;;     j65_state *s, const char *buf, size_t len)
.proc _j65_parse
        sta jlen
        stx jlen+1
        save_regbank            ; save regbank onto 6502 stack
        ldy #0                  ; move state and buf from C stack to regbank
        lda (sp),y
        sta inbuf
        iny
        lda (sp),y
        sta inbuf+1
        iny
        lda (sp),y
        sta state
        sta strbuf
        iny
        lda (sp),y
        sta state+1
        add #1                  ; strbuf is state+256
        sta strbuf+1
        jsr incsp4              ; remove state and buf from C stack
loop:   lda jlen+1
        beq leftovers
        pha                     ; save jlen on 6502 stack
        lda jlen
        pha
        lda #$ff
        sta inbuflast
        jsr parse
        tax
        lda #$ff                ; increment file_pos by 256
        jsr add_a_plus_1_to_file_pos
        pla                     ; restore jlen off 6502 stack
        sta jlen
        pla
        sub #1                  ; decrement jlen by 256
        sta jlen+1
        cpx #J65_WANT_MORE
        beq done                ; error or success; don't need to parse more
        inc inbuf+1             ; add 256 to inbuf
        jmp loop
leftovers:                      ; hi byte of jlen is zero
        ldx jlen
        beq done                ; if length was a multiple of 256
        dex
        stx inbuflast
        txa
        pha
        jsr parse
        tax
        pla
        jsr add_a_plus_1_to_file_pos
done:   jsr incsp4              ; pop ctx and cb off of C stack
        restore_regbank         ; restore regbank off of 6502 stack
        txa                     ; return value
        ldx #0
        rts
.endproc                ; _j65_parse

;; adds a plus 1 to file_pos.
;; clobbers a and y.  preserves x.
.proc add_a_plus_1_to_file_pos
        ldy #st::file_pos
        sec
        adc (state),y           ; file_pos
        sta (state),y
        iny
        lda (state),y           ; file_pos+1
        adc #0
        sta (state),y
        iny
        lda (state),y           ; file_pos+2
        adc #0
        sta (state),y
        iny
        lda (state),y           ; file_pos+3
        adc #0
        sta (state),y
        rts
.endproc                ; add_a_plus_1_to_file_pos

;; x will contain character, and a will contain character properties
;; on exit. clobbers y.
;; negative flag is set based on hi bit of properties.  (prop_ws)
.proc getchar
        ldy charidx
        lda (inbuf),y
        tax
        bmi hiset
        lda charprops,x
        rts
hiset:  lda #prop_str           ; non-ascii unicode char, legal only in strings
        rts
.endproc                ; getchar

;; state, strbuf, inbuf, and inbuflast should be set up upon entry.
;; stack should contain context and callback.
;; returns status in a.
.proc parse
        lda #0
        sta charidx
parseloop:
        getstate st::lexer_st
        tay
        lda lex_tab_h,y
        pha
        lda lex_tab_l,y
        pha
        rts                     ; jump table; not end of subroutine
l_ready:
        jsr getchar
        bmi nextchar            ; whitespace
        bit flags_prop_lit_or_num
        bne start_lit
        and #prop_sc
        asl
        asl
        asl
        sta tmp1
        getstate st::parser_st
        ora tmp1
        tay
        lda dispatch_tab_h,y
        pha
        lda dispatch_tab_l,y
        pha
        rts                     ; jump table; not end of subroutine
start_lit:
        getstate st::parser_st
        tay
        lda literal_errors,y
        bne error
        lda #prop_lit | prop_int | prop_num
        putstate st::flags
        lda #lex_literal
        putstate st::lexer_st   ; fall thru and process same char as literal
l_literal:
        jsr getchar
        ldy #st::flags
        and (state),y
        bne goodliteral
        lda (state),y
        jsr handle_literal
        jmp finished_scalar
goodliteral:
        sta (state),y           ; write back flags after and
        jmp putchar
l_string:
        jsr getchar
        and #prop_str
        beq illegal_char
        cpx #$5C                ; backslash
        beq got_backslash
        cpx #$22                ; double quote
        beq got_quote
        jmp putchar
got_backslash:
        lda #lex_str_escape
        putstate st::lexer_st
        jmp nextchar
got_quote:
        jsr handle_string
finished_scalar:
        bcs error
        lda #lex_ready
        putstate st::lexer_st
        jmp nextchar
illegal_char:
        lda #J65_ILLEGAL_CHAR
        jmp error
l_str_escape:
        lda #lex_string
        putstate st::lexer_st
        ldy charidx             ; don't need to jsr getchar; don't need props
        lda (inbuf),y
        sta esc_code
        cmp #$5c                ; backslash
        beq escape_later
        cmp #'u'
        beq escape_later
        jsr lookup_escape
        bcs illegal_escape
        tax
        jmp putchar
illegal_escape:
        lda #J65_ILLEGAL_ESCAPE
        jmp error
escape_later:
        lda #1
        putstate st::flags      ; flag indicating we need a later escape pass
        getstate st::str_idx    ; re-insert backslash first
        tay
        lda #$5c                ; backslash
        sta (strbuf),y
        iny
        beq strtoolong
        lda esc_code
        jmp putchar1
putchar:                        ; x contains char to put in string buf
        getstate st::str_idx
        tay
        txa
putchar1:                       ; a contains char, y contains str_idx
        sta (strbuf),y
        iny
        beq strtoolong
        tya
        putstate st::str_idx
nextchar:
        getstate st::parser_st
        cmp #par_done
        beq done
        lda charidx
        cmp inbuflast
        beq wantmore
        inc charidx
        jmp parseloop
wantmore:
        lda #J65_WANT_MORE
        rts                     ; end of subroutine
done:   lda #J65_DONE
        rts                     ; end of subroutine
strtoolong:
        lda #J65_STRING_TOO_LONG
error:  sta evtype
        jsr make_byte_offset    ; get byte offset in file into regsave
        jsr call_callback
        lda #J65_ERROR
        rts                     ; end of subroutine
disp_illegal_char:
        lda #J65_ILLEGAL_CHAR
        jmp error
disp_parse_error:
        lda #J65_PARSE_ERROR
        jmp error
disp_start_obj:
        ldx #J65_START_OBJ
        lda #0                  ; index into close_states
descend:
        pha
        stx evtype
        jsr call_callback
        getstate st::parser_st2
        jsr push_state_stack
        pla
        bcs error
        tax
        lda close_states,x
        putstate st::parser_st
        lda close_states+1,x
        putstate st::parser_st2
        jmp nextchar
disp_end_obj:
        lda #J65_END_OBJ
ascend: sta evtype
        jsr call_callback
        jsr pop_state_stack
        bcs error
        putstate st::parser_st
        putstate st::parser_st2
        jmp nextchar
disp_start_array:
        ldx #J65_START_ARRAY
        lda #2                  ; index into close_states
        jmp descend
disp_end_array:
        lda #J65_END_ARRAY
        jmp ascend
disp_start_string:
        lda #lex_string
        putstate st::lexer_st
        lda #0
        putstate st::flags      ; boolean for second unescape pass
        jmp nextchar
disp_comma_array:
        lda #par_ready_or_close_array
dca1:   putstate st::parser_st
        jmp nextchar
disp_comma_object:
        lda #par_key_or_close_object
        jmp dca1
disp_colon:
        lda #par_ready
        jmp dca1

        .rodata

.define lex_tab l_ready-1, l_literal-1, l_string-1, l_str_escape-1
lex_tab_l:
        .lobytes lex_tab
lex_tab_h:
        .hibytes lex_tab
.undefine lex_tab

flags_prop_lit_or_num:
        .byte prop_lit | prop_int | prop_num

.define dt_none  TODO
.define dt_lsq   TODO
.define dt_lcur  TODO
.define dt_rsq   TODO
.define dt_rcur  TODO
.define dt_colon TODO
.define dt_comma TODO
.define dt_quote TODO
dispatch_tab_l:
;        .lobytes dt_none
;        .lobytes dt_lsq
;        .lobytes dt_lcur
;        .lobytes dt_rsq
;        .lobytes dt_rcur
;        .lobytes dt_colon
;        .lobytes dt_comma
;        .lobytes dt_quote
dispatch_tab_h:
;        .hibytes dt_none
;        .hibytes dt_lsq
;        .hibytes dt_lcur
;        .hibytes dt_rsq
;        .hibytes dt_rcur
;        .hibytes dt_colon
;        .hibytes dt_comma
;        .hibytes dt_quote

.undefine dt_none
.undefine dt_lsq
.undefine dt_lcur
.undefine dt_rsq
.undefine dt_rcur
.undefine dt_colon
.undefine dt_comma
.undefine dt_quote

close_states:
        .byte par_key_or_close_object, par_need_comma_or_close_object
        .byte par_ready_or_close_array, par_need_comma_or_close_array

literal_errors:                 ; needs to match parser state enum
        .byte 0, 0, J65_EXPECTED_STRING, J65_EXPECTED_COLON
        .byte J65_EXPECTED_COMMA, J65_EXPECTED_COMMA, J65_PARSE_ERROR

        .code

.endproc                ; parse

;; "data" argument is in regsave.
;; event type is in evtype.
;; context and callback are on stack.
;; clobbers all regs.
.proc call_callback
        lda inbuflast           ; save caller-save regs
        pha
        lda charidx
        pha
        jsr decsp3              ; make room for 3 bytes of arguments
        ldy #6
        lda (sp),y              ; context hi
        tax
        dey
        lda (sp),y              ; context lo
        sta tmp1
        dey
        lda (sp),y              ; callback hi
        sta ptr4+1
        dey
        lda (sp),y              ; callback lo
        sta ptr4
        txa
        dey
        sta (sp),y              ; context hi
        lda tmp1
        dey
        sta (sp),y              ; context lo
        lda evtype
        dey
        sta (sp),y              ; event type
        jsr resteax             ; regsave becomes "data" argument
        jsr callptr4            ; call the C callback function (in ptr4)
        pla                     ; restore caller-save regs
        sta charidx
        pla
        sta inbuflast
        rts                     ; end of subroutine
.endproc                ; call_callback

;; add charidx to file_pos and store result in regsave.
;; clobbers a, x, y.
.proc make_byte_offset
        lda charidx
        ldy #st::file_pos
        add (state),y
        sta regsave
        lda #0
        iny
        adc (state),y
        sta regsave+1
        iny
        lda #0
        adc (state),y
        sta regsave+2
        iny
        lda #0
        adc (state),y
        sta regsave+3
        rts
.endproc                ; make_byte_offset

;; Takes escape code in esc_code (tmp2).
;; If legal, returns escaped char in a with carry clear.
;; If not legal, returns with carry set.
;; Clobbers y, preserves x.
.proc lookup_escape
        ldy #0
loop:   lda escape_codes,y
        beq notfound
        iny
        cmp esc_code
        bne loop
        lda escaped_chars,y
        clc
        rts
notfound:
        sec
        rts

        .rodata
escape_codes:
        .byte $22,"/bfnrt",0
escaped_chars:
        .byte $22, $2f, $08, $0c, $0a, $0d, $09
        .code

.endproc                ; lookup_escape

;; Handle a double-quoted string.
;; Check flags to see if it needs a second unescaping pass.
;; Clobbers all registers.
;; On success, returns carry clear.
;; On error, returns carry set with error event in a.
.proc handle_string
        getstate st::flags
        beq skipescape
        jsr unescape_unicode
        bcc skipescape
        lda #J65_ILLEGAL_ESCAPE
        rts                     ; error exit; carry is still set
skipescape:
        getstate st::parser_st
        cmp #par_ready
        beq p_ready
        cmp #par_ready_or_close_array
        beq p_ready
        cmp #par_key_or_close_object
        beq p_key
        lda #J65_PARSE_ERROR
        sec
        rts                     ; error exit
p_ready:
        jsr string_in_regsave
        lda #J65_STRING
        sta evtype
        jsr call_callback
        getstate st::parser_st2 ; get next parser state in a
        putstate st::parser_st
        clc
        rts                     ; success exit
p_key:  jsr string_in_regsave
        lda #J65_KEY
        sta evtype
        jsr call_callback
        lda #par_need_colon
        putstate st::parser_st
        clc
        rts                     ; success exit
.endproc                ; handle_string

;; put string length in first two bytes of regsave
;; and string pointer in second two bytes of regsave.
;; clobbers a and y.
.proc string_in_regsave
        getstate st::str_idx
        sta regsave
        lda #0
        sta regsave+1
        lda strbuf
        sta regsave+2
        lda strbuf+1
        sta regsave+3
        rts
.endproc                ; string_in_regsave

;; unescape \\ and \u in the string buffer.
;; returns carry set on error.  clear on success.
;; clobbers all registers.
.proc unescape_unicode
        getstate st::str_idx
        sta tmp2
        ldy #0
        sty tmp1
loop:   cpy tmp2
        beq done
        lda (strbuf),y
        iny
        cmp #$5c                ; backslash
        beq escape
loop1:  sty tmp0
        ldy tmp1
        sta (strbuf),y
        inc tmp1
        ldy tmp0
        jmp loop
escape: cpy tmp2
        beq error
        lda (strbuf),y
        iny
        cmp #$5c                ; backslash
        beq loop1
        cmp #'u'
        beq unicode
error:  sec
        rts
unicode:
        jsr read4hexintosreg
        bcs error
        jsr movesregtolong1
        lda (strbuf),y
        cpy tmp2
        beq bmp
        cmp #$5c                ; backslash
        bne bmp
        iny
        cpy tmp2
        beq bmp0
        lda (strbuf),y
        cmp #'u'
        beq check_surrogate
bmp0:   dey
bmp:    jsr long1toutf8
        jmp loop
bmp1:   pla
        tay
        jmp bmp
check_surrogate:
        jsr is_sreg_left_surrogate
        bcc bmp0
        tya
        sub #1
        pha
        jsr read4hexintosreg
        bcs bmp1
        jsr is_sreg_right_surrogate
        bcc bmp1
        pla
        jsr combine_surrogates
        jmp bmp
done:   lda tmp1
        putstate st::str_idx
        clc
        rts
.endproc                ; unescape_unicode

;; reads 4 hex digs from strbuf at y into sreg.
;; (buffer length is in tmp2)
;; on success, carry clear, leaves y pointing after 4 digs.
;; on failure, carry set.
.proc read4hexintosreg
        ldx #4
loop:   jsr shift_sreg_left_4bits
        jsr or1hexintosreg
        bcs done
        dex
        bne loop
        clc
done:   rts
.endproc                ; read4hexintosreg

;; clobbers a, preserves x and y.
.proc shift_sreg_left_4bits
        lda sreg
        asl a
        rol sreg+1
        asl a
        rol sreg+1
        asl a
        rol sreg+1
        asl a
        rol sreg+1
        sta sreg
        rts
.endproc                ; shift_sreg_left_4bits

;; reads 1 hex dig from strbuf at y into low 4 bits of sreg.
;; (buffer length is in tmp2)
;; on success, carry clear, leaves y pointing after digit.
;; on failure, carry set.
.proc or1hexintosreg
        cpy tmp2
        beq fail
        lda (strbuf),y
        iny
        jsr hex_dig_to_nibble
        bcs fail
        ora sreg
        sta sreg
        clc
        rts
fail:   sec
        rts
.endproc                ; and1hexintosreg

;; converts ascii char in a to nibble in a.
;; sets carry if not a hex digit.
;; preserves x and y.
.proc hex_dig_to_nibble
        cmp #'0'
        blt fail
        cmp #'9'+1
        bge tryupper
        sub #'0'
        clc
        rts
tryupper:
        cmp #'A'
        blt fail
        cmp #'F'+1
        bge trylower
        sub #'A'-10
        clc
        rts
trylower:
        cmp #'a'
        blt fail
        cmp #'f'+1
        bge fail
        sub #'a'-10
        clc
        rts
fail:   sec
        rts
.endproc                ; hex_dig_to_nibble

;; zero-extends sreg into long1.
;; clobbers a, preserves x and y
.proc movesregtolong1
        lda sreg
        sta long1
        lda sreg+1
        sta long1+1
        lda #0
        sta long1+2
        sta long1+3
        rts
.endproc                ; movesregtolong1

;; converts long1 to utf8 in strbuf at tmp1.
;; (output index is in tmp1)
;; preserves y.
.proc long1toutf8
        sty tmp0
        ldy tmp1
        lda long1+2
        bne len4
        lda long1+1
        beq latin1
        cmp #8
        bge len3
len2:   ldx #1
        jsr shift_left_by_2
        lda long1
        and #%00111111
        ora #%10000000
        sta long1
        lda long1+1
        and #%00011111
        ora #%11000000
        sta long1+1
        ldx #1
        jmp done
len3:   ldx #1
        jsr shift_left_by_2
        ldx #2
        jsr shift_left_by_2
        lda long1
        and #%00111111
        ora #%10000000
        sta long1
        lda long1+1
        and #%00111111
        ora #%10000000
        sta long1+1
        lda long1+2
        and #%00001111
        ora #%11100000
        sta long1+2
        ldx #2
        jmp done
len4:   ldx #1
        jsr shift_left_by_2
        ldx #2
        jsr shift_left_by_2
        ldx #3
        jsr shift_left_by_2
        lda long1
        and #%00111111
        ora #%10000000
        sta long1
        lda long1+1
        and #%00111111
        ora #%10000000
        sta long1+1
        lda long1+2
        and #%00111111
        ora #%10000000
        sta long1+2
        lda long1+3
        and #%00000111
        ora #%11110000
        sta long1+3
        ldx #3
        jmp done
latin1: lda long1
        bmi len2
        ldx #0                  ; length 1, already in the right format
done:   jsr writeutf8
        sty tmp1
        ldy tmp0
        rts
.endproc                ; long1toutf8

;; writes the first x+1 bytes of long1, in reverse order,
;; to strbuf, starting at y.  advances y.
;; clobbers a, x.
.proc writeutf8
        lda long1,x
        sta (strbuf),y
        iny
        dex
        bpl writeutf8
        rts
.endproc                ; writeutf8

;; shift the last 4-x bytes of long1 left by 2 bits.
;; clobbers a, x.  preserves y.
.proc shift_left_by_2
        stx tmp5
        jsr shift_left_by_1
        ldx tmp5
shift_left_by_1:
        asl long1,x
loop:   php
        cpx #3
        beq done
        inx
        plp
        rol long1,x
        jmp loop
done:   plp
        rts
.endproc                ; shift_left_by_2

;; preserves y.
;; sets carry if sreg is a left surrogate.
.proc is_sreg_left_surrogate
        lda sreg+1
        and #$fc
        cmp #$d8
        beq yes
        clc
        rts
yes:    sec
        rts
.endproc                ; is_sreg_left_surrogate

;; preserves y.
;; sets carry if sreg is a right surrogate.
.proc is_sreg_right_surrogate
        lda sreg+1
        and #$fc
        cmp #$dc
        beq yes
        clc
        rts
yes:    sec
        rts
.endproc                ; is_sreg_right_surrogate

;; combine left surrogate in long1 with right surrogate in sreg.
;; result in long1.  preserves y.
.proc combine_surrogates
        lda long1+1
        and #3
        sta long1+2
        lda long1
        sta long1+1
        asl long1+1
        rol long1+2
        asl long1+1
        rol long1+2
        lda sreg
        sta long1
        lda sreg+1
        and #3
        ora long1+1
        sta long1+1
        inc long1+2
        rts
.endproc

;; parse signed integer in strbuf (length in str_idx).
;; on success, carry clear and result in long1 (regsave).
;; on integer overflow, carry set and overflow set.
;; on illegal character, carry set and overflow clear.
;; clobbers a and x, preserves y.
;; FIXME: might not need to preserve y?
.proc parse_signed_integer
        tya
        pha
        ldy #0
        lda (strbuf),y
        cmp #'-'
        beq negative
        jsr parse_unsigned_integer
done:   pla
        tay
        rts
negative:
        iny
        jsr parse_unsigned_integer
        bcs done
        jsr resteax
        jsr negeax
        jsr saveeax
        clc
        jmp done
.endproc                ; parse_signed_integer

;; parse unsigned integer in strbuf, starting at y.
;; (although "unsigned", result greater than 0x7fffffff is considered
;; an error.)
;; on success, carry clear and result in long1 (regsave).
;; on integer overflow, carry set and overflow set.
;; on illegal character, carry set and overflow clear.
;; clobbers a, x, and y.  FIXME: doesn't seem to actually clobber x?
.proc parse_unsigned_integer
        lda #0
        sta long1
        sta long1+1
        sta long1+2
        sta long1+3
loop:   tya
        ldy #st::str_idx
        cmp (state),y
        bge done
        tay
        jsr multiply_long1_by_10
        bcs overflow
        lda (strbuf),y
        jsr hex_dig_to_nibble
        bcs error
        jsr add_a_to_long1
        bcs overflow
        iny
        lda long1+3             ; overflow if we go over 0x7fffffff
        bpl loop
overflow:
        bit an_rts              ; bit on an rts instruction will set overflow
        sec
an_rts: rts
done:   clc
        rts
error:  clv
        sec
        rts
.endproc                ; parse_unsigned_integer

;; multiplies long1 by 10. clobbers a and long2. preserves x y.
;; returns with carry set if result overflows a 32-bit unsigned long.
.proc multiply_long1_by_10
        jsr shift_long1_left_by_1
        bcs done
        lda long1
        sta long2
        lda long1+1
        sta long2+1
        lda long1+2
        sta long2+2
        lda long1+3
        sta long2+3
        jsr shift_long1_left_by_1
        bcs done
        jsr shift_long1_left_by_1
        bcs done
        lda long1
        add long2
        sta long1
        lda long1+1
        adc long2+1
        sta long1+1
        lda long1+2
        adc long2+2
        sta long1+2
        lda long1+3
        adc long2+3
        sta long1+3
done:   rts
.endproc                ; multiply_long1_by_10

;; shifts long1 left by 1.  clobbers a; preserves x and y.
.proc shift_long1_left_by_1
        asl long1
        rol long1+1
        rol long1+2
        rol long1+3
        rts
.endproc                ; shift_long1_left_by_1

;; add a to long1.  sets carry if result overflows an unsigned long.
;; clobbers a; preserves x and y.
.proc add_a_to_long1
        add long1
        sta long1
        lda long1+1
        adc #0
        sta long1+1
        lda long1+2
        adc #0
        sta long1+2
        lda long1+3
        adc #0
        sta long1+3
        rts
.endproc                ; add_a_to_long1

;; parse "null", "false", or "true" in strbuf (length in str_idx).
;; on success, carry clear and a contains event number.
;; on failure, carry set.  clobbers x and y.
.proc identify_literal
        getstate st::str_idx
        cmp #4
        beq len4
        cmp #5
        beq len5
fail:   sec
        rts
len4:   lda #<str_null
        ldx #>str_null
        ldy #3
        jsr compare_strings
        beq got_null
        lda #<str_true
        ldx #>str_true
        ldy #3
        jsr compare_strings
        bne fail
        lda #J65_TRUE
        clc
        rts
got_null:
        lda #J65_NULL
        clc
        rts
len5:   lda #<str_false
        ldx #>str_false
        ldy #4
        jsr compare_strings
        bne fail
        lda #J65_FALSE
        clc
        rts

        .rodata
str_null:
        .byte "null"
str_true:
        .byte "true"
str_false:
        .byte "false"
        .code

.endproc                ; identify_literal

;; compares string (of length y+1) at strbuf with string pointed to
;; by a (lo byte) and x (hi byte).
;; returns with zero flag set if strings match, or zero flag clear
;; if they do not.
;; clobbers ptr1.
.proc compare_strings
        sta ptr1
        stx ptr1+1
loop:   lda (strbuf),y
        cmp (ptr1),y
        bne done
        dey
        bpl loop
        lda #0                  ; set zero flag
done:   rts
.endproc                    ; compare_strings

;; Handle a literal (a number, or null, true, or false).
;; On entry, a should contain flags.  (prop_lit, prop_int, prop_num)
;; Clobbers all registers.
;; On success, returns carry clear.
;; On error, returns carry set with error event in a.
.proc handle_literal
        tax
        getstate st::parser_st
        cmp #par_ready
        beq p_ready
        cmp #par_ready_or_close_array
        beq p_ready
parse_err:
        lda #J65_PARSE_ERROR
        sec
        rts                     ; error exit
p_ready:
        txa
        bit flags_prop_lit
        beq keyword
        bit flags_prop_int
        beq integer
number: jsr string_in_regsave
        lda #J65_NUMBER
do_callback:
        sta evtype
        jsr call_callback
        getstate st::parser_st2 ; get next parser state in a
        putstate st::parser_st
        clc
        rts                     ; success exit
integer:
        jsr parse_signed_integer
        bcs not_integer
        lda #J65_INTEGER
        jmp do_callback
not_integer:
        bvs number
        jmp parse_err
keyword:
        jsr identify_literal
        bcs parse_err
        jmp do_callback

        .rodata
flags_prop_lit:
        .byte prop_lit
flags_prop_int:
        .byte prop_int
        .code

.endproc                ; handle_literal

;; push a onto the state stack.
;; carry clear on success.
;; carry set on error, with error event in a.
;; clobbers x, y.
.proc push_state_stack
        tax
        getstate st::stack_idx
        ldy #st::stack_min
        cmp (state),y
        blt stack_full
        tay
        txa
        sta (state),y
        dey
        tya
        putstate st::stack_idx
        clc
        rts
stack_full:
        lda #J65_NESTING_TOO_DEEP
        sec
        rts
.endproc                ; push_state_stack

;; pop the state stack.
;; carry clear on success, with popped state in a.
;; carry set on error, with error event in a.
;; clobbers x, y.
.proc pop_state_stack
        getstate st::stack_idx
        tay
        iny
        beq stack_empty
        lda (state),y
        tax
        tya
        putstate st::stack_idx
        txa
        clc
        rts
stack_empty:
        lda #J65_PARSE_ERROR
        sec
        rts
.endproc                ; pop_state_stack
