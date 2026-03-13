;//////////////////////////////////////////////////////////////////////
;//                                                                  //
;// Tandberg TDV-5000 series 968551 v2.1                             //
;//                                                                  //
;//   8051-based Firmware, running the TDV-5010 122-key keyboard     //
;//   from Tandber Data. This provides a MF2-type keyboard for the   //
;//   PS/2 interface, with support for some extra features like key- //
;//   click, key-locks and an AT/XT/Terminal mode toggle switch.     //
;//                                                                  //
;//                                 Dissasembled by Frodevan, 2023   //
;//                                                                  //
;//////////////////////////////////////////////////////////////////////

;////////////////////////////////////////
;//
;// Ports
;//

ROW_DATA                         DATA P0
ROW_SELECT                       DATA P1
LEDS_AND_JUMPERS                 DATA P2
DATA_AND_CLOCK                   DATA P3

;////////////////////////////////////////
;//
;// Port bitfields
;//

SPEAKER                          BIT P2.0
NUM_LOCK_INDICATOR               BIT P2.1
CAPS_LOCK_INDICATOR              BIT P2.2
SCROLL_LOCK_INDICATOR            BIT P2.3
KEYBOARD_MODE_JUMPER_ST1         BIT P2.4
KEYBOARD_MODE_JUMPER_ST2         BIT P2.5
DEFAULT_BEEP_JUMPER_ST3          BIT P2.6
NAVIGATION_NUMCASE_IGNORE_FLAG   BIT P2.7

SERIAL_CLOCK_TX                  BIT P3.0
SERIAL_DATA_TX                   BIT P3.1
SERIAL_CLOCK_RX                  BIT P3.2
SERIAL_DATA_RX                   BIT P3.3
DISABLE_SCANNING_FLAG            BIT P3.5
R_SHIFT_UP_PENDING               BIT P3.6
L_SHIFT_UP_PENDING               BIT P3.7



;//////////////////////////////////////////////////////////////////////
;//
;// Internal RAM layout
;//

DSEG AT 00h

;////////////////////////////////////////
;//
;// Main-loop registers
;//

scancode_tx_buffer_head_ptr:     DS 1
scancode_tx_buffer_tail_ptr:     DS 1
scancode_tx_queue_length:        DS 1
secondary_loop_counter:          DS 1
temporary_counter:               DS 1
previously_sent_byte:            DS 1
size_of_unsent_msg:              DS 1
keytype_flags:                   DS 1

;////////////////////////////////////////
;//
;// Scanning registers
;//

keystate_row_current_bitmap_ptr: DS 1
keystate_row_held_bitmap_ptr:    DS 1
row_counter:                     DS 1
number_of_keys_held:             DS 1
keystate_row_previous_bitmap:    DS 1
scancode_table_ptr_hi:           DS 1
latest_held_key_index:           DS 1
beep_duration:                   DS 1

;////////////////////////////////////////
;//
;// Stack
;//

stack_space:                     DS 17

;////////////////////////////////////////
;//
;// Variables
;//

keylocks_state:                  DS 1
keylocks_prev_state:             DS 1
keyup_key_index:                 DS 1
t1_ticks_since_last_tx:          DS 1
typematic_count:                 DS 1
keydown_key_index:               DS 1
scancode_table_ptr_lo:           DS 1
typematic_delay:                 DS 1
typematic_repeat_rate:           DS 1
prioritized_tx_byte:             DS 1
rx_byte:                         DS 1

;////////////////////////////////////////
;//
;// Data-tables
;//

bit_flags:                       DS 3
scancode_tx_queue:               DS 17
current_keystate_bitmap:         DS 16
held_keystate_bitmap:            DS 16
key_mode_table:                  DS 32



;//////////////////////////////////////////////////////////////////////
;//
;// Internal Bitfield layout
;//

;////////////////////////////////////////
;//
;// bit_flags
;//

BSEG AT 8*(bit_flags - 20h)

change_mode_of_backspace:        DBIT 1
xt_mode_flag:                    DBIT 1
tx_byte_pending:                 DBIT 1
release_enabled:                 DBIT 1
scancode_queue_overflowed:       DBIT 1
is_scancode_set_1:               DBIT 1
is_scancode_set_3:               DBIT 1
l_shift_key_held:                DBIT 1

r_shift_key_held:                DBIT 1
ctrl_key_held:                   DBIT 1
alt_key_held:                    DBIT 1
num_lock_flag:                   DBIT 1
typematic_enabled:               DBIT 1
typematic_ongoing:               DBIT 1
typematic_armed_flag:            DBIT 1
typematic_ready_flag:            DBIT 1

proccessing_keys_up_flag:        DBIT 1
beep_enable_flag:                DBIT 1
sound_beeper:                    DBIT 1
rx_tx_parity_bit:                DBIT 1
tx_and_rx_done:                  DBIT 1
rx_and_tx_flag:                  DBIT 1
tx_single_byte_flag:             DBIT 1
in_init_flag:                    DBIT 1



;//////////////////////////////////////////////////////////////////////
;//
;// Program entry
;//

CSEG AT 0000h

    LJMP        init

    DB          00h, 00h, 00h, 00h, 00h, 00h, 00h, 00h



;//////////////////////////////////////////////////////////////////////
;//
;// Interrupt Timers
;//

;////////////////////////////////////////
;//
;// Secondary timer
;//
;//   Handles key scanning.
;//   Triggers about 2.20KHz
;//

timer0_int:
    MOV         TL0,#60h                    ; Reset timer
    MOV         TH0,#0FEh
    JNB         DISABLE_SCANNING_FLAG,timer_routine
    RETI

    DB          00h, 00h, 00h, 00h, 00h, 00h

;////////////////////////////////////////
;//
;// Primary timer
;//
;//   Mainly used for beeping the speaker.
;//   Triggers about 4.47KHz, Prioritized
;//

timer1_int:
    INC         t1_ticks_since_last_tx
    JNB         sound_beeper,skip_flipping_speaker
    DJNZ        beep_duration,flip_speaker
    MOV         beep_duration,#18h
    CLR         SPEAKER
    CLR         sound_beeper
skip_flipping_speaker:
    RETI

flip_speaker:
    CPL         SPEAKER
    RETI



;//////////////////////////////////////////////////////////////////////
;//
;// Key Scanning routines
;//
;//   Scans the keyboard matrix, one row per timer-interrupt. The full
;//   round therefore takes 17 interrupts, since there is one extra
;//   interrupt where pointers are reset and the trigger for typematic
;//   repeat is being handled. That is, around 130 complete scan-cycles
;//   are done every second. Since there's one cycle delay to sort out
;//   debounce, the typical latency will be in the range of 8-15ms.
;//
;//   R0   Pointer to bitmap of row's current immediate key state
;//   R1   Pointer to bitmap of row's current key-held state
;//   R2   Row counter
;//   R3   Total number of keys held in all rows
;//   R4   Bitmap of row's previous immediate key state
;//   R4   Temporary key-held bitmap (in check_for_typematic_arming)
;//

timer_routine:
    PUSH        ACC                         ; Save CPU state, swap registers
    PUSH        PSW
    PUSH        DPL
    PUSH        DPH
    SETB        RS0
    INC         R2                          ; Advance to next row
    CJNE        R2,#10h,read_next_row
    LJMP        reset_row_counter           ; Reset scan if all rows done

read_next_row:
    MOV         A,ROW_SELECT                ; Select current row
    ANL         A,#0F0h
    ADD         A,R2
    MOV         ROW_SELECT,A
    NOP                                     ; Small delay
    NOP
    NOP
    NOP
    NOP
    MOV         A,ROW_DATA                  ; Read row data
    CJNE        R2,#0Ch,check_for_keysup
    ANL         A,#0FCh

;////////////////////////////////////////

check_for_keysup:
    XCh         A,@R0                       ; Save new immediate key-state
    MOV         R4,A                        ; Keep previous immediate key-state
    ORL         A,@R0                       ; Get keys not held in either
    CPL         A
    ANL         A,@R1                       ; See if any prev. held key is up
    JNZ         new_keys_up
    LJMP        check_for_keysdown

new_keys_up:
    SETB        proccessing_keys_up_flag    ; Determine which key is up in row
    JB          ACC.0,new_key_col_0_up
    JB          ACC.1,new_key_col_1_up
    JB          ACC.2,new_key_col_2_up
    JB          ACC.3,new_key_col_3_up
    JB          ACC.4,new_key_col_4_up
    JB          ACC.5,new_key_col_5_up
    JB          ACC.6,new_key_col_6_up

    MOV         A,@R1                       ; Column 7 up, update held keys
    ANL         A,#7Fh
    MOV         @R1,A
    MOV         A,#70h
    SJMP        handle_key_up

new_key_col_6_up:
    MOV         A,@R1                       ; Column 6 up, update held keys
    ANL         A,#0BFh
    MOV         @R1,A
    MOV         A,#60h
    SJMP        handle_key_up

new_key_col_5_up:
    MOV         A,@R1                       ; Column 5 up, update held keys
    ANL         A,#0DFh
    MOV         @R1,A
    MOV         A,#50h
    SJMP        handle_key_up

new_key_col_4_up:
    MOV         A,@R1                       ; Column 4 up, update held keys
    ANL         A,#0EFh
    MOV         @R1,A
    MOV         A,#40h
    SJMP        handle_key_up

new_key_col_3_up:
    MOV         A,@R1                       ; Column 3 up, update held keys
    ANL         A,#0F7h
    MOV         @R1,A
    MOV         A,#30h
    SJMP        handle_key_up

new_key_col_2_up:
    MOV         A,@R1                       ; Column 2 up, update held keys
    ANL         A,#0FBh
    MOV         @R1,A
    MOV         A,#20h
    SJMP        handle_key_up

new_key_col_1_up:
    MOV         A,@R1                       ; Column 1 up, update held keys
    ANL         A,#0FDh
    MOV         @R1,A
    MOV         A,#10h
    SJMP        handle_key_up

new_key_col_0_up:
    MOV         A,@R1                       ; Column 0 up, update held keys
    ANL         A,#0FEh
    MOV         @R1,A
    CLR         A

;////////////////////////////////////////

handle_key_up:
    ADD         A,R2                        ; Combine col and row for key index
    MOV         keyup_key_index,A           ; Save it for scancode event
    MOV         DPTR,#keytype_flags_table   ; Get flags for key
    MOVC        A,@A+DPTR
    MOV         keytype_flags,A             ; Save it for event and proccessing

    MOV         size_of_unsent_msg,#00h     ; Do scancode event
    LCALL       encode_and_tx_scancode
    DEC         R3                          ; Scancode sent, one less held key

    MOV         A,keytype_flags             ; Handle any changes to shift state
    ANL         A,#38h                      ; Key shift-type in bit 3-5
    RL          A
    SWAP        A
    JZ          normal_key_keyup            ; Determine shift-type of key
    DEC         A
    JZ          l_shift_key_keyup
    DEC         A
    JZ          r_shift_key_keyup
    DEC         A
    JZ          alt_key_keyup
    DEC         A
    JZ          ctrl_key_keyup
    SJMP        normal_key_keyup

l_shift_key_keyup:
    CLR         l_shift_key_held            ; Left shift let go
    JNB         scancode_queue_overflowed,skip_holdoff_shifts
    SETB        L_SHIFT_UP_PENDING          ; Set flag for overflow recovery
    SJMP        normal_key_keyup

r_shift_key_keyup:
    CLR         r_shift_key_held            ; Right shift let go
    JNB         scancode_queue_overflowed,skip_holdoff_shifts
    SETB        R_SHIFT_UP_PENDING          ; Set flag for overflow recovery
    SJMP        normal_key_keyup

alt_key_keyup:
    CLR         alt_key_held                ; Alt let go
    SJMP        normal_key_keyup

ctrl_key_keyup:
    CLR         ctrl_key_held               ; Ctrl let go

normal_key_keyup:
    CLR         scancode_queue_overflowed
skip_holdoff_shifts:
    CLR         typematic_ongoing           ; Any key-up stops tymeatic repeat

;////////////////////////////////////////

check_for_keysdown:
    CLR         proccessing_keys_up_flag
    MOV         A,R4                        ; Get previous immediate key state
    ANL         A,@R0                       ; Get keys which are still held
    CPL         A                           ; Prune keys already proccessed
    ORL         A,@R1
    CPL         A
    JNZ         new_keys_down
    LJMP        check_for_typematic_arming

new_keys_down:
    JB          ACC.0,new_key_col_0_down    ; Determine which key is held
    JB          ACC.1,new_key_col_1_down
    JB          ACC.2,new_key_col_2_down
    JB          ACC.3,new_key_col_3_down
    JB          ACC.4,new_key_col_4_down
    JB          ACC.5,new_key_col_5_down
    JB          ACC.6,new_key_col_6_down

    MOV         A,@R1                       ; Column 7 down, update held keys
    ORL         A,#80h
    MOV         @R1,A
    MOV         A,#70h
    SJMP        handle_key_down

new_key_col_6_down:
    MOV         A,@R1                       ; Column 6 down, update held keys
    ORL         A,#40h
    MOV         @R1,A
    MOV         A,#60h
    SJMP        handle_key_down

new_key_col_5_down:
    MOV         A,@R1                       ; Column 5 down, update held keys
    ORL         A,#20h
    MOV         @R1,A
    MOV         A,#50h
    SJMP        handle_key_down

