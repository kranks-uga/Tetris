BITS 64
W equ 10
H equ 20

section .data
; 7 фигур × 4 поворота, каждая — маска 4×4 в 16 битах.
; Бит (0x8000 >> i) соответствует клетке x = i & 3, y = i >> 2
pieces: dw 0x0F00,0x2222,0x00F0,0x4444   ; I
        dw 0x44C0,0x8E00,0x6440,0x0E20   ; J
        dw 0x4460,0x0E80,0xC440,0x2E00   ; L
        dw 0xCC00,0xCC00,0xCC00,0xCC00   ; O
        dw 0x06C0,0x8C40,0x6C00,0x4620   ; S
        dw 0x0E40,0x4C40,0x4E00,0x4640   ; T
        dw 0x0C60,0x4C80,0xC600,0x2640   ; Z

s_init:     db 27,"[2J",27,"[?25l"            ; очистить экран, спрятать курсор
s_init_len  equ $-s_init
s_home:     db 27,"[H"                        ; курсор в левый верхний угол
s_home_len  equ $-s_home
s_rowend:   db 27,"[0m!>",13,10
s_rowend_len equ $-s_rowend
s_bottom:   db "<!====================!>",13,10,"Счет: "
s_bottom_len equ $-s_bottom
s_help:     db "    ",13,10,"a/d— перемещение, w — поворот, s — вниз, пробел — сброс, q — выход",13,10
s_help_len  equ $-s_help
s_fini:     db 27,"[0m",27,"[2J",27,"[H",27,"[?25h"
s_fini_len  equ $-s_fini
; экран конца игры — поверх середины поля
s_over:     db 27,"[0m"
            db 27,"[9;3H",  "                    "
            db 27,"[10;3H", "   Игра окончена!   "
            db 27,"[11;3H", "                    "
            db 27,"[12;3H", "    Enter - меню    "
            db 27,"[13;3H", "     Q - выход      "
            db 27,"[14;3H", "                    "
s_over_len  equ $-s_over

; --- меню ---
s_menu:     db 27,"[3;8H","T E T R I S"
            db 27,"[9;2H","A/D - изменить скорость"
            db 27,"[10;2H","Enter - старт   Q - выход"
            db 27,"[6;2H","Скорость:  < "           ; дальше — значение
s_menu_len  equ $-s_menu
sp_slow:    db "Медленно"
sp_slow_len equ $-sp_slow
sp_norm:    db "Нормально"
sp_norm_len equ $-sp_norm
sp_fast:    db "Быстро"
sp_fast_len equ $-sp_fast
; пары (адрес, длина) по 16 байт
speed_tab:  dq sp_slow, sp_slow_len, sp_norm, sp_norm_len, sp_fast, sp_fast_len
fall_tab:   dd 15, 10, 5                      ; тиков на шаг падения для каждой скорости
speed:      dd 1                              ; выбранная скорость (по умолчанию нормальная)

timespec:   dq 0, 50000000                    ; тик = 50 мс

section .bss
board:  resb W*H        ; 0 — пусто, 1..7 — цвет
frame:  resb W*H        ; board + текущая фигура, для отрисовки
orig_t: resb 64         ; struct termios (ядро: 36 байт)
raw_t:  resb 64
keys:   resb 16
outbuf: resb 8192
numbuf: resb 24
piece:  resd 1
rot:    resd 1
px:     resd 1
py:     resd 1
score:  resd 1
ticks:  resd 1
fall:   resd 1          ; тиков на шаг падения (из меню)
seed:   resq 1

section .text
global _start

; ---------------------------------------------------------------
; fits: ebx = rot, esi = x, edi = y (piece берётся из [piece])
; -> eax = 1, если фигура помещается. Портит ecx, r8-r10
fits:
    mov eax, [piece]
    lea eax, [eax*4+ebx]
    movzx r8d, word [pieces+rax*2]
    xor ecx, ecx
