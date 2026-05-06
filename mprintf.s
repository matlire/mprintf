section .text

default rel             ; Default position independent code

extern printf
global mprintf

%define STDCALL_WRITE 1
%define FD_stdout     1

%define BUF_CAP     256 ; Output buffer size
%define NUMBUF_LEN  66  ; 64 + sign + 1
%define REG_ARGS    5   ; rsi, rdx, rcx, r8, r9

; Jump table index range
%define JT_FIRST '%'
%define JT_LAST  'x'
%define JT_RANGE (JT_LAST - JT_FIRST)

struc Frame
    .orig_rax resq 1    ; al = number of vector registers used for floating point args
    .orig_rdi resq 1
    .orig_rsi resq 1
    .orig_rdx resq 1
    .orig_rcx resq 1
    .orig_r8  resq 1
    .orig_r9  resq 1

    .regargs   resq REG_ARGS
    .stackptr  resq 1        ; First stack-passed arg
    .arg_index resq 1        ; How many args consumed

    .numbuf resb NUMBUF_LEN
    .outbuf resb BUF_CAP
endstruc

%assign FRAME_BYTES ((Frame_size + 15) & ~15) ; Round Frame to up to *16 for stack alignment

; Here: rbx = base of local Frame, r12 = outbuf current pointer, r13 = current format pointer, r14 = current buffered len
; If outbuf is full, flush it
%macro PUT_AL 0
    mov [r12], al
    inc r12
    inc r14
    cmp r14, BUF_CAP
    jne %%ok
    call flush_buffer
%%ok:
%endmacro

; Put constant char to buffer
%macro PUT_IMM 1
    mov al, %1
    PUT_AL
%endmacro

next_arg:
    mov rcx, [rbx + Frame.arg_index]
    inc qword [rbx + Frame.arg_index]

    cmp ecx, REG_ARGS
    jae .from_stack

    mov rax, [rbx + Frame.regargs + rcx * 8]
    ret

.from_stack:
    sub rcx, REG_ARGS
    mov rdx, [rbx + Frame.stackptr]
    mov rax, [rdx + rcx * 8]
    ret

emit_cstring:
    mov r8, rsi                     ; rsi = pointer to c string
    mov rdi, rsi
    xor eax, eax
    mov rcx, -1
    repne scasb                     ; Repeat Not Equal, Scan String Byte - compare al with es:edi, edi++, ecx-- until match/end
    not rcx
    dec rcx
    mov rsi, r8
    mov rdx, rcx
    jmp emit_mem

emit_mem:
    test rdx, rdx
    jz .emit_mem_done

.copy_loop:
    mov rax, BUF_CAP
    sub rax, r14
    jnz .have_room

    call flush_buffer
    mov eax, BUF_CAP

.have_room:
    cmp rdx, rax
    jbe .take_rest

.take_chunk:
    mov rcx, rax
    mov rdi, r12
    rep movsb
    mov r12, rdi
    add r14, rax
    sub rdx, rax
    jnz .copy_loop
    ret

.take_rest:
    mov rax, rdx
    jmp .take_chunk

.emit_mem_done:
    ret

; IN:  rax - signed 32 bit int, sign extended to 64 bytes, rdi - destination buffer
; OUT: rsi - start of produced characters, rdx - length
fmt_dec32:
    mov rsi, rdi
    xor r8d, r8d

    test rax, rax
    jns .abs_ready
    neg rax
    mov r8b, 1
.abs_ready:
    test eax, eax
    jnz .loop

    dec rsi
    mov byte [rsi], '0'
    mov edx, 1
    ret
.loop:
    xor edx, edx
    mov ecx, 10
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test eax, eax
    jne .loop
    
    test r8b, r8b
    jz .dec32_done
    dec rsi
    mov byte [rsi], '-'

.dec32_done:
    mov rdx, rdi
    sub rdx, rsi
    ret

; For macoro IN: func name; bits per digit; digit mask; symbols
; IN:  eax - u32 bit value; rdi - ptr to end of destination buffer
; OUT: rsi - ptr to first proccessed char; rdx - length of produced string
%macro DEFINE_FMT_U32_P2 4
%1:
    mov rsi, rdi
    lea r10, [rel %4]

    test eax, eax
    jnz %%loop

    dec rsi
    mov byte [rsi], '0'
    mov edx, 1
    ret

%%loop:
    dec rsi
    mov r9d, eax
    and r9d, %3             ; Extract lower digits
    mov r11b, [r10 + r9]
    mov [rsi], r11b
    shr eax, %2
    jne %%loop

    mov rdx, rdi
    sub rdx, rsi
    ret
%endmacro

DEFINE_FMT_U32_P2 fmt_bin32,    1,  1,  bin_digits
DEFINE_FMT_U32_P2 fmt_oct32,    3,  7,  hex_digits_lo
DEFINE_FMT_U32_P2 fmt_hex_lo32, 4, 15,  hex_digits_lo
DEFINE_FMT_U32_P2 fmt_hex_hi32, 4, 15,  hex_digits_hi

%macro HANDLE_SIGNED_NUMS_SPEC 1
    call next_arg
    movsxd rax, eax
    lea rdi, [rbx + Frame.numbuf + NUMBUF_LEN]
    call %1
    call emit_mem
    jmp .parse_loop
%endmacro