new_key_col_4_down:
    MOV         A,@R1                       ; Column 4 down, update held keys
    ORL         A,#10h
    MOV         @R1,A
    MOV         A,#40h
    SJMP        handle_key_down

new_key_col_3_down:
    MOV         A,@R1                       ; Column 3 down, update held keys
    ORL         A,#08h
    MOV         @R1,A
    MOV         A,#30h
    SJMP        handle_key_down

new_key_col_2_down:
    MOV         A,@R1                       ; Column 2 down, update held keys
    ORL         A,#04h
    MOV         @R1,A
    MOV         A,#20h
    SJMP        handle_key_down

new_key_col_1_down:
    MOV         A,@R1                       ; Column 1 down, update held keys
    ORL         A,#02h
    MOV         @R1,A
    MOV         A,#10h
    SJMP        handle_key_down

new_key_col_0_down:
    MOV         A,@R1                       ; Column 0 down, update held keys
    ORL         A,#01h
    MOV         @R1,A
    CLR         A

;////////////////////////////////////////

handle_key_down:
    ADD         A,R2                        ; Combine col and row for key index
    MOV         keydown_key_index,A         ; Save it for scancode event
    JNB         xt_mode_flag,skip_update_scroll_lock
    CJNE        A,#3Eh,skip_update_scroll_lock
    CPL         SCROLL_LOCK_INDICATOR       ; Key 3E is hardcoded to ScrollLock
skip_update_scroll_lock:
    MOV         DPTR,#keytype_flags_table   ; Get flags for key
    MOVC        A,@A+DPTR
    MOV         keytype_flags,A             ; Save it for event and proccessing

    MOV         size_of_unsent_msg,#00h     ; Do scancode event
    LCALL       encode_and_tx_scancode
    CLR         scancode_queue_overflowed
    INC         R3                          ; Scancode sent, one more held key

    MOV         typematic_count,typematic_delay
    CLR         typematic_ongoing           ; Reset typematic repeat system
    MOV         A,keytype_flags             ; Set default for scancode set 1/2
    ANL         A,#07h                      ; Get key-type
    JB          is_scancode_set_3,keydown_process_modifier
    CJNE        A,#05h,arm_default_typematic
    CLR         typematic_enabled           ; No typematic rep. for Pause/Break
    SJMP        keydown_process_modifier
arm_default_typematic:
    SETB        typematic_enabled           ; Otherwise, yes typematic repeat

keydown_process_modifier:
    MOV         A,keytype_flags             ; Handle any changes to shift state
    ANL         A,#38h                      ; Key shift-type in bit 3-5
    RL          A
    SWAP        A
    JZ          normal_key_keydown          ; Determine shift-type of key
    DEC         A
    JZ          l_shift_key_keydown
    DEC         A
    JZ          r_shift_key_keydown
    DEC         A
    JZ          alt_key_keydown
    DEC         A
    JZ          ctrl_key_keydown
    DEC         A
    JZ          num_lock_key_keydown
    DEC         A
    JZ          caps_lock_key_keydown
    SJMP        normal_key_keydown

num_lock_key_keydown:
    JNB         xt_mode_flag,normal_key_keydown
    CPL         num_lock_flag
    CPL         NUM_LOCK_INDICATOR
    SJMP        normal_key_keydown

l_shift_key_keydown:
    SETB        l_shift_key_held
    SJMP        normal_key_keydown

r_shift_key_keydown:
    SETB        r_shift_key_held
    SJMP        normal_key_keydown

alt_key_keydown:
    SETB        alt_key_held
    SJMP        normal_key_keydown

ctrl_key_keydown:
    SETB        ctrl_key_held
    SJMP        normal_key_keydown

caps_lock_key_keydown:
    JNB         xt_mode_flag,normal_key_keydown
    CPL         CAPS_LOCK_INDICATOR

normal_key_keydown:
    MOV         A,keydown_key_index
    CJNE        A,#0Dh,keydown_arm_beep     ; Key 0D is hardcoded to Arrow Down
    JNB         alt_key_held,keydown_arm_beep
    JNB         ctrl_key_held,keydown_arm_beep
    CPL         beep_enable_flag            ; Toggle beep if Ctrl+Alt+Down
keydown_arm_beep:
    JNB         beep_enable_flag,done_keydown
    SETB        sound_beeper                ; Trigger beep if enabled
done_keydown:
    SJMP        key_row_end

;////////////////////////////////////////

check_for_typematic_arming:
    JNB         typematic_ready_flag,key_row_end
    JB          typematic_armed_flag,key_row_end
    MOV         A,@R1                       ; Scan if most recent key is held
    JZ          key_row_end

search_for_next_typematic_key:
    JB          ACC.0,key_col_0_held        ; Check any held key in row
    JB          ACC.1,key_col_1_held
    JB          ACC.2,key_col_2_held
    JB          ACC.3,key_col_3_held
    JB          ACC.4,key_col_4_held
    JB          ACC.5,key_col_5_held
    JB          ACC.6,key_col_6_held

    ANL         A,#7Fh                       ; Column 7 held, select
    MOV         R4,A
    MOV         A,#70h
    SJMP        held_key_found

key_col_6_held:
    ANL         A,#0BFh                      ; Column 6 down, select
    MOV         R4,A
    MOV         A,#60h
    SJMP        held_key_found

key_col_5_held:
    ANL         A,#0DFh                      ; Column 5 down, select
    MOV         R4,A
    MOV         A,#50h
    SJMP        held_key_found

key_col_4_held:
    ANL         A,#0EFh                      ; Column 4 down, select
    MOV         R4,A
    MOV         A,#40h
    SJMP        held_key_found

key_col_3_held:
    ANL         A,#0F7h                      ; Column 3 down, select
    MOV         R4,A
    MOV         A,#30h
    SJMP        held_key_found

key_col_2_held:
    ANL         A,#0FBh                      ; Column 2 down, select
    MOV         R4,A
    MOV         A,#20h
    SJMP        held_key_found

key_col_1_held:
    ANL         A,#0FDh                      ; Column 1 down, select
    MOV         R4,A
    MOV         A,#10h
    SJMP        held_key_found

key_col_0_held:
    ANL         A,#0FEh                      ; Column 0 down, select
    MOV         R4,A
    CLR         A

;////////////////////////////////////////

held_key_found:
    ADD         A,R2                        ; Combine col and row for key index
    MOV         latest_held_key_index,A
    CJNE        A,keydown_key_index,not_latest_held_key
    SETB        typematic_armed_flag        ; Arm typematic if the key is found
    SJMP        key_row_end
not_latest_held_key:
    MOV         A,R4                        ; Otherwise keep scanning held keys
    JNZ         search_for_next_typematic_key

;////////////////////////////////////////

key_row_end:
    INC         R0                          ; Point to next row
    INC         R1

timer_int_end:
    POP         DPH                         ; Restore CPU state
    POP         DPL
    POP         PSW
    POP         ACC
    RETI

;////////////////////////////////////////

reset_row_counter:
    MOV         R2,#-1                      ; Reset row counter
    MOV         R0,#current_keystate_bitmap ; Reset keystate bitmap pointers
    MOV         R1,#held_keystate_bitmap

    JB          typematic_ongoing,check_for_typematic_trigger
    JBC         typematic_ready_flag,typematic_arm_check
    MOV         A,R3                        ; Get number of held keys
    JZ          typematic_skip_ready        ; Don't ready typematic if no keys
    DJNZ        typematic_count,typematic_skip_ready
    SETB        typematic_ready_flag        ; Typematic delay almost over: Ready
    CLR         typematic_armed_flag        ; Arming is done on next scan-cycle
typematic_skip_ready:
    SJMP        read_keylocks

;////////////////////////////////////////

typematic_arm_check:
    SETB        typematic_ongoing           ; Start typematic anyways
    JNB         typematic_armed_flag,read_keylocks
    MOV         typematic_count,#05h        ; If armed, add rest of delay first
    LJMP        read_keylocks

;////////////////////////////////////////

typematic_disarm:
    CLR         typematic_armed_flag        ; Trigger will skip if not armed
    SJMP        read_keylocks

;////////////////////////////////////////

check_for_typematic_trigger:
    DJNZ        typematic_count,read_keylocks
    JNB         typematic_armed_flag,read_keylocks
    JNB         typematic_enabled,typematic_disarm
    JNB         SERIAL_CLOCK_RX,typematic_triggered
    MOV         typematic_count,#01h
    LJMP        typematic_end

typematic_triggered:
    MOV         DPTR,#keytype_flags_table   ; Get typematic key flags
    MOV         A,latest_held_key_index
    MOVC        A,@A+DPTR
    MOV         keytype_flags,A             ; Save for evt. scancode event

    JNB         is_scancode_set_3,typematic_scancode_set_12
    CPL         A                           ; Check if Notis-key in set 3
    ANL         A,#07h
    JNZ         typematic_normal_key        ; If not, send scancode
    MOV         A,#80h                      ; Else, send Notis-key prefix
    MOV         size_of_unsent_msg,#00h
    SJMP        typematic_send_scode_prefix

typematic_scancode_set_12:
    MOV         size_of_unsent_msg,#00h     ; Scancode set 1/2 typematic...
    MOV         A,keytype_flags             ; Get flags back to check shift
    ANL         A,#07h
    JZ          typematic_normal_key        ; Send normal keys clean
    JNB         alt_key_held,typematic_set_12_extended_no_alt
    CJNE        A,#04h,typematic_set_12_extended_no_alt
    MOV         A,#84h                      ; Typematic on Alt+PrtScr in set 2
    JNB         is_scancode_set_1,typematic_send_scancode
    MOV         A,#54h                      ; Typematic on Alt+PrtScr in set 1
    SJMP        typematic_send_scancode

typematic_set_12_extended_no_alt:
    MOV         A,keytype_flags             ; Get flags back to check Notis
    CPL         A
    ANL         A,#07h
    JZ          typematic_notis_key         ; Send Notis prefix if so
    MOV         A,#0E0h
    SJMP        typematic_send_scode_prefix ; Else send extended prefix

typematic_notis_key:
    MOV         A,#80h
typematic_send_scode_prefix:
    LCALL       queue_scancode              ; Send any prefix
typematic_normal_key:
    MOV         DPL,scancode_table_ptr_lo
    MOV         DPH,scancode_table_ptr_hi
    MOV         A,latest_held_key_index     ; Get normal scancode
    MOVC        A,@A+DPTR
typematic_send_scancode:
    LCALL       queue_scancode              ; Send main scancode
    MOV         typematic_count,typematic_repeat_rate

typematic_end:
    CLR         scancode_queue_overflowed
    JNB         beep_enable_flag,typematic_only_beep_on_normal_key
    SETB        sound_beeper                ; Sound beeper if enabled...
typematic_only_beep_on_normal_key:
    MOV         A,keytype_flags
    ANL         A,#38h
    JZ          read_keylocks
    CLR         sound_beeper                ; ...but ONLY on normal keys!

;////////////////////////////////////////

read_keylocks:
    MOV         A,ROW_SELECT                ; Read keylocks on row 0Ch
    ANL         A,#0F0h                     ; Select row
    ADD         A,#0Ch
    MOV         ROW_SELECT,A
    NOP                                     ; Wait a little
    NOP
    NOP
    NOP
    NOP
    MOV         A,ROW_DATA                  ; Data in lower 2 columns
    ANL         A,#03h
    CJNE        A,keylocks_prev_state,keylocks_end
    MOV         keylocks_state,keylocks_prev_state
    AJMP        timer_int_end

keylocks_end:
    MOV         keylocks_prev_state,A   ; Save immediate state for debounce
    AJMP        timer_int_end



;//////////////////////////////////////////////////////////////////////
;//
;// Main Loop
;//
;//   Handles communication to and from the keyboard, as well as
;//   reacting to any incoming commands from the computer.
;//

main_loop:
    JB          L_SHIFT_UP_PENDING,main_enrty_pending_shift_up
    JB          R_SHIFT_UP_PENDING,main_enrty_pending_shift_up
main_loop_no_pending_shift_up:
    LCALL       push_tx                     ; Send any pending scancodes
main_loop_wait_for_rx:
    LCALL       poll_rx                     ; Poll for incoming commands
    JNB         tx_and_rx_done,main_loop

main_loop_repeat_prev_cmd:
    CLR         tx_and_rx_done
    MOV         A,rx_byte                   ; Check command
    CJNE        A,#-20,check_command_in_range
check_command_in_range:
    JC          command_not_in_range
    MOV         DPTR,#keyboard_commands     ; Execute valid command [EC -> FF]
    SUBB        A,#-20
    RL          A
    JMP         @A+DPTR

command_not_in_range:
    LJMP        invalid_operation           ; Else handle invalid command

;////////////////////////////////////////
;//
;// Recover shift release events after overflow
;//

main_enrty_pending_shift_up:
    JB          is_scancode_set_1,encode_pending_shift_up_set_1
    MOV         A,#0F0h                     ; Queue break-code for set 2
    LCALL       queue_scancode
    MOV         A,#12h                      ; Left Shift scancode for set 2
    JB          L_SHIFT_UP_PENDING,send_pending_shift_up
    MOV         A,#59h                      ; Right Shift scancode for set 2
    SJMP        send_pending_shift_up