.loop:
    mov eax, 0x8000
    shr eax, cl
    test r8d, eax
    jz .next
    mov r9d, ecx
    and r9d, 3
    add r9d, esi            ; x клетки
    mov r10d, ecx
    shr r10d, 2
    add r10d, edi           ; y клетки
    cmp r9d, W
    jae .no                 ; беззнаковое сравнение ловит и x < 0
    cmp r10d, H
    jge .no
    test r10d, r10d
    js .next                ; выше поля — можно
    imul eax, r10d, W
    add eax, r9d
    cmp byte [board+rax], 0
    jne .no
.next:
    inc ecx
    cmp ecx, 16
    jb .loop
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; ---------------------------------------------------------------
; place: rdi = буфер (board или frame), рисует туда текущую фигуру
place:
    mov eax, [piece]
    mov edx, [rot]
    lea eax, [eax*4+edx]
    movzx r8d, word [pieces+rax*2]
    mov r11d, [piece]
    inc r11d                ; цвет 1..7
    xor ecx, ecx
.loop:
    mov eax, 0x8000
    shr eax, cl
    test r8d, eax
    jz .next
    mov r9d, ecx
    shr r9d, 2
    add r9d, [py]
    js .next
    imul r9d, r9d, W
    mov r10d, ecx
    and r10d, 3
    add r10d, [px]
    add r9d, r10d
    mov [rdi+r9], r11b
.next:
    inc ecx
    cmp ecx, 16
    jb .loop
    ret

; ---------------------------------------------------------------
; try_move: ebx = новый rot, esi = dx, edi = dy -> eax = 1, если сдвинули
try_move:
    add esi, [px]
    add edi, [py]
    call fits
    test eax, eax
    jz .ret
    mov [rot], ebx
    mov [px], esi
    mov [py], edi
.ret:
    ret

; ---------------------------------------------------------------
; clear_lines: удаляет заполненные строки, сдвигая всё выше вниз
clear_lines:
    mov r8d, H-1
.row:
    imul eax, r8d, W
    lea rsi, [board+rax]
    xor ecx, ecx
.chk:
    cmp byte [rsi+rcx], 0
    je .notfull
    inc ecx
    cmp ecx, W
    jb .chk
    inc dword [score]
    lea rdi, [rsi+W-1]      ; копируем строки 0..y-1 на 1..y, с конца
    dec rsi
    mov ecx, eax            ; y*W байт
    std
    rep movsb
    cld
    mov rdi, board          ; верхнюю строку обнуляем
    mov ecx, W
    xor eax, eax
    rep stosb
    jmp .row                ; та же строка ещё раз — туда съехала новая
.notfull:
    dec r8d
    jns .row
    ret

; ---------------------------------------------------------------
; rand7: xorshift64 -> eax в 0..6
rand7:
    mov rax, [seed]
    mov rdx, rax
    shl rdx, 13
    xor rax, rdx
    mov rdx, rax
    shr rdx, 7
    xor rax, rdx
    mov rdx, rax
    shl rdx, 17
    xor rax, rdx
    mov [seed], rax
    xor edx, edx
    mov ecx, 7
    div rcx
    mov eax, edx
    ret

; spawn: новая фигура сверху -> eax = 0, если не влезла (game over)
spawn:
    call rand7
    mov [piece], eax
    mov dword [rot], 0
    mov dword [px], 3
    mov dword [py], 0
    xor ebx, ebx
    mov esi, 3
    xor edi, edi
    jmp fits

; itoa: eax -> десятичная строка по адресу rdi (rdi сдвигается)
itoa:
    mov ecx, 10
    lea r9, [numbuf+23]
    mov r10, r9
.l: xor edx, edx
    div ecx
    add dl, '0'
    dec r9
    mov [r9], dl
    test eax, eax
    jnz .l
    mov rsi, r9
    mov rcx, r10
    sub rcx, r9
    rep movsb
    ret

; ---------------------------------------------------------------
; draw: собирает кадр в outbuf и выводит одним write
draw:
    mov rsi, board
    mov rdi, frame
    mov ecx, W*H
    rep movsb
    mov rdi, frame
    call place

    mov rdi, outbuf
    mov rsi, s_home
    mov ecx, s_home_len
    rep movsb
    xor r8d, r8d            ; индекс клетки