%macro HANDLE_UNSIGNED_NUMS_SPEC 1
    call next_arg
    mov eax, eax
    lea rdi, [rbx + Frame.numbuf + NUMBUF_LEN]
    call %1
    call emit_mem
    jmp .parse_loop
%endmacro

mprintf:
    push rbp                        ; rbp = frame pointer 
    mov rbp, rsp
    push rbx 
    push r12 
    push r13 
    push r14
    sub rsp, FRAME_BYTES            ; Reserve mem for Frame

    cld
    lea rbx, [rbp - FRAME_BYTES]    ; rbx = base address of Frame

    ; Save original incoming registers
    mov [rbx + Frame.orig_rax], rax
    mov [rbx + Frame.orig_rdi], rdi
    mov [rbx + Frame.orig_rsi], rsi
    mov [rbx + Frame.orig_rdx], rdx
    mov [rbx + Frame.orig_rcx], rcx
    mov [rbx + Frame.orig_r8 ], r8
    mov [rbx + Frame.orig_r9 ], r9

    ; Trampoline: spill register-passed varargs into memory
    mov [rbx + Frame.regargs +  0], rsi
    mov [rbx + Frame.regargs +  8], rdx
    mov [rbx + Frame.regargs + 16], rcx
    mov [rbx + Frame.regargs + 24], r8
    mov [rbx + Frame.regargs + 32], r9

    lea rax, [rbp + 16]                 ; rbp + 16 = first arg
    mov [rbx + Frame.stackptr], rax
    mov qword [rbx + Frame.arg_index], 0

    mov r13, rdi                        ; Current format string pointer
    lea r12, [rbx + Frame.outbuf]
    xor r14d, r14d

.parse_loop:
    mov al, [r13]
    inc r13
    test al, al
    jz .print_done

    cmp al, '%'
    jne .literal_char

    mov al, [r13]
    test al, al
    jz .dangling_percent
    inc r13

    movzx edx, al                       ; ASCII byte -> integer index
    sub edx, JT_FIRST                   ; Rebase index (for example '%' -> 0)
    cmp edx, JT_RANGE
    ja .spec_unknown
    
    ; Load address from jump table
    lea r8, [rel spec_table]
    jmp qword [r8 + rdx*8]

.literal_char:
    PUT_AL
    jmp .parse_loop

.dangling_percent:
    PUT_IMM '%'
    jmp .print_done

.spec_percent:
    PUT_IMM '%'
    jmp .parse_loop

.spec_c:
    call next_arg
    PUT_AL
    jmp .parse_loop

.spec_s:
    call next_arg
    mov rsi, rax
    test rsi, rsi
    jnz .have_string
    lea rsi, [rel null_text]
.have_string:
    call emit_cstring
    jmp .parse_loop

.spec_d:
    HANDLE_SIGNED_NUMS_SPEC fmt_dec32

.spec_o:
    HANDLE_UNSIGNED_NUMS_SPEC fmt_oct32

.spec_b:
    HANDLE_UNSIGNED_NUMS_SPEC fmt_bin32

.spec_x:
    HANDLE_UNSIGNED_NUMS_SPEC fmt_hex_hi32

.spec_X:
    HANDLE_UNSIGNED_NUMS_SPEC fmt_hex_hi32

.spec_unknown:
    PUT_IMM '%'
    PUT_AL
    jmp .parse_loop

.print_done:
    call flush_buffer
    
    mov rax, [rbx + Frame.orig_rax]
    mov rdi, [rbx + Frame.orig_rdi]
    mov rsi, [rbx + Frame.orig_rsi]
    mov rdx, [rbx + Frame.orig_rdx]
    mov rcx, [rbx + Frame.orig_rcx]
    mov r8 , [rbx + Frame.orig_r8 ]
    mov r9 , [rbx + Frame.orig_r9 ]

    add rsp, FRAME_BYTES
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp

    jmp printf wrt ..plt ; Find in procedure linking table
    
    ret

flush_buffer:
    test r14, r14
    jz .reset_only
    lea rsi, [rbx + Frame.outbuf]
    mov rdx, r14

.write_again:
    mov eax, STDCALL_WRITE
    mov edi, FD_stdout
    syscall                 ; rax - syscall num, rdi - fd, rsi - buf, rdx - count
    cmp rax, 0
    jle .reset_only
    sub rdx, rax
    add rsi, rax
    jne .write_again

.reset_only:
    lea r12, [rbx + Frame.outbuf]
    xor r14d, r14d
    ret

section .rodata

null_text       db "(null)", 0
bin_digits      db "01"
hex_digits_lo   db "0123456789abcdef"
hex_digits_hi   db "0123456789ABCDEF"

section .data

spec_table:
    dq mprintf.spec_percent
    dq 50 dup(mprintf.spec_unknown)
    dq mprintf.spec_X
    dq 9  dup(mprintf.spec_unknown)
    dq mprintf.spec_b
    dq mprintf.spec_c
    dq mprintf.spec_d
    dq 10 dup(mprintf.spec_unknown)
    dq mprintf.spec_o
    dq 3  dup(mprintf.spec_unknown)
    dq mprintf.spec_s
    dq 4  dup(mprintf.spec_unknown)
    dq mprintf.spec_x

section .note.GNU-stack noalloc noexec nowrite progbits