encode_pending_shift_up_set_1:
    MOV         A,#0AAh                     ; Left Shift break-code for set 1
    JB          L_SHIFT_UP_PENDING,send_pending_shift_up
    MOV         A,#0B6h                     ; Right Shift break-code for set 1
send_pending_shift_up:
    LCALL       queue_scancode              ; Queue scancode

    JBC         scancode_queue_overflowed,main_loop_no_pending_shift_up
    JBC         L_SHIFT_UP_PENDING,main_loop_no_pending_shift_up
    CLR         R_SHIFT_UP_PENDING
    SJMP        main_loop_no_pending_shift_up

;////////////////////////////////////////

keyboard_commands:
    AJMP        op_get_keylocks             ; Jump-table to all valid commands
    AJMP        op_set_indicators
    AJMP        op_echo
    AJMP        invalid_operation
    AJMP        op_set_scancode_set
    AJMP        invalid_operation
    AJMP        op_identify_kbd
    AJMP        op_set_typematic
    AJMP        op_en_scanning
    AJMP        op_restore_defaults
    AJMP        op_restore_defaults
    AJMP        op_typematic_all
    AJMP        op_make_release_all
    AJMP        op_make_only_all
    AJMP        op_typematic_make_release_all
    AJMP        op_typematic_key
    AJMP        op_typematic_make_release_key
    AJMP        op_make_only_key
    AJMP        op_resend
    AJMP        op_reset_and_selftest



;////////////////////////////////////////
;//
;// Command: Get keylock state
;//
;//   Input:
;//     [EC]
;//
;//   Output:
;//     [FA]
;//     Keylock state
;//       -> [F6]: Both keylocks open
;//       -> [F7]: Keylock col 1 closed
;//       -> [F8]: Keylock col 0 closed
;//       -> [F9]: Both keylocks closed
;//

op_get_keylocks:
    CLR         ET0                         ; Data will be sent, so no scanning

    SETB        rx_and_tx_flag              ; Send Ack
    MOV         prioritized_tx_byte,#0FAh
    SETB        tx_single_byte_flag
    LCALL       push_tx

    MOV         A,keylocks_state            ; Get lock state
    PUSH        DPL                         ; Translate it to return byte
    PUSH        DPH
    MOV         DPTR,#keylocks_status_enum
    MOVC        A,@A+DPTR
    POP         DPH
    POP         DPL
    MOV         prioritized_tx_byte,A       ; Send byte
    SETB        tx_single_byte_flag
    CLR         rx_and_tx_flag
    LCALL       push_tx

    AJMP        main_loop                   ; Command done

keylocks_status_enum:
    DB          0F6h, 0F8h, 0F7h, 0F9h



;////////////////////////////////////////
;//
;// Command: Set keyboard indicators
;//
;//   Input:
;//     [ED]
;//     Indicator state
;//       -> [00]: All off
;//       -> [01]: Scroll-Lock on
;//       -> [02]: Num-Lock on
;//       -> [03]: Scroll-Lock + Num-Lock on
;//       -> [04]: Caps-Lock on
;//       -> [05]: Caps-Lock + Scroll-Lock on
;//       -> [06]: Caps-Lock + Num-Lock on
;//       -> [07]: All on
;//
;//   Output:
;//     [FA]
;//     [FA]
;//

op_set_indicators:
    CLR         ET0                         ; Data will be sent, so no scanning

    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    SETB        rx_and_tx_flag              ; But also expect data
set_indicators_tx_loop:
    LCALL       push_tx
set_indicators_rx_loop:
    LCALL       poll_rx
    JB          tx_byte_pending,set_indicators_tx_loop
    JNB         tx_and_rx_done,set_indicators_rx_loop
    CLR         tx_and_rx_done

    MOV         A,rx_byte                   ; Get received data
    CJNE        A,#08h,check_indicator_range
check_indicator_range:
    JNC         invalid_indicator_data      ; Check data
    CPL         A                           ; Set indicators from valid data
    MOV         C,ACC.0
    MOV         SCROLL_LOCK_INDICATOR,C
    MOV         C,ACC.2
    MOV         CAPS_LOCK_INDICATOR,C
    MOV         C,ACC.1
    MOV         NUM_LOCK_INDICATOR,C
    CPL         C
    MOV         num_lock_flag,C

    MOV         prioritized_tx_byte,#0FAh   ; Ack valid data
    SETB        tx_single_byte_flag
    CLR         rx_and_tx_flag
    LCALL       push_tx

    AJMP        main_loop                   ; Command done

invalid_indicator_data:
    CLR         rx_and_tx_flag              ; Invalid data, wait for more
    SETB        ET0                         ; Enable scanning before retry
    AJMP        main_loop_repeat_prev_cmd



;////////////////////////////////////////
;//
;// Command: Echo
;//
;//   Input:
;//     [EE]
;//
;//   Output:
;//     [EE]
;//

op_echo:
    MOV         prioritized_tx_byte,#0EEh   ; Send Echo response
    SETB        tx_single_byte_flag

    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Invalid command
;//
;//   Output:
;//     [FE]
;//

invalid_operation:
    MOV         previously_sent_byte,prioritized_tx_byte
    MOV         prioritized_tx_byte,#0FEh   ; Send Nack
    SETB        tx_single_byte_flag

    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Command: Set Scancode Set
;//
;//   Input:
;//     [F0]
;//     Scancode set
;//       -> [00]: Get selected scancode set
;//       -> [01]: Selected scancode set 1
;//       -> [02]: Selected scancode set 2
;//       -> [03]: Selected scancode set 3
;//
;//   Output:
;//     [FA]
;//     [FA]
;//     Scancode set selected (if "Get selected" Input)
;//       -> [01]: Scancode set 1
;//       -> [02]: Scancode set 2
;//       -> [03]: Scancode set 3
;//

op_set_scancode_set:
    CLR         ET0                         ; Data will be sent, so no scanning

    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    SETB        rx_and_tx_flag              ; But also expect data
scancode_set_tx_loop:
    LCALL       push_tx
scancode_set_rx_loop:
    LCALL       poll_rx
    JB          tx_byte_pending,scancode_set_tx_loop
    JNB         tx_and_rx_done,scancode_set_rx_loop
    CLR         tx_and_rx_done

    MOV         A,rx_byte                   ; Get received data
    CJNE        A,#04h,check_scancode_set_range
check_scancode_set_range:
    JNC         invalid_scancode_set        ; Check data
    JZ          get_scancode_set
    LCALL       flush_tx_buffer
    DEC         A
    JZ          select_scancode_set_1
    DEC         A
    JZ          select_scancode_set_2
    LCALL       set_scancode_set_3          ; Set scancode set 3
    SJMP        select_scancode_set_done
select_scancode_set_2:
    LCALL       set_scancode_set_2          ; Set scancode set 2
    SJMP        select_scancode_set_done
select_scancode_set_1:
    MOV         prioritized_tx_byte,#0FAh   ; Ack valid data
    SETB        tx_single_byte_flag
    CLR         rx_and_tx_flag
    LCALL       push_tx
    LCALL       set_scancode_set_1          ; Set scancode set 1
    AJMP        main_loop                   ; Command done

select_scancode_set_done:
    MOV         prioritized_tx_byte,#0FAh   ; Ack valid data
    SETB        tx_single_byte_flag
    CLR         rx_and_tx_flag
    LCALL       push_tx
    AJMP        main_loop                   ; Command done

invalid_scancode_set:
    CLR         rx_and_tx_flag              ; Abort
    SETB        ET0
    AJMP        main_loop_repeat_prev_cmd   ; Command failed

get_scancode_set:
    MOV         prioritized_tx_byte,#0FAh   ; Ack valid data
    SETB        tx_single_byte_flag
    LCALL       push_tx
    JB          is_scancode_set_1,scancode_set_1_selected
    JB          is_scancode_set_3,scancode_set_3_selected
    MOV         prioritized_tx_byte,#02h
    SJMP        get_scancode_set_done
scancode_set_1_selected:
    MOV         prioritized_tx_byte,#01h
    SJMP        get_scancode_set_done
scancode_set_3_selected:
    MOV         prioritized_tx_byte,#03h
get_scancode_set_done:
    SETB        tx_single_byte_flag         ; Respond with selected set
    CLR         rx_and_tx_flag
    LCALL       push_tx
    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Command: Identify Keyboard
;//
;//   Input:
;//     [F2]
;//
;//   Output:
;//     [FA]
;//     [AB 83]
;//

op_identify_kbd:
    CLR         ET0                         ; Data will be sent, so no scanning

    SETB        rx_and_tx_flag              ; Might as well expect next command
    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    LCALL       push_tx
    MOV         prioritized_tx_byte,#0ABh   ; Send MF2-keyboard identification
    SETB        tx_single_byte_flag
    LCALL       push_tx
    MOV         prioritized_tx_byte,#83h
    SETB        tx_single_byte_flag
    CLR         rx_and_tx_flag
    LCALL       push_tx

    CLR         DISABLE_SCANNING_FLAG       ; Enable scanning if disabled
    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Command: Set Typematic Settings
;//
;//   Input:
;//     [F3]
;//     Typematic settings:
;//       -> 76543210
;//          ||||||||
;//          |||+++++- Repeat rate
;//          |++------ Delay before repeat
;//          +-------- 0
;//
;//   Output:
;//     [FA]
;//     [FA]
;//

op_set_typematic:
    CLR         ET0                         ; Data will be sent, so no scanning

    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    SETB        rx_and_tx_flag              ; But also expect data
set_typematics_tx_loop:
    LCALL       push_tx
set_typematics_rx_loop:
    LCALL       poll_rx
    JB          tx_byte_pending,set_typematics_tx_loop
    JNB         tx_and_rx_done,set_typematics_rx_loop
    CLR         tx_and_rx_done

    MOV         A,rx_byte                   ; Get received data
    JNB         ACC.7,valid_typematic_byte  ; Check data
    CLR         rx_and_tx_flag              ; Abort
    SETB        ET0
    AJMP        main_loop_repeat_prev_cmd   ; Command failed

valid_typematic_byte:
    ANL         A,#60h                      ; Separate out Delay
    RR          A
    SWAP        A
    PUSH        DPH                         ; Get delay timer value from table
    PUSH        DPL
    MOV         DPTR,#delay_before_repeat_timings
    MOVC        A,@A+DPTR
    POP         DPL
    POP         DPH
    MOV         typematic_delay,A           ; Set new delay timer value
    MOV         A,rx_byte                   ; Recover received data
    ANL         A,#1Fh                      ; Separate out Repetition
    PUSH        DPH                         ; Get rep. timer value from table
    PUSH        DPL
    MOV         DPTR,#repeat_rate_timings
    MOVC        A,@A+DPTR
    MOV         typematic_repeat_rate,A     ; Set new repetition timer value
    POP         DPL
    POP         DPH

    CLR         rx_and_tx_flag
    MOV         prioritized_tx_byte,#0FAh   ; Ack valid data
    SETB        tx_single_byte_flag
    LCALL       push_tx

    AJMP        main_loop                   ; Command done

delay_before_repeat_timings:
    DB          1Ah, 3Ah, 59h, 7Ah          ; 200ms, 447ms, 686ms, 941ms  +54ms

repeat_rate_timings:
    DB          04h, 05h, 05h, 06h          ; 32.4Hz, 25.9Hz, 25.9Hz, 21.6Hz
    DB          06h, 06h, 07h, 08h          ; 21.6Hz, 21.6Hz, 18.5Hz, 16.2Hz
    DB          08h, 09h, 0Bh, 0Ch          ; 16.2Hz, 14.4Hz, 11.8Hz, 10.8Hz
    DB          0Dh, 0Eh, 10h, 10h          ; 9.97Hz, 9.26Hz, 8.10Hz, 8.10Hz
    DB          11h, 13h, 15h, 17h          ; 7.62Hz, 6.82Hz, 6.17Hz, 5.64Hz
    DB          19h, 1Bh, 1Dh, 1Fh          ; 5.18Hz, 4.80Hz, 4.47Hz, 4.18Hz
    DB          22h, 26h, 2Ah, 2Eh          ; 3.81Hz, 3.41Hz, 3.09Hz, 2.82Hz
    DB          32h, 37h, 3Ch, 40h          ; 2.59Hz, 2.36Hz, 2.16Hz, 2.03Hz



;////////////////////////////////////////
;//
;// Command: Enable Scanning
;//
;//   Input:
;//     [F4]
;//
;//   Output:
;//     [FA]
;//

op_en_scanning:
    CLR         ET0                         ; Data will be sent, so no scanning

    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    LCALL       push_tx
    LCALL       flush_tx_buffer

    CLR         typematic_enabled           ; Reset typematic repeat

    SETB        ET0                         ; Resume scanning
    CLR         DISABLE_SCANNING_FLAG       ; Enable scanning if disabled
    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Command: Restore Default Settings
;//
;//   Input:
;//     Post-reset State
;//       -> [F5]: Scanning disabled
;//       -> [F6]: Scanning enabled
;//
;//   Output:
;//     [FA]
;//