.rowstart:
    mov ax, '<!'
    stosw
    xor r9d, r9d
.cell:
    movzx edx, byte [frame+r8]
    mov al, 27              ; ESC [ 9 <цвет> m : 90 серый, 91..97 яркие
    stosb
    mov al, '['
    stosb
    mov al, '9'
    stosb
    lea eax, [edx+'0']
    stosb
    mov al, 'm'
    stosb
    mov ax, ' .'
    test edx, edx
    jz .empty
    mov ax, '[]'
.empty:
    stosw
    inc r8d
    inc r9d
    cmp r9d, W
    jb .cell
    mov rsi, s_rowend
    mov ecx, s_rowend_len
    rep movsb
    cmp r8d, W*H
    jb .rowstart

    mov rsi, s_bottom
    mov ecx, s_bottom_len
    rep movsb
    mov eax, [score]
    call itoa
    mov rsi, s_help
    mov ecx, s_help_len
    rep movsb
    ; дальше — flush

; flush: выводит outbuf до rdi одним write
flush:
    mov rdx, rdi
    sub rdx, outbuf
    mov eax, 1              ; write(1, outbuf, len)
    mov edi, 1
    mov rsi, outbuf
    syscall
    ret

; wait_keys: ждёт нажатия -> eax = сколько байт прочитано в keys
wait_keys:
    xor eax, eax            ; read(0, keys, 16)
    xor edi, edi
    mov rsi, keys
    mov edx, 16
    syscall
    test eax, eax
    jg .ret
    mov eax, 35             ; ничего не нажато — подождать
    mov rdi, timespec
    xor esi, esi
    syscall
    jmp wait_keys
.ret:
    ret

; ---------------------------------------------------------------
; menu: стартовый экран. A/D (стрелки ←/→) — скорость, Enter/пробел — старт.
; Пишет скорость в fall -> eax = 1, если нажата q, иначе 0
menu:
.draw:
    mov rdi, outbuf
    mov rsi, s_init
    mov ecx, s_init_len
    rep movsb
    mov rsi, s_menu
    mov ecx, s_menu_len
    rep movsb
    mov eax, [speed]
    shl eax, 4
    mov rsi, [speed_tab+rax]
    mov ecx, [speed_tab+rax+8]
    rep movsb
    mov ax, ' >'
    stosw
    call flush

    call wait_keys
    mov r14d, eax
    xor r13d, r13d
.key:
    cmp r13d, r14d
    jae .draw
    movzx eax, byte [keys+r13]
    inc r13d
    cmp al, 27
    jne .plain
    lea ecx, [r13+1]        ; стрелки: ESC [ C — вправо, ESC [ D — влево
    cmp ecx, r14d
    jae .key
    cmp byte [keys+r13], '['
    jne .key
    movzx eax, byte [keys+r13+1]
    add r13d, 2
    cmp al, 'C'
    je .right
    cmp al, 'D'
    je .left
    jmp .key
.plain:
    cmp al, 'q'
    je .quit
    cmp al, 10              ; Enter
    je .start
    cmp al, 13
    je .start
    cmp al, ' '
    je .start
    cmp al, 'a'
    je .left
    cmp al, 'd'
    je .right
    jmp .key
.left:
    dec dword [speed]
    jns .key
    mov dword [speed], 2    ; по кругу: на последнее значение
    jmp .key
.right:
    inc dword [speed]
    cmp dword [speed], 3
    jb .key
    mov dword [speed], 0    ; по кругу: на первое значение
    jmp .key

.start:
    mov eax, [speed]        ; скорость -> тиков на шаг падения
    mov eax, [fall_tab+rax*4]
    mov [fall], eax
    xor eax, eax
    ret
.quit:
    mov eax, 1
    ret

; ---------------------------------------------------------------
_start:
    ; сохраняем настройки терминала и включаем «сырой» режим
    mov eax, 16             ; ioctl(0, TCGETS, &orig_t)
    xor edi, edi
    mov esi, 0x5401
    mov rdx, orig_t
    syscall
    mov rsi, orig_t
    mov rdi, raw_t
    mov ecx, 64
    rep movsb
    and dword [raw_t+12], ~(2|8)    ; c_lflag &= ~(ICANON | ECHO)
    mov byte [raw_t+17+5], 0        ; c_cc[VTIME] = 0
    mov byte [raw_t+17+6], 0        ; c_cc[VMIN]  = 0 -> read не блокирует
    mov eax, 16             ; ioctl(0, TCSETS, &raw_t)
    xor edi, edi
    mov esi, 0x5402
    mov rdx, raw_t
    syscall

    rdtsc                   ; зерно для ГПСЧ
    shl rdx, 32
    or rax, rdx
    or rax, 1
    mov [seed], rax

new_game:                   ; сюда же возвращаемся после конца партии
    mov rdi, board
    mov ecx, W*H
    xor eax, eax
    rep stosb
    mov [score], eax
    mov [ticks], eax
    call menu
    test eax, eax
    jnz .quit

    mov eax, 1
    mov edi, 1
    mov rsi, s_init
    mov edx, s_init_len
    syscall
    call spawn

.loop:
    call draw
    mov eax, 35             ; nanosleep(&timespec, NULL)
    mov rdi, timespec
    xor esi, esi
    syscall

    xor eax, eax            ; read(0, keys, 16)
    xor edi, edi
    mov rsi, keys
    mov edx, 16
    syscall
    test eax, eax
    jle .gravity
    mov r12d, eax
    xor r13d, r13d
.key:
    movzx eax, byte [keys+r13]
    mov ebx, [rot]
    xor esi, esi
    xor edi, edi
    cmp al, 'q'
    je .quit
    cmp al, 'a'
    jne .k1
    mov esi, -1
    call try_move
    jmp .knext
.k1:
    cmp al, 'd'
    jne .k2
    mov esi, 1
    call try_move
    jmp .knext
.k2:
    cmp al, 'w'
    jne .k3
    inc ebx
    and ebx, 3
    call try_move
    jmp .knext
.k3:
    cmp al, 's'
    jne .k4
    mov edi, 1
    call try_move
    jmp .knext
.k4:
    cmp al, ' '
    jne .knext
.drop:                      ; роняем, пока получается
    mov ebx, [rot]
    xor esi, esi
    mov edi, 1
    call try_move
    test eax, eax
    jnz .drop
    mov dword [ticks], 100  ; фиксируем на ближайшем шаге гравитации
.knext:
    inc r13d
    cmp r13d, r12d
    jb .key

.gravity:
    inc dword [ticks]
    mov eax, [fall]         ; падение раз в fall тиков (10 = 0.5 с)
    cmp [ticks], eax
    jb .loop
    mov dword [ticks], 0
    mov ebx, [rot]
    xor esi, esi
    mov edi, 1
    call try_move
    test eax, eax
    jnz .loop
    mov rdi, board          ; упали на дно — впечатываем в поле
    call place
    call clear_lines
    call spawn
    test eax, eax
    jnz .loop

    ; конец игры: Enter — в меню, q — выход.
    ; Пробел не принимаем: он мог остаться зажатым после сброса фигуры
    call draw
    mov eax, 1
    mov edi, 1
    mov rsi, s_over
    mov edx, s_over_len
    syscall
.over_wait:
    call wait_keys
    mov r12d, eax
    xor r13d, r13d
.over_key:
    movzx eax, byte [keys+r13]
    cmp al, 'q'
    je .quit
    cmp al, 10
    je new_game
    cmp al, 13
    je new_game
    inc r13d
    cmp r13d, r12d
    jb .over_key
    jmp .over_wait

.quit:
    mov eax, 16             ; восстанавливаем терминал
    xor edi, edi
    mov esi, 0x5402
    mov rdx, orig_t
    syscall
    mov eax, 1
    mov edi, 1
    mov rsi, s_fini
    mov edx, s_fini_len
    syscall
    mov eax, 60             ; exit(0)
    xor edi, edi
    syscall