op_restore_defaults:
    CLR         ET0                         ; Data will be sent, so no scanning
    PUSH        ACC                         ; Save command byte

    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    LCALL       push_tx

    MOV         typematic_delay,#3Ah        ; Reset settings
    MOV         typematic_repeat_rate,#0Ch
    LCALL       flush_tx_buffer
    LCALL       restore_default_key_modes
    CLR         typematic_enabled

    POP         ACC                         ; Recover command byte
    JNB         ACC.1,restore_defaults_done ; ...but disable if odd cmd byte
    SETB        DISABLE_SCANNING_FLAG
restore_defaults_done:
    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Command: Set typematic for all
;//          keys in scancode set 3
;//
;//   Input:
;//     Setting
;//       -> [F7]: Make + Typematic
;//       -> [F8]: Make + Release
;//       -> [F9]: Make only
;//       -> [FA]: Make + Release + Typematic
;//
;//   Output:
;//     [FA]
;//

op_typematic_all:
    MOV         A,#55h
    SJMP        set_key_mode_all

op_make_release_all:
    MOV         A,#0AAh
    SJMP        set_key_mode_all

op_make_only_all:
    MOV         A,#00h
    SJMP        set_key_mode_all

op_typematic_make_release_all:
    MOV         A,#0FFh

;////////////////////////////////////////

set_key_mode_all:
    CLR         ET0                         ; Data will be sent, so no scanning

    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    PUSH        ACC
    LCALL       push_tx
    POP         ACC

    PUSH        PSW                         ; Fill bitpair-table with setting
    PUSH        scancode_tx_buffer_head_ptr
    CLR         RS0
    MOV         R0,#key_mode_table
fill_key_mode_table_loop:
    MOV         @R0,A
    INC         R0
    CJNE        R0,#key_mode_table + 20h,fill_key_mode_table_loop
    POP         scancode_tx_buffer_head_ptr
    POP         PSW

    JNB         is_scancode_set_3,fill_key_mode_table_done
    LCALL       flush_tx_buffer             ; Flush TX if new setting active
fill_key_mode_table_done:

    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Command: Set typematic for single
;//          key in scancode set 3
;//
;//   This assumes two possible key indexes
;//   for backspace, and in the case of the
;//   backspace scancode both of these keys
;//   in the matrix will be affected by the
;//   requested mode change.
;//
;//   Input:
;//     Setting
;//       -> [FB]: Make + Typematic
;//       -> [FC]: Make + Release
;//       -> [FD]: Make only
;//     Key
;//       -> [00-85]: Scancode of key, from set 3
;//
;//   Output:
;//     [FA]
;//

op_typematic_key:
    CLR         ET0                         ; Data will be sent, so no scanning
    CLR         release_enabled
    SETB        typematic_enabled
    SJMP        set_key_mode_key

op_typematic_make_release_key:
    CLR         ET0                         ; Data will be sent, so no scanning
    SETB        release_enabled
    CLR         typematic_enabled
    SJMP        set_key_mode_key

op_make_only_key:
    CLR         ET0                         ; Data will be sent, so no scanning
    CLR         release_enabled
    CLR         typematic_enabled
    SJMP        set_key_mode_key

;////////////////////////////////////////

set_key_mode_key:
    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    SETB        rx_and_tx_flag              ; But also expect data
set_key_mode_tx_loop:
    LCALL       push_tx
set_key_mode_rx_loop:
    LCALL       poll_rx
    JB          tx_byte_pending,set_key_mode_tx_loop
    JNB         tx_and_rx_done,set_key_mode_rx_loop
    CLR         tx_and_rx_done

set_key_mode_next:
    MOV         A,rx_byte                   ; Get received data
    CJNE        A,#85h,check_valid_set_3_scancode
check_valid_set_3_scancode:
    JNC         set_mode_operation_done     ; check if valid set-3 scancode
    MOV         DPTR,#scancode_set_3_decode ; If so, get key index of scancode
    MOVC        A,@A+DPTR
    CJNE        A,#66h,check_if_key_supports_mode
    SETB        change_mode_of_backspace    ; Key 66 is hardcoded to Backspace
check_if_key_supports_mode:
    CJNE        A,#0FFh,set_key_mode        ; Set key mode if applicable index
    SJMP        set_mode_operation_done     ; Else, end command

set_key_mode:
    MOV         B,#04h                      ; Get byte index of bitpair table
    DIV         AB
    ADD         A,#key_mode_table
    MOV         rx_byte,A                   ; ...save it somewhere
    MOV         A,B                         ; Get bitpair index of byte
    PUSH        PSW
    PUSH        scancode_tx_buffer_head_ptr
    CLR         RS0
    MOV         R0,rx_byte                  ; Recover byte index
    JZ          set_mode_byte_entry_1       ; Bitpairs are organized big-endian
    DEC         A
    JZ          set_mode_byte_entry_2
    DEC         A
    JZ          set_mode_byte_entry_3

    MOV         A,@R0                       ; Fourth bitpair
    MOV         C,release_enabled
    MOV         ACC.1,C
    MOV         C,typematic_enabled
    MOV         ACC.0,C
    SJMP        set_mode_byte_entry_done

set_mode_byte_entry_3:
    MOV         A,@R0                       ; Third bitpair
    MOV         C,release_enabled
    MOV         ACC.3,C
    MOV         C,typematic_enabled
    MOV         ACC.2,C
    SJMP        set_mode_byte_entry_done

set_mode_byte_entry_2:
    MOV         A,@R0                       ; Second bitpair
    MOV         C,release_enabled
    MOV         ACC.5,C
    MOV         C,typematic_enabled
    MOV         ACC.4,C
    SJMP        set_mode_byte_entry_done

set_mode_byte_entry_1:
    MOV         A,@R0                       ; First bitpair
    MOV         C,release_enabled
    MOV         ACC.7,C
    MOV         C,typematic_enabled
    MOV         ACC.6,C

set_mode_byte_entry_done:
    MOV         @R0,A                       ; Write to bitpair table
    MOV         A,#48h                      ; Key 48 is hardcoded to Backspace
    JBC         change_mode_of_backspace,set_key_mode
    POP         scancode_tx_buffer_head_ptr
    POP         PSW

set_mode_operation_done:
    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
set_key_mode_tx_loop_2:
    ACALL       push_tx
set_key_mode_rx_loop_2:
    LCALL       poll_rx
    JB          tx_byte_pending,set_key_mode_tx_loop_2
    JNB         tx_and_rx_done,set_key_mode_rx_loop_2
    CLR         tx_and_rx_done

    CJNE        A,#0F4h,set_key_mode_next   ; Expect data until Enable Scanning
    CLR         rx_and_tx_flag
    AJMP        op_en_scanning              ; Command done



;////////////////////////////////////////
;//
;// Command: Resend last byte
;//
;//   Input:
;//     [FE]
;//
;//   Output:
;//     Last RX'ed byte if sending resend,
;//     else Last TX'ed byte
;//

op_resend:
    MOV         A,prioritized_tx_byte       ; Send previous Tx unless we...
    CJNE        A,#0FEh,do_resend           ; ...raised nack, then send last Rx
    MOV         prioritized_tx_byte,previously_sent_byte
do_resend:
    SETB        tx_single_byte_flag
    AJMP        main_loop                   ; Command done



;////////////////////////////////////////
;//
;// Command: Hard reset and self-test
;//
;//   Input:
;//     [FF]
;//
;//   Output:
;//     [FA]
;//     Selftest-result
;//       -> [AA]: All fine
;//

op_reset_and_selftest:
    CLR         ET0                         ; Data will be sent, so no scanning

    MOV         prioritized_tx_byte,#0FAh   ; Send Ack
    SETB        tx_single_byte_flag
    ACALL       push_tx

invoke_reset_wait_for_clk_low_1:            ; Wait for zero-bit handshake
    JB          SERIAL_CLOCK_RX,invoke_reset_wait_for_clk_low_1
    MOV         R4,#0FFh
invoke_reset_wait_a_bit:
    DJNZ        R4,invoke_reset_wait_a_bit
invoke_reset_wait_for_clk_low_2:
    JB          SERIAL_CLOCK_RX,invoke_reset_wait_for_clk_low_2

    LCALL       read_clock_and_data_lines
    CJNE        A,#08h,invoke_reset_do_selftest
    AJMP        main_loop_wait_for_rx       ; Skip if zero-bit not received

invoke_reset_do_selftest:
    LJMP        Init                        ; Reboot firmware



;//////////////////////////////////////////////////////////////////////
;//
;// Transmit a byte to host
;//
;//   If an immediate response is pending, this will get priority,
;//   otherwise the byte to send will be taken from the scancode-buffer.
;//   In case the buffer is empty in this situation, nothing will happen.
;//
;//   This is supposed to be called from the main loop.
;//
;//   R1   Pointer to tail of Tx Scancode FiFo-Buffer
;//   R2   Tx Scancode FiFo-Buffer current size
;//   R4   Temporary counter
;//

push_tx:
    JB          xt_mode_flag,push_tx_xt     ; Determine AT or XT mode
    SJMP        tx_byte_at

push_tx_xt:
    CLR         ET0                         ; Prepare for CLK-line check if XT
    LJMP        tx_byte_xt                  ; ...this needs accurate timing.

;////////////////////////////////////////

tx_cleanup:
    JBC         tx_single_byte_flag,tx_done ; Pop transmitted byte off FiFo
    DEC         R2
    INC         R1
    CJNE        R1,#scancode_tx_queue+17,tx_done
    MOV         R1,#scancode_tx_queue       ; Take care of buffer wrap-around

tx_done:
    JB          rx_and_tx_flag,tx_hold_line
    JB          in_init_flag,tx_hold_line
    SETB        ET0                         ; Resume scanning if all done
tx_hold_line:
    JB          xt_mode_flag,tx_complete    ; Only default lines to high if AT
    CLR         SERIAL_CLOCK_TX
    CLR         SERIAL_DATA_TX
tx_complete:
    CLR         tx_byte_pending             ; Byte has been sent
    RET

;////////////////////////////////////////

tx_byte_at:
    JB          tx_single_byte_flag,tx_at_single_byte   ; Tx immediate-byte?
    MOV         A,R2                        ; Anything from buffer to transmit?
    JZ          tx_done
    MOV         prioritized_tx_byte,@R1     ; If so, get next byte from buffer

init_tx_at:
    MOV         A,t1_ticks_since_last_tx    ; Check cooldown time between bytes
    CJNE        A,#05h,tx_at_check_time
tx_at_check_time:
    JC          tx_byte_at
    MOV         R4,#10h                     ; Wait a bit more after cooldown
tx_at_init_wait:
    DJNZ        R4,tx_at_init_wait
    SJMP        tx_at_wait_for_clock        ; Wait for serial line ready

tx_at_sync_up:
    CLR         SERIAL_DATA_TX              ; Release data-line, just in case
    SJMP        tx_at_wait_for_clock        ; Wait for serial line ready

tx_at_single_byte:
    MOV         A,prioritized_tx_byte       ; No cooldown for response 83h
    CJNE        A,#83h,init_tx_at           ; Wait for serial line ready

tx_at_wait_for_clock:
    LCALL       read_clock_and_data_lines   ; Wait for Clock/Data lines to...
tx_at_wait_for_clock_loop:                  ; ...remain stable for some time
    MOV         B,A
    MOV         R4,#10h
tx_at_wait_for_clock_delay:
    DJNZ        R4,tx_at_wait_for_clock_delay
    LCALL       read_clock_and_data_lines
    CJNE        A,B,tx_at_wait_for_clock_loop
    JZ          do_tx_at                    ; Start transmit if both lines high
    CJNE        A,#08h,tx_at_setup_fault_retry  ; Retry unles only data low
    SJMP        tx_done
tx_at_setup_fault_retry:
    MOV         t1_ticks_since_last_tx,#01h ; Reset cooldown timer for retry
    SJMP        tx_byte_at

do_tx_at:
    CLR         ET0                         ; Time-critical, so no scanning now
    MOV         B,prioritized_tx_byte       ; Fetch byte to transmit
    MOV         A,prioritized_tx_byte
    MOV         C,P                         ; Get parity bit of byte to Tx
    CPL         C
    MOV         rx_tx_parity_bit,C

    JB          SERIAL_CLOCK_RX,tx_at_sync_up   ; Verify clock still high
    SETB        SERIAL_DATA_TX              ; Set low start bit...
    MOV         R4,#09h                     ; ...and clock through
tx_at_start_bit_hi:
    DJNZ        R4,tx_at_start_bit_hi
    SETB        SERIAL_CLOCK_TX
    MOV         R4,#12h
tx_at_start_bit_lo:
    DJNZ        R4,tx_at_start_bit_lo
    CLR         SERIAL_CLOCK_TX

    MOV         R4,#04h                     ; Wait a little before bit 0
tx_at_bit_0_hi:
    DJNZ        R4,tx_at_bit_0_hi

    MOV         temporary_counter,#08h      ; Send 8 data-bits
    JB          SERIAL_CLOCK_RX,tx_at_sync_up
tx_at_next_bit:
    LCALL       set_next_tx_bit
    PUSH        temporary_counter
    MOV         R4,#07h
tx_at_next_hi:
    DJNZ        R4,tx_at_next_hi
    SETB        SERIAL_CLOCK_TX
    MOV         R4,#12h
tx_at_bit_n_lo:
    DJNZ        R4,tx_at_bit_n_lo
    CLR         SERIAL_CLOCK_TX
    MOV         R4,#04h                     ; Wait a little before next bit
tx_at_bit_n_hi:
    DJNZ        R4,tx_at_bit_n_hi
    POP         temporary_counter
    JB          SERIAL_CLOCK_RX,tx_at_sync_up
    DJNZ        temporary_counter,tx_at_next_bit

    MOV         R4,#03h                     ; Wait a little before parity bit
tx_at_last_data_hi:
    DJNZ        R4,tx_at_last_data_hi

    MOV         C,rx_tx_parity_bit          ; Send parity bit
    CPL         C
    MOV         SERIAL_DATA_TX,C
    MOV         R4,#08h
tx_at_parity_bit_hi:
    DJNZ        R4,tx_at_parity_bit_hi
    SETB        SERIAL_CLOCK_TX
    MOV         R4,#12h
tx_at_parity_bit_lo:
    DJNZ        R4,tx_at_parity_bit_lo
    CLR         SERIAL_CLOCK_TX

    MOV         R4,#0Ah                     ; Wait a little before stop bit
tx_at_last_bit_hi:
    DJNZ        R4,tx_at_last_bit_hi
    JNB         SERIAL_CLOCK_RX,tx_at_success
    AJMP        tx_at_sync_up

tx_at_success:
    CLR         SERIAL_DATA_TX              ; Send stop bit
    MOV         R4,#0Ch
tx_at_stop_bit_hi:
    DJNZ        R4,tx_at_stop_bit_hi
    SETB        SERIAL_CLOCK_TX
    MOV         t1_ticks_since_last_tx,#00h
    MOV         R4,#11h
tx_at_stop_bit_lo:
    DJNZ        R4,tx_at_stop_bit_lo
    CLR         SERIAL_CLOCK_TX

    AJMP        tx_cleanup                  ; Tx done

;////////////////////////////////////////

tx_byte_xt:
    JNB         SERIAL_CLOCK_RX,tx_ready_xt ; Reset firmware if clock-line held
    LCALL       wait_ca_10ms
    JB          SERIAL_CLOCK_RX,xt_dataline_reset

tx_ready_xt:
    JB          tx_single_byte_flag,init_tx_xt  ; Check if immediate-byte Tx
    MOV         A,R2                        ; Anything from buffer to transmit?
    JZ          tx_xt_abort
    MOV         prioritized_tx_byte,@R1     ; If so, get next byte from buffer

init_tx_xt:
    JB          in_init_flag,do_tx_xt       ; On reset, don't wait to send ack
    MOV         R4,#0E6h                    ; Otherwise ensure a small pause
wait_pre_tx_post_reset:
    DJNZ        R4,wait_pre_tx_post_reset

do_tx_xt:
    MOV         B,prioritized_tx_byte       ; Fetch byte to transmit
    SETB        SERIAL_CLOCK_TX             ; Prepare clock line by pulling it
    MOV         R4,#2Eh
tx_xt_start_bit_lo:
    DJNZ        R4,tx_xt_start_bit_lo
    CLR         SERIAL_DATA_TX              ; Set start bit...
    CLR         SERIAL_CLOCK_TX             ; ...and clock through
    MOV         R4,#19h
tx_xt_start_bit_hi:
    DJNZ        R4,tx_xt_start_bit_hi
    SETB        SERIAL_CLOCK_TX
    MOV         R4,#01h
tx_xt_bit_0_lo:
    DJNZ        R4,tx_xt_bit_0_lo

    MOV         temporary_counter,#08h      ; Send 8 data bits
tx_xt_next_bit:
    LCALL       set_next_tx_bit
    PUSH        temporary_counter
    MOV         R4,#05h
tx_xt_bit_next_lo:
    DJNZ        R4,tx_xt_bit_next_lo
    CLR         SERIAL_CLOCK_TX
    MOV         R4,#15h
tx_xt_bit_n_hi:
    DJNZ        R4,tx_xt_bit_n_hi
    SETB        SERIAL_CLOCK_TX
    MOV         R4,#01h
tx_xt_bit_n_lo:
    DJNZ        R4,tx_xt_bit_n_lo
    POP         temporary_counter
    DJNZ        temporary_counter,tx_xt_next_bit

    MOV         R4,#02h                     ; Wait a little before stop-bit
tx_xt_last_bit_lo:
    DJNZ        R4,tx_xt_last_bit_lo

    SETB        SERIAL_DATA_TX              ; Send stop-bit
    MOV         R4,#06h
tx_xt_data_hi:
    DJNZ        R4,tx_xt_data_hi
    CLR         SERIAL_CLOCK_TX

    AJMP        tx_cleanup                  ; Tx done

;////////////////////////////////////////

tx_xt_abort:
    AJMP        tx_done                     ; Nothing transmitted, return

;////////////////////////////////////////

xt_dataline_reset:
    LJMP        init                        ; Reset requested, reboot firmware



;//////////////////////////////////////////////////////////////////////
;//
;// Poll host for a byte to receive
;//
;//   If a byte is expected from the host, this routine will poll the host
;//   for data.
;//
;//   This is supposed to be called from the main loop, and if immediate
;//   tx is to take place at the same time then the call to push_tx should
;//   be done right before the call to poll_rx. This is due to that only
;//   poll_rx updates the combined pending-rx and -tx flag.
;//
;//   R4   Temporary counter
;//

poll_rx:
    CLR         ET0                         ; Timing-critical action
    JNB         xt_mode_flag,rx_byte_at     ; Determine AT or XT mode
    JNB         SERIAL_CLOCK_RX,rx_end      ; No Rx for XT mode, just check...
    LCALL       wait_ca_10ms                ; ...if clock held low
    JNB         SERIAL_CLOCK_RX,rx_end
    LJMP        init                        ; Reset requested, reboot keyboard

;////////////////////////////////////////

rx_done:
    JB          tx_byte_pending,rx_end
    SETB        tx_and_rx_done
rx_end:
    JB          rx_and_tx_flag,rx_return
    SETB        ET0
rx_return:
    RET

;////////////////////////////////////////

rx_byte_at:
    LCALL       read_clock_and_data_lines   ; Check Rx Clock and Data lines
    CJNE        A,#08h,rx_end               ; Expect Clock high and Data low
    MOV         R4,#04h                     ; Wait tiny bit
rx_byte_check_lines_wait:
    DJNZ        R4,rx_byte_check_lines_wait
    LCALL       read_clock_and_data_lines   ; Verify consistency
    CJNE        A,#08h,rx_end

    MOV         temporary_counter,#09h      ; Set Rx + Parity bit-counter
rx_next_bit:
    SETB        SERIAL_CLOCK_TX             ; Clock in next bit...
    PUSH        temporary_counter
    MOV         R4,#13h
rx_bit_lo:
    DJNZ        R4,rx_bit_lo
    CLR         SERIAL_CLOCK_TX
    MOV         R4,#10h
rx_bit_hi:
    DJNZ        R4,rx_bit_hi
    MOV         C,SERIAL_DATA_RX            ; ...and shift into Rx byte
    CPL         C
    MOV         A,rx_byte
    RRC         A
    MOV         rx_byte,A
    MOV         rx_tx_parity_bit,C          ; Temporary storage of 9th bit
    POP         temporary_counter
    DJNZ        temporary_counter,rx_next_bit

rx_wait_for_stop_bit:
    LCALL       toggle_clock_line           ; Get and assert stop-bit
    JB          SERIAL_DATA_RX,rx_sync_fault

    SETB        SERIAL_DATA_TX              ; Send low bit to ack stop-bit
    MOV         R4,#08h
rx_stop_bit:
    DJNZ        R4,rx_stop_bit
    LCALL       toggle_clock_line
    CLR         SERIAL_DATA_TX              ; Restore data-line to high

    MOV         A,rx_byte                   ; Separate parity-bit from Rx-bits
    MOV         C,rx_tx_parity_bit
    RLC         A
    MOV         rx_byte,A
    MOV         rx_tx_parity_bit,C

    MOV         A,rx_byte                   ; Verify parity of Rx
    MOV         C,P
    CPL         C
    ANL         C,rx_tx_parity_bit
    JC          rx_done
    MOV         C,P
    ANL         C,/rx_tx_parity_bit
    JC          rx_done

    SETB        tx_single_byte_flag         ; Parity fault, queue Nack
    MOV         previously_sent_byte,prioritized_tx_byte
    MOV         prioritized_tx_byte,#0FEh
    SETB        tx_byte_pending
    SJMP        rx_end

rx_sync_fault:
    SETB        tx_single_byte_flag         ; Stop-bit not received, queue Nack
    MOV         previously_sent_byte,prioritized_tx_byte
    MOV         prioritized_tx_byte,#0FEh
    SETB        tx_byte_pending
    MOV         R4,#08h                     ; Keep clocking until stop-bit
rx_fault_wait:
    DJNZ        R4,rx_fault_wait
    SJMP        rx_wait_for_stop_bit



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Set next Tx bit
;//
;//   Shifts the LSB from register B onto the Data-line
;//
;//   B = Data working-byte
;//

set_next_tx_bit:
    MOV         A,B
    RRC         A
    MOV         B,A
    CPL         C
    MOV         SERIAL_DATA_TX,C
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Toggle Clock-line
;//
;//   Clocks the Clock-line to low then high once.
;//
;//   R4   Temporary counter
;//

toggle_clock_line:
    SETB        SERIAL_CLOCK_TX
    MOV         R4,#14h
toggle_clock_line_wait_1:
    DJNZ        R4,toggle_clock_line_wait_1
    CLR         SERIAL_CLOCK_TX
    MOV         R4,#08h
toggle_clock_line_wait_2:
    DJNZ        R4,toggle_clock_line_wait_2
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Read Clock and Data lines
;//
;//   Gets the Clock and Data lines in bit 2 and 3 (respectively) of A
;//
read_clock_and_data_lines:
    MOV         A,DATA_AND_CLOCK
    ANL         A,#0Ch
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Encode and queue scancode for Tx
;//
;//    Converts a key-index into the appropriate scan-code, or sequence
;//    of scancodes. Handles all conversions when it comes to extended
;//    keyboard-layout handling for scancode-set 1 and 2.
;//
;//    The pending key-index variable is expected to have been set by
;//    the scanning-routine, and this function is supposed to be called
;//    from there in response to a key-state change.
;//
;//    A    Keytype flags
;//

encode_and_tx_scancode:
    JNB         is_scancode_set_3,encode_and_tx_scancode_set_1_2
    CPL         A                           ; Scan-code set 3: Check key-class
    ANL         A,#07h                      ; 7: Extended notis key
    JZ          notis_key_encode            ;    ...handled separately
    CJNE        A,#01h,encode_key_active    ; 6: Inactive key, don't handle
    RET

;////////////////////////////////////////
;//
;// Ordinary scan-code set 3
;//

encode_key_active:
    JNB         proccessing_keys_up_flag,encode_keydown_set_3
    MOV         A,keyup_key_index           ; Retreive key for flags
    LCALL       get_key_mode                ; Flags affect key-up action
    JNB         release_enabled,skip_key_release_if_disabled
    MOV         A,#0F0h                     ; Queue break-code prefix
    LCALL       queue_scancode
    SJMP        send_base_scancode_code_set_3

encode_keydown_set_3:
    MOV         A,keydown_key_index         ; Retreive key for scancode
    LCALL       get_key_mode
send_base_scancode_code_set_3:
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
skip_key_release_if_disabled:
    RET

;////////////////////////////////////////
;//
;// NOTIS-keys, common handler for all sets
;//

notis_key_encode:
    JNB         proccessing_keys_up_flag,encode_notis_keydown
    JNB         is_scancode_set_3,encode_notis_keyup_set_1_2
    MOV         A,keyup_key_index           ; Retreive key for flags
    LCALL       get_key_mode                ; Flags affect key-up action
    JNB         release_enabled,notis_skip_key_release_if_disabled
    MOV         A,keydown_key_index         ; Retreive key for flags again
    LCALL       get_key_mode
encode_notis_keyup_set_1_2:
    MOV         A,#80h                      ; Queue notis-key prefix
    LCALL       queue_scancode
    JB          is_scancode_set_1,encode_notis_base_scancode_set_1
    MOV         A,#0F0h                     ; Queue break-code prefix
    LCALL       queue_scancode
encode_notis_base_scancode_set_1:
    LCALL       get_stored_scancode         ; Queue key scancode
    JNB         is_scancode_set_1,send_keyup_code_set_2_3
    ORL         A,#80h                      ; Set break-flag for scancode set 1
send_keyup_code_set_2_3:
    LCALL       queue_scancode
notis_skip_key_release_if_disabled:
    RET

encode_notis_keydown:
    JNB         is_scancode_set_3,notis_keydown_check_numcase
    MOV         A,keydown_key_index         ; Retreive key for flags again
    LCALL       get_key_mode
    SJMP        send_notis_keydown
notis_keydown_check_numcase:
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,notis_add_numcase_postfix
    SJMP        send_notis_keydown          ; If a navigation-key is held...
notis_add_numcase_postfix:
    LCALL       tx_numcase_modifier_up      ; ...Then queue re-enable numlock
send_notis_keydown:
    MOV         A,#80h                      ; Queue notis-key prefix
    LCALL       queue_scancode
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
    RET

;////////////////////////////////////////
;//
;// Scan-code set 1 or 2 common handler
;//

encode_and_tx_scancode_set_1_2:
    MOV         A,keytype_flags             ; Handle key based on key class
    ANL         A,#07h
    JZ          normal_key_encode           ; 0: Normal key
    DEC         A
    JZ          extended_key_encode         ; 1: Extended key
    DEC         A
    JZ          navigation_key_encode       ; 2: Extended force no shift/numpad
    DEC         A
    JZ          numpad_div_key_encode       ; 3: Extended force no shift
    DEC         A
    JZ          prtscr_key_encode           ; 4: Special handling
    DEC         A
    JZ          pause_break_key_encode      ; 5: Only make-key sequences
    SJMP        notis_key_encode            ; 7: Extended notis key

numpad_div_key_encode:
    LJMP        numpad_div_key_entry

prtscr_key_encode:
    LJMP        prtscr_key_entry

pause_break_key_encode:
    LJMP        pause_break_key_entry

;////////////////////////////////////////
;//
;// Normal key
;// No extra prefix
;//

normal_key_encode:
    JNB         proccessing_keys_up_flag,normal_keydown_check_numcase
    JB          is_scancode_set_1,normal_keyup_encode
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
    SJMP        normal_scancode_encode

normal_keydown_check_numcase:
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,normal_add_numcase_postfix
    SJMP        normal_scancode_encode      ; If a navigation-key is held...
normal_add_numcase_postfix:
    LCALL       tx_numcase_modifier_up      ; ...Then queue re-enable numlock
normal_scancode_encode:
    LCALL       get_stored_scancode         ; Queue key scancode
    SJMP        send_normal_scancode

normal_keyup_encode:
    LCALL       get_stored_scancode         ; Queue key scancode
    ORL         A,#80h                      ; Set break-flag for scancode set 1
send_normal_scancode:
    LCALL       queue_scancode
    RET

;////////////////////////////////////////
;//
;// Extended key
;// Always 0E0h prefix
;//

extended_key_encode:
    MOV         A,#0E0h                     ; Queue Extended key prefix
    LCALL       queue_scancode
    JNB         proccessing_keys_up_flag,extended_key_keydown_check_numcase
    JB          is_scancode_set_1,normal_keyup_encode
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
    SJMP        send_extended_key_scancode

extended_key_keydown_check_numcase:
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,extended_add_numcase_postfix
    SJMP        send_extended_key_scancode  ; If a navigation-key is held...
extended_add_numcase_postfix:
    LCALL       tx_numcase_modifier_up      ; ...Then queue re-enable numlock
    LCALL       queue_scancode              ; Queue Extended key prefix again
send_extended_key_scancode:
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
    RET

    LCALL       get_stored_scancode         ; Queue key scancode
    ORL         A,#80h                      ; Set break-flag for scancode set 1
    LCALL       queue_scancode
    RET

;////////////////////////////////////////
;//
;// Navigation key
;// These are non-shifted numpad keys in set 1 and 2
;//

navigation_key_encode:
    JB          num_lock_flag,encode_navigation_numlock
encode_navigation_no_numlock:
    JB          proccessing_keys_up_flag,encode_navigation_keyup
    JB          l_shift_key_held,encode_navigation_keydown_l_shift
    JB          r_shift_key_held,encode_navigation_keydown_r_shift
    SJMP        encode_navigation_no_shift

encode_navigation_numlock:
    LJMP        send_navigation_numlock

encode_navigation_keyup:
    JB          l_shift_key_held,send_navigation_keyup_shift
    JB          r_shift_key_held,send_navigation_keyup_shift

encode_navigation_no_shift:                 ; No locks/modifiers, just send key
    MOV         A,#0E0h                     ; Queue Extended key prefix
    LCALL       queue_scancode
    JNB         proccessing_keys_up_flag,send_navigation_base_no_shift
    JB          is_scancode_set_1,send_navigation_keyup_no_shift_set_1
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
send_navigation_base_no_shift:
    LCALL       get_stored_scancode         ; Queue key scancode
    SJMP        send_navigation_no_shift
send_navigation_keyup_no_shift_set_1:
    LCALL       get_stored_scancode
    ORL         A,#80h                      ; Set break-flag for scancode set 1
send_navigation_no_shift:
    LCALL       queue_scancode
    RET

encode_navigation_keydown_l_shift:
    JB          r_shift_key_held,encode_navigation_keydown_both_shift
    MOV         DPTR,#nav_keydown_l_shift_set_2
    JNB         is_scancode_set_1,send_navigation_keydown_shift
    MOV         DPTR,#nav_keydown_l_shift_set_1
    SJMP        send_navigation_keydown_shift

encode_navigation_keydown_r_shift:
    MOV         DPTR,#nav_keydown_r_shift_set_2
    JNB         is_scancode_set_1,send_navigation_keydown_shift
    MOV         DPTR,#nav_keydown_r_shift_set_1
    SJMP        send_navigation_keydown_shift

encode_navigation_keydown_both_shift:
    MOV         DPTR,#nav_keydown_both_shift_set_2
    JNB         is_scancode_set_1,send_navigation_keydown_shift
    MOV         DPTR,#nav_keydown_both_shift_set_1

send_navigation_keydown_shift:
    LCALL       queue_string                ; Queue disable Shift sequence
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
    RET

nav_keydown_l_shift_set_1:
    DB          0E0h, 0AAh, 0E0h, 00h
nav_keydown_l_shift_set_2:
    DB          0E0h, 0F0h, 12h, 0E0h, 00h

nav_keydown_r_shift_set_1:
    DB          0E0h, 0B6h, 0E0h, 00h
nav_keydown_r_shift_set_2:
    DB          0E0h, 0F0h, 59h, 0E0h, 00h

nav_keydown_both_shift_set_1:
    DB          0E0h, 0AAh, 0E0h, 0B6h, 0E0h, 00h
nav_keydown_both_shift_set_2:
    DB          0E0h, 0F0h, 12h, 0E0h, 0F0h, 59h, 0E0h, 00h

send_navigation_keyup_shift:
    MOV         A,#0E0h                     ; Queue Extended key prefix
    LCALL       queue_scancode
    JB          is_scancode_set_1,encode_numpad_keyup_shift_set_1
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    JNB         r_shift_key_held,send_nav_keyup_l_shift_set_2
    MOV         A,#59h                      ; Queue re-enable Right Shift
    LCALL       queue_scancode
    JNB         l_shift_key_held,send_nav_keyup_done_set_2
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
send_nav_keyup_l_shift_set_2:
    MOV         A,#12h                      ; Queue re-enable Left Shift
    LCALL       queue_scancode
send_nav_keyup_done_set_2:
    RET

encode_numpad_keyup_shift_set_1:
    LCALL       get_stored_scancode         ; Queue key scancode
    ORL         A,#80h                      ; Set break-flag for scancode set 1
    LCALL       queue_scancode
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    JNB         r_shift_key_held,send_nav_keyup_l_shift_set_1
    MOV         A,#36h                      ; Queue re-enable Right Shift
    LCALL       queue_scancode
    JNB         l_shift_key_held,send_nav_keyup_done_set_1
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
send_nav_keyup_l_shift_set_1:
    MOV         A,#2Ah                      ; Queue re-enable Left Shift
    LCALL       queue_scancode
send_nav_keyup_done_set_1:
    RET

send_navigation_numlock:
    JB          l_shift_key_held,encode_navigation_numlock_shift
    JB          r_shift_key_held,encode_navigation_numlock_shift
    JB          proccessing_keys_up_flag,encode_nav_numlock_keyup
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,send_navigation_keydown
    MOV         DPTR,#nav_prefix_set_1
    JB          is_scancode_set_1,send_navigation_prefix
    MOV         DPTR,#nav_prefix_set_2
send_navigation_prefix:
    LCALL       queue_string                ; Queue disable numlock sequence
send_navigation_keydown:
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
    SETB        NAVIGATION_NUMCASE_IGNORE_FLAG
    RET

nav_prefix_set_1:
    DB          0E0h, 2Ah, 00h
nav_prefix_set_2:
    DB          0E0h, 12h, 00h

encode_nav_numlock_keyup:
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    JB          is_scancode_set_1,encode_nav_numlock_keyup_scancode
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
encode_nav_numlock_keyup_scancode:
    LCALL       get_stored_scancode         ; Queue key scancode
    JNB         is_scancode_set_1,send_nav_numlock_keyup_scancode
    ORL         A,#80h                      ; Set break-flag for scancode set 1
send_nav_numlock_keyup_scancode:
    LCALL       queue_scancode
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,encode_navigation_postfix
    RET

encode_navigation_postfix:
    MOV         DPTR,#nav_postfix_set_2
    JNB         is_scancode_set_1,send_navigation_postfix
    MOV         DPTR,#nav_postfix_set_1
send_navigation_postfix:
    LCALL       queue_string                ; Queue re-enable numlock sequence
    RET

nav_postfix_set_1:
    DB          0E0h, 0AAh, 00h
nav_postfix_set_2:
    DB          0E0h, 0F0h, 12h, 00h

encode_navigation_numlock_shift:
    AJMP        encode_navigation_no_shift  ; numlock + shift, just send key

;////////////////////////////////////////
;//
;// Numpad division key
;// This key is a non-shifted non-numpad key in set 1 and 2
;//

numpad_div_key_entry:
    JB          l_shift_key_held,encode_numpad_div_shift
    JB          r_shift_key_held,encode_numpad_div_shift
    JB          proccessing_keys_up_flag,encode_numpad_div_keyup
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,send_numpad_div_numcase
    SJMP        send_numpad_div_keydown     ; If a navigation-key is held...
send_numpad_div_numcase:
    LCALL       tx_numcase_modifier_up      ; ...Then queue re-enable numlock
send_numpad_div_keydown:
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
    RET

encode_numpad_div_keyup:
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    JB          is_scancode_set_1,encode_numpad_div_keyup_scancode
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
encode_numpad_div_keyup_scancode:
    LCALL       get_stored_scancode         ; Queue key scancode
    JNB         is_scancode_set_1,send_numpad_div_keyup_scancode
    ORL         A,#80h                      ; Set break-flag for scancode set 1
send_numpad_div_keyup_scancode:
    LCALL       queue_scancode
    RET

encode_numpad_div_shift:
    AJMP        encode_navigation_no_numlock    ; Ignore shift if shift active

;////////////////////////////////////////
;//
;// Print-screen key
;// This is an extended key except of Alt + PrtScr
;//

prtscr_key_entry:
    JB          alt_key_held,encode_prtscr_alt_modifier
    JB          ctrl_key_held,encode_prtscr_other_modifier
    JB          l_shift_key_held,encode_prtscr_other_modifier
    JB          r_shift_key_held,encode_prtscr_other_modifier

    JB          proccessing_keys_up_flag,encode_prtscr_keyup
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,send_prtscr_keydown
    MOV         DPTR,#prtscr_prefix_set_2
    JNB         is_scancode_set_1,send_prtscr_prefix
    MOV         DPTR,#prtscr_prefix_set_1
send_prtscr_prefix:
    LCALL       queue_string                ; Queue disable numlock
send_prtscr_keydown:
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    LCALL       get_stored_scancode         ; Queue key scancode
    LCALL       queue_scancode
    SETB        NAVIGATION_NUMCASE_IGNORE_FLAG
    RET

prtscr_prefix_set_1:
    DB          0E0h, 2Ah, 00h
prtscr_prefix_set_2:
    DB          0E0h, 12h, 00h

encode_prtscr_keyup:
    MOV         DPTR,#prtscr_keyup_set_2
    JNB         is_scancode_set_1,send_prtscr_keyup
    MOV         DPTR,#prtscr_keyup_set_1
send_prtscr_keyup:
    LCALL       queue_string                ; Queue scancode
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,encode_prtscr_postfix
    RET

encode_prtscr_postfix:
    MOV         DPTR,#prtscr_postfix_set_2
    JNB         is_scancode_set_1,send_prtscr_postfix
    MOV         DPTR,#prtscr_postfix_set_1
send_prtscr_postfix:
    LCALL       queue_string                ; Queue re-enable numlock
    RET

prtscr_keyup_set_1:
    DB          0E0h, 0B7h, 00h
prtscr_keyup_set_2:
    DB          0E0h, 0F0h, 7Ch, 00h

prtscr_postfix_set_1:
    DB          0E0h, 0AAh, 00h
prtscr_postfix_set_2:
    DB          0E0h, 0F0h, 12h, 00h

encode_prtscr_alt_modifier:
    JB          is_scancode_set_1,send_prtscr_alt_set_1
    JNB         proccessing_keys_up_flag,send_prtscr_alt_scancode_set_2
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
send_prtscr_alt_scancode_set_2:
    MOV         A,#84h                      ; Queue alt + print screen scancode
    LCALL       queue_scancode
    RET

send_prtscr_alt_set_1:
    MOV         A,#54h                      ; Queue Alt + PtrScr make-code
    JNB         proccessing_keys_up_flag,send_prtscr_alt_scancode_set_1
    MOV         A,#0D4h                      ; Queue Alt + PrtScr break-code
send_prtscr_alt_scancode_set_1:
    LCALL       queue_scancode
    RET

encode_prtscr_other_modifier:
    MOV         A,#0E0h                     ; Queue Extended prefix
    LCALL       queue_scancode
    JNB         proccessing_keys_up_flag,encode_prtscr_other_modifier_keydown
    JB          is_scancode_set_1,encode_prtscr_other_keyup
    MOV         A,#0F0h                     ; Queue break-code prefix for set 2
    LCALL       queue_scancode
encode_prtscr_other_keyup:
    LCALL       get_stored_scancode         ; Queue scancode
    JNB         is_scancode_set_1,send_prtscr_other_keyup
    ORL         A,#80h                      ; Set break-flag for scancode set 1
send_prtscr_other_keyup:
    LCALL       queue_scancode
    RET

encode_prtscr_other_modifier_keydown:
    LCALL       get_stored_scancode         ; Queue scancode
    LCALL       queue_scancode
    RET

;////////////////////////////////////////
;//
;// Pause/Break key
;// Only send make-sequence
;//

pause_break_key_entry:
    JNB         proccessing_keys_up_flag,encode_break_keydown
    RET

encode_break_keydown:
    JB          ctrl_key_held,encode_break_ctrl_keydown
    JBC         NAVIGATION_NUMCASE_IGNORE_FLAG,encode_break_keydown_check_numcase
    SJMP        send_break_keydown          ; If a navigation-key is held...
encode_break_keydown_check_numcase:
    ACALL       tx_numcase_modifier_up      ; ...Then queue re-enable numlock
send_break_keydown:
    MOV         DPTR,#break_set_2
    JNB         is_scancode_set_1,send_break
    MOV         DPTR,#break_set_1
send_break:
    ACALL       queue_string                ; Send Break key sequence
    RET

break_set_2:
    DB          0E1h, 14h, 77h, 0E1h, 0F0h, 14h, 0F0h, 77h, 00h
break_set_1:
    DB          0E1h, 1Dh, 45h, 0E1h, 9Dh, 0C5h, 00h

encode_break_ctrl_keydown:
    MOV         DPTR,#ctrl_break_set_2
    JNB         is_scancode_set_1,send_ctrl_break
    MOV         DPTR,#ctrl_break_set_1
send_ctrl_break:
    ACALL       queue_string                ; Send Ctrl+Break sequence
    RET

ctrl_break_set_2:
    DB          0E0h, 7Eh, 0E0h, 0F0h, 7Eh, 00h
ctrl_break_set_1:
    DB          0E0h, 46h, 0E0h, 0C6h, 00h



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Get scancode
;//
;//   Uses the current stored key index and the selected scancode-set
;//   to fetch the appropriate scan-code.
;//

get_stored_scancode:
    MOV         A,keydown_key_index         ; Get key index
    JNB         proccessing_keys_up_flag,get_scancode
    MOV         A,keyup_key_index
get_scancode:
    MOV         DPH,scancode_table_ptr_hi
    MOV         DPL,scancode_table_ptr_lo
    MOVC        A,@A+DPTR                   ; Get scancode from key index
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Queue re-enable numlock state
;//

tx_numcase_modifier_up:
    MOV         DPTR,#numcase_postfix_set_1
    JB          is_scancode_set_1,send_numcase_set_1
    MOV         DPTR,#numcase_postfix_set_2
send_numcase_set_1:
    ACALL       queue_string                ; Queue re-enable numlock
    RET

numcase_postfix_set_2:
    DB          0E0h, 0F0h, 12h, 00h
numcase_postfix_set_1:
    DB          0E0h, 0AAh, 00h



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Queue a sequence
;//
;//   Queues a scancode sequence to be sent to the host. The sequence
;//   must be terminated with a zero-byte.
;//

queue_string:
    CLR         A
    MOVC        A,@A+DPTR
    JZ          string_done
    LCALL       queue_scancode
    INC         DPTR
    SJMP        queue_string
string_done:
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Restore default key-flags in scancode set 3
;//

restore_default_key_modes:
    PUSH        PSW                         ; Save register selection
    PUSH        00h                         ; Save R0 of register bank 0
    CLR         RS0                         ; Use register bank 0

    MOV         DPTR,#default_key_modes     ; Source pointer to default table
    MOV         R0,#key_mode_table          ; Dest. pointer to active table
restore_key_mode_loop:
    CLR         A                           ; Copy over next byte
    MOVC        A,@A+DPTR
    MOV         @R0,A
    INC         DPTR
    INC         R0
    CJNE        R0,#key_mode_table+32,restore_key_mode_loop

    POP         00h                         ; Restore R0
    POP         PSW                         ; Restore register selection
    RET

    ;
    ; Each key has two bits in the table,
    ; starting with MSB of byte 0 for key 0
    ;
    ; 10
    ; ||
    ; |+- Typematic enabled
    ; +-- Release enabled
    ;
default_key_modes:
    DB          88h, 65h, 01h, 12h, 58h, 59h, 40h, 05h
    DB          54h, 55h, 85h, 00h, 54h, 50h, 10h, 00h
    DB          54h, 50h, 40h, 00h, 54h, 55h, 44h, 10h
    DB          54h, 55h, 44h, 00h, 54h, 55h, 44h, 00h



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Get flags of a key in scancode set 3
;//
;//   Retreived flags are stored in their appropriate variables in INTRAM.
;//
;//   A     Key index
;//

get_key_mode:
    MOV         B,#04h                      ; 4 set of flags per byte in table
    DIV         AB
    ADD         A,#key_mode_table           ; Get byte with flags for key
    PUSH        PSW
    PUSH        00h
    CLR         RS0
    MOV         R0,A
    MOV         A,@R0
    POP         00h
    POP         PSW

    PUSH        ACC                         ; Keep byte with flags for now
    MOV         A,B                         ; Remainder in B determines bitpair
    JZ          first_bitpair
    DEC         A
    JZ          second_bitpair
    DEC         A
    JZ          third_bitpair
    SJMP        fourth_bitpair

first_bitpair:
    POP         ACC                         ; Get bitpair 0
    MOV         C,ACC.7
    MOV         release_enabled,C
    MOV         C,ACC.6
    MOV         typematic_enabled,C
    RET

second_bitpair:
    POP         ACC                         ; Get bitpair 1
    MOV         C,ACC.5
    MOV         release_enabled,C
    MOV         C,ACC.4
    MOV         typematic_enabled,C
    RET

third_bitpair:
    POP         ACC                         ; Get bitpair 2
    MOV         C,ACC.3
    MOV         release_enabled,C
    MOV         C,ACC.2
    MOV         typematic_enabled,C
    RET

fourth_bitpair:
    POP         ACC                         ; Get bitpair 3
    MOV         C,ACC.1
    MOV         release_enabled,C
    MOV         C,ACC.0
    MOV         typematic_enabled,C
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Queue a scancode byte
;//
;//   If the queue, the whole partial sequence which has been queued will
;//   be removed from the queue, and an overflow status will be added in
;//   its place, if a pending overflow is not already is queued.
;//
;//   A     Scancode to send
;//   R0    Scancode queue head pointer
;//   R2    Scancode queue size
;//

queue_scancode:
    PUSH        PSW                         ; Save register selection
    CLR         RS0                         ; Use register bank 0

    JB          scancode_queue_overflowed,queue_scancode_done
    CJNE        R2,#17,queue_check          ; Abort immediately if queue full
queue_check:
    JC          add_to_queue
    SETB        scancode_queue_overflowed   ; Mark overflow, but don't send
    SJMP        queue_scancode_done
add_to_queue:
    MOV         @R0,A                       ; Add scancode to queue
    INC         R0
    INC         size_of_unsent_msg
    INC         R2

    CJNE        R2,#17,queue_not_full       ; Check for queue overflow
    SJMP        unqueue_entire_msg
queue_not_full:
    CJNE        R0,#scancode_tx_queue+17,queue_scancode_done
    MOV         R0,#scancode_tx_queue       ; Queue head-pointer wrap-around
queue_scancode_done:
    POP         PSW                         ; Restore register selection
    RET

unqueue_entire_msg:
    DEC         R0                          ; Remove entire unsent message
    CJNE        R0,#scancode_tx_queue-1,unqueue_not_wraparound_1
    MOV         R0,#scancode_tx_queue+16    ; Queue head-pointer wrap-around
unqueue_not_wraparound_1:
    DEC         R2
    DJNZ        size_of_unsent_msg,unqueue_entire_msg

    DEC         R0                          ; Get current top of queue
    CJNE        R0,#scancode_tx_queue-1,unqueue_not_wraparound_2
    MOV         R0,#scancode_tx_queue+16
unqueue_not_wraparound_2:
    MOV         A,@R0
    INC         R0
    CJNE        R0,#scancode_tx_queue+17,unqueue_not_wraparound_3
    MOV         R0,#scancode_tx_queue
unqueue_not_wraparound_3:
    JZ          tx_buffer_emptied_completelty   ; Don't queue multiple overflow
    MOV         @R0,#00h                    ; 00h Overflow scancode in set 2/3
    JNB         is_scancode_set_1,send_internal_buffer_overflow
    MOV         @R0,#0FFh                   ; 0FFh Overflow scancode in set 1
send_internal_buffer_overflow:
    INC         R0                          ; Prepare to send overflow error
    CJNE        R0,#scancode_tx_queue+17,unqueue_not_wraparound_4
    MOV         R0,#scancode_tx_queue       ; Queue head-pointer wrap-around
unqueue_not_wraparound_4:
    INC         R2
tx_buffer_emptied_completelty:
    SETB        scancode_queue_overflowed   ; Set internal overflow flag
    POP         PSW                         ; Restore register selection
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Flush Tx queue
;//
;//   Empties the whole scancode Tx queue
;//
;//   R0    Scancode queue head pointer
;//   R1    Scancode queue tail pointer
;//   R2    Scancode queue size
;//

flush_tx_buffer:
    PUSH        PSW                         ; Save register selection
    CLR         RS0                         ; Use register bank 0
    MOV         R0,#scancode_tx_queue
    MOV         R1,#scancode_tx_queue
    MOV         R2,#00h
    POP         PSW                         ; Restore register selection
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Wait about 10ms
;//
;//   Fixed-length loop-delay of around 10 milliseconds.
;//
;//   R3    Temporary outer counter
;//   R4    Temporary inner counter
;//

wait_ca_10ms:
    MOV         R3,#12h
wait_R3x513c:
    MOV         R4,#0FFh
wait_R4x2c:
    DJNZ        R4,wait_R4x2c
    DJNZ        R3,wait_R3x513c
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Select scancode set 1
;//

set_scancode_set_1:
    MOV         scancode_table_ptr_hi,#((scancode_set_1_encode SHR 8) AND 0FFh)
    MOV         scancode_table_ptr_lo,#(scancode_set_1_encode AND 0FFh)
    SETB        is_scancode_set_1
    CLR         is_scancode_set_3
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Select scancode set 2
;//

set_scancode_set_2:
    MOV         scancode_table_ptr_hi,#((scancode_set_2_encode SHR 8) AND 0FFh)
    MOV         scancode_table_ptr_lo,#(scancode_set_2_encode AND 0FFh)
    CLR         is_scancode_set_1
    CLR         is_scancode_set_3
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Subroutine: Select scancode set 3
;//

set_scancode_set_3:
    MOV         scancode_table_ptr_hi,#((scancode_set_3_encode SHR 8) AND 0FFh)
    MOV         scancode_table_ptr_lo,#(scancode_set_3_encode AND 0FFh)
    SETB        is_scancode_set_3
    CLR         is_scancode_set_1
    RET



;//////////////////////////////////////////////////////////////////////
;//
;// Boot procedure
;//
;//   Checks the system and initalizes the variables. When everything is
;//   done, the 0AAh status is queued to verify for the host that we are
;//   ready, then scanning is started and we jump to the main loop.
;//

init:
    CLR         EA
    MOV         DATA_AND_CLOCK,#0Ch         ; Set serial lines
    MOV         LEDS_AND_JUMPERS,#70h       ; Light all LEDs
    MOV         PSW,#00h                    ; Select register bank 0
    MOV         R0,#7Fh                     ; Clear entire INTMEM
clear_intmem:
    MOV         @R0,#00h
    DJNZ        R0,clear_intmem

;////////////////////////////////////////
;//
;// Set up registers and vatiabled
;//

    SETB        RS0                         ; Setup scanning registers
    MOV         R0,#current_keystate_bitmap
    MOV         R1,#held_keystate_bitmap
    MOV         R2,#-1

    CLR         RS0                         ; Setup main-loop registers
    MOV         R0,#scancode_tx_queue
    MOV         R1,#scancode_tx_queue

    MOV         SP,#stack_space-1           ; Setup other variables
    MOV         typematic_delay,#3Ah
    MOV         typematic_repeat_rate,#0Ch
    ACALL       restore_default_key_modes

;////////////////////////////////////////
;//
;// Get settings from jumpers
;//

    CLR         beep_enable_flag            ; Jumper ST3: Beeper default state
    JNB         DEFAULT_BEEP_JUMPER_ST3,set_keyboard_mode
    SETB        beep_enable_flag

set_keyboard_mode:
    MOV         A,LEDS_AND_JUMPERS          ; Jumpers ST1/ST2: Keyboard mode
    ANL         A,#30h
    SWAP        A
    JZ          mode_at
    DEC         A
    JZ          mode_3180
    DEC         A
    JZ          mode_xt
    SJMP        mode_at

mode_3180:
    ACALL       set_scancode_set_3          ; IBM 3180, normal, set 3 default
    SJMP        setup_timers

mode_xt:
    SETB        xt_mode_flag                ; PC/XT, special mode, set 1 only
    ACALL       set_scancode_set_1
    SETB        SERIAL_DATA_TX
    SJMP        setup_timers

mode_at:
    ACALL       set_scancode_set_2          ; PC/AT, normal, set 2 default

;////////////////////////////////////////
;//
;// Set up timers
;//

setup_timers:
    MOV         TH0,#00h                    ; Setup beep and scan timers
    MOV         TL0,#00h
    MOV         TH1,#33h
    MOV         TL1,#00h
    MOV         beep_duration,#18h
    MOV         IP,#08h
    MOV         TMOD,#21h

;////////////////////////////////////////
;//
;// Check ROM
;//

    MOV         DPTR,#00h
    MOV         R4,#00h
    CLR         C
    MOV         R3,PSW                      ; Save cleared carry-bit

rom_checksum_loop:
    MOV         PSW,R3                      ; Restore carry from previous add
    CLR         A
    MOVC        A,@A+DPTR                   ; Add byte + carry to checksum
    ADDC        A,R4
    MOV         R4,A                        ; Save current checksum
    MOV         R3,PSW                      ; Save carry to preserve overflow
    INC         DPTR                        ; Point to next byte
    MOV         A,DPH
    CJNE        A,#10h,rom_checksum_loop

    MOV         PSW,R3                      ; Add 1 now if last add overflowed
    JNC         rom_checksum_dome
    INC         R4
rom_checksum_dome:
    CJNE        R4,#0AAh,self_test_failed   ; Sum is epxected to be 0AAh

;////////////////////////////////////////
;//
;// Check RAM
;//

    MOV         DPL,R0                      ; Save R0
    MOV         R0,#7Fh                     ; Point to end of RAM

test_intram_loop:
    MOV         DPH,@R0                     ; Save byte at pointer
    MOV         A,R0                        ; Write pointer to RAM...
    MOV         @R0,A                       ; ...and verify that it sticke.
    XRL         A,@R0
    MOV         @R0,DPH                     ; Restore byte at pointer
    JNZ         intram_bad
    DJNZ        R0,test_intram_loop         ; Check next byte

    MOV         R0,DPL                      ; Restore R0

;////////////////////////////////////////
;//
;// Set verdict of self-test
;//

    MOV         prioritized_tx_byte,#0AAh   ; Send 0AAh if all is good
    SETB        tx_single_byte_flag
    SJMP        self_test_done

intram_bad:
    MOV         R0,DPL                      ; Still restore R0 on failure
self_test_failed:
    MOV         prioritized_tx_byte,#0FCh   ; Send 0FCh if selftest failed
    SETB        rx_and_tx_flag
    SETB        tx_single_byte_flag

;////////////////////////////////////////
;//
;// Get keylock states
;//

self_test_done:
    MOV         ROW_SELECT,#0ECh            ; Point to key-locks
    MOV         A,ROW_DATA                  ; Get and store state in variables
    ANL         A,#03h
    MOV         keylocks_state,A
    MOV         keylocks_prev_state,A

;////////////////////////////////////////
;//
;// Wait about 0.4s to let LEDs shine
;//

    MOV         R2,#03h
wait_R2x122625c_init:
    MOV         R3,#0FFh
wait_R3x479c_init:
    MOV         R4,#0EEh
wait_R4x2c_init:
    DJNZ        R4,wait_R4x2c_init
    DJNZ        R3,wait_R3x479c_init
    DJNZ        R2,wait_R2x122625c_init

;////////////////////////////////////////
;//
;// Boot clean-up
;//

    MOV         LEDS_AND_JUMPERS,#7Eh       ; Cut all LEDs

    SETB        in_init_flag                ; Send selftest status-byte to host
wait_for_clock_cleared:
    JB          SERIAL_CLOCK_RX,wait_for_clock_cleared
    MOV         IE,#8Ah
    SETB        TR1
    LCALL       push_tx
    CLR         in_init_flag

    SETB        TR0                         ; Enable scanning
    CLR         NAVIGATION_NUMCASE_IGNORE_FLAG
    LJMP        main_loop                   ; Goto main-loop



;//////////////////////////////////////////////////////////////////////
;//
;// Key data-tables
;//

scancode_set_1_encode:
    DB          2Ah, 7Fh, 5Bh, 01h, 29h, 38h, 39h, 4Bh
    DB          38h, 52h, 1Dh, 4Dh, 00h, 50h, 34h, 1Dh
    DB          56h, 0Fh, 3Ah, 2Bh, 02h, 2Dh, 5Dh, 69h
    DB          6Ah, 53h, 48h, 50h, 00h, 4Fh, 0Eh, 2Ch
    DB          1Fh, 10h, 1Eh, 3Bh, 03h, 2Eh, 35h, 2Eh
    DB          36h, 1Ch, 1Ch, 30h, 51h, 22h, 47h, 4Bh
    DB          21h, 12h, 13h, 3Dh, 05h, 30h, 58h, 41h
    DB          42h, 4Eh, 57h, 6Ah, 4Dh, 37h, 46h, 4Ch
    DB          22h, 23h, 14h, 3Eh, 06h, 32h, 68h, 43h
    DB          0Eh, 39h, 44h, 64h, 49h, 69h, 00h, 48h
    DB          2Fh, 11h, 20h, 3Ch, 04h, 31h, 34h, 28h
    DB          27h, 4Ah, 2Bh, 4Fh, 37h, 53h, 51h, 35h
    DB          24h, 25h, 15h, 3Fh, 07h, 33h, 0Ah, 09h
    DB          0Bh, 6Eh, 0Ch, 47h, 6Dh, 52h, 6Bh, 6Ch
    DB          18h, 16h, 17h, 40h, 08h, 26h, 1Bh, 1Ah
    DB          19h, 67h, 0Dh, 49h, 66h, 08h, 45h, 65h

scancode_set_2_encode:
    DB          12h, 5Fh, 1Fh, 76h, 0Eh, 11h, 29h, 6Bh
    DB          11h, 70h, 14h, 74h, 00h, 72h, 34h, 14h
    DB          61h, 0Dh, 58h, 5Dh, 16h, 22h, 2Fh, 30h
    DB          38h, 71h, 75h, 72h, 00h, 69h, 66h, 1Ah
    DB          1Bh, 15h, 1Ch, 05h, 1Eh, 21h, 4Ah, 21h
    DB          59h, 5Ah, 5Ah, 32h, 7Ah, 34h, 6Ch, 6Bh
    DB          2Bh, 24h, 2Dh, 04h, 25h, 32h, 07h, 83h
    DB          0Ah, 79h, 78h, 38h, 74h, 7Ch, 7Eh, 73h
    DB          34h, 33h, 2Ch, 0Ch, 2Eh, 3Ah, 28h, 01h
    DB          66h, 29h, 09h, 08h, 7Dh, 30h, 00h, 75h
    DB          2Ah, 1Dh, 23h, 06h, 26h, 31h, 49h, 52h
    DB          4Ch, 7Bh, 5Dh, 69h, 7Ch, 71h, 7Ah, 4Ah
    DB          3Bh, 42h, 35h, 03h, 36h, 41h, 46h, 3Eh
    DB          45h, 57h, 4Eh, 6Ch, 50h, 70h, 40h, 48h
    DB          44h, 3Ch, 43h, 0Bh, 3Dh, 4Bh, 5Bh, 54h
    DB          4Dh, 20h, 55h, 7Dh, 18h, 3Dh, 77h, 10h

scancode_set_3_encode:
    DB           12h,  9Bh,  8Bh,  08h,  0Eh,  19h,  29h,  61h
    DB           39h,  70h,  58h,  6Ah,  00h,  60h,  49h,  11h
    DB           13h,  0Dh,  14h,  53h,  16h,  22h,  8Dh, 0A3h
    DB          0A2h,  71h,  63h,  72h,  00h,  69h,  66h,  1Ah
    DB           1Bh,  15h,  1Ch,  07h,  1Eh,  21h,  4Ah, 0B1h
    DB           59h,  79h,  5Ah, 0B2h,  7Ah, 0B5h,  6Ch,  6Bh
    DB           2Bh,  24h,  2Dh,  17h,  25h,  32h,  5Eh,  37h
    DB           3Fh,  7Ch,  56h,  96h,  74h,  57h,  5Fh,  73h
    DB           34h,  33h,  2Ch,  1Fh,  2Eh,  3Ah,  94h,  47h
    DB           66h,  29h,  4Fh,  90h,  7Dh,  95h,  62h,  75h
    DB           2Ah,  1Dh,  23h,  0Fh,  26h,  31h,  49h,  52h
    DB           4Ch,  84h,  53h,  65h,  7Eh,  64h,  6Dh,  77h
    DB           3Bh,  42h,  35h,  27h,  36h,  41h,  46h,  3Eh
    DB           45h,  9Ah,  4Eh,  6Eh,  99h,  67h,  97h,  98h
    DB           44h,  3Ch,  43h,  2Fh,  3Dh,  4Bh,  5Bh,  54h
    DB           4Dh,  93h,  55h,  6Fh,  92h,  9Fh,  76h,  91h

    ;
    ; 76543210
    ;   ||||||
    ;   |||+++--- 0 = Normal Key
    ;   |||       1 = Extended Key
    ;   |||       2 = Extended Key, Non Shift/NumLock (Navigation)
    ;   |||       3 = Extended Key, Non Shift         (NumPad /)
    ;   |||       4 = PrtScr
    ;   |||       5 = Pause/Break
    ;   |||       6 = Key disabled
    ;   |||       7 = NOTIS special
    ;   |||
    ;   +++------ 0 = Normal Key
    ;             1 = L Shift
    ;             2 = R Shift
    ;             3 = Alt
    ;             4 = Ctrl
    ;             5 = Num Lock
    ;             6 = Caps Lock
    ;             7 = Insert
    ;

keytype_flags_table:
    DB          0C8h,  00h,  01h,  80h,  00h, 0D8h,  00h,  02h
    DB           99h,  80h, 0A1h,  02h,  06h,  02h,  87h, 0E0h
    DB           00h,  00h, 0F0h,  87h,  00h,  00h,  01h,  01h
    DB           01h,  80h,  02h,  80h,  06h,  80h,  00h,  00h
    DB           00h,  00h,  00h,  80h,  00h,  00h,  00h,  01h
    DB          0D0h,  81h,  00h,  01h,  80h,  01h,  80h,  80h
    DB           00h,  00h,  00h,  80h,  00h,  00h,  80h,  80h
    DB           80h,  00h,  80h,  00h,  80h,  84h,  80h,  80h
    DB           00h,  00h,  00h,  80h,  00h,  00h,  00h,  80h
    DB           00h,  87h,  80h,  00h,  80h,  00h,  85h,  80h
    DB           00h,  00h,  00h,  80h,  00h,  00h,  00h,  00h
    DB           00h,  80h,  00h,  82h,  80h,  02h,  82h,  83h
    DB           00h,  00h,  00h,  80h,  00h,  00h,  00h,  00h
    DB           00h,  00h,  00h,  82h,  00h, 0BAh,  00h,  00h
    DB           00h,  00h,  00h,  80h,  00h,  00h,  00h,  00h
    DB           00h,  00h,  00h,  82h,  00h,  01h, 0A8h,  00h

scancode_set_3_decode:
    DB          0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh, 0FFh,  23h
    DB           03h, 0FFh, 0FFh, 0FFh, 0FFh,  11h,  04h,  53h
    DB          0FFh,  0Fh,  00h,  10h,  12h,  21h,  14h,  33h
    DB          0FFh,  05h,  1Fh,  20h,  22h,  51h,  24h,  43h
    DB          0FFh,  25h,  15h,  52h,  31h,  34h,  54h,  63h
    DB          0FFh,  06h,  50h,  30h,  42h,  32h,  44h,  73h
    DB          0FFh,  55h,  35h,  41h,  40h,  62h,  64h,  37h
    DB          0FFh,  08h,  45h,  60h,  71h,  74h,  67h,  38h
    DB          0FFh,  65h,  61h,  72h,  70h,  68h,  66h,  47h
    DB          0FFh,  56h,  26h,  75h,  58h,  78h,  6Ah,  4Ah
    DB          0FFh, 0FFh,  57h,  5Ah,  77h,  7Ah,  3Ah,  3Dh
    DB           0Ah,  28h,  2Ah,  76h, 0FFh, 0FFh,  36h,  3Eh
    DB           0Dh,  07h,  4Eh,  1Ah,  5Dh,  5Bh,  1Eh,  6Dh
    DB          0FFh,  1Dh,  0Bh,  2Fh,  2Eh,  5Eh,  6Bh,  7Bh
    DB           09h,  19h,  1Bh,  3Fh,  3Ch,  4Fh,  7Eh,  5Fh
    DB          0FFh,  29h,  2Ch, 0FFh,  39h,  4Ch,  5Ch, 0FFh
    DB          0FFh, 0FFh, 0FFh, 0FFh,  59h



;//////////////////////////////////////////////////////////////////////
;//
;// Unused data
;//

copyright:
    DB          '968551-02.1 '
    DB          'COPYRIGHT 1988 TANDBERG DATA A/S'

    DB          00h

    DB          'Patched by Frodevan 2023'

    DB          00h

checksum:
    DB          6Ah

    END
