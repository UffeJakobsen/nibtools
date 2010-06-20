; Burst Nibbler - main floppy routines
; V1.0 Assembled code matches original code exactly
;
; Remaining questions (from original analysis):
;  * _format_track  : Is the SYNC being deleted here?
;    We write $55 512 times, then write $ff 10 times and then write
;    $55 again, 7424 times (total 7946 bytes).  This clearly overwrites
;    all former data on the track including SYNC marks.
;    ! But, a new SYNC mark is written, one for the whole track
;
; (From Pete)
; It's writing 7696 bytes total at density 3, so it should not overwrite
; the sync unless the drive motor is really, really fast.  This is standard for 300RPM
;
; $c2: current track
; $c3-$c8: density statistic bins
;
; General description of routines
; ===============================
; This code is uploaded to the drive and then executed. It can be at most
; 1 KB ($300 - $700). The main_loop reads commands and executes them by
; a direct RTS. Each command is at least 5 bytes: a 4-byte header and then
; the command byte itself. A table at the end of this code links routines
; to command bytes.
;
; There are two forms of IO: interlocked (send_byte) and handshaked
; (read_gcr_1). Both use the parallel port for the actual byte transfer,
; but signal differently via the IEC lines. Interlocked IO involves toggling
; the ATN (host) and DATA lines (drive). It allows both sides to be sure
; their timing is correct. The host sets ATN to indicate it is ready for IO,
; then the drive releases DATA when it is ready. After the data byte is done
; (send or receive), the sender toggles its line. (The CPU releases ATN or
; the drive acquires DATA, depending on who was sending). Then the sequence
; can continue. This method is reliable but slightly slower than handshaked.
; It is used for commands and their status return value because some can
; take a long time (e.g., a seek) and the other side has to wait.
;
; Handshaked transfers only give one-way notification. The sending side
; toggles DATA when a byte is ready. Each edge (0->1 or 1->0) indicates
; another byte is ready. The other side just has to be fast enough to keep up.
; This is used for the high-speed transfer where bytes are ready quickly.
;
; After receiving a command, the drive indicates it is executing it by
; sending an interlocked byte to the host. This byte is not interpreted, but
; allows the host to wait for it. If the command was a parallel read or write,
; the host needs to be immediately ready to start transferring bytes via
; handshaked IO. Thus, it should not receive the ack byte until it is entering
; its tight IO loop.

.ifndef DRIVE
        .error "DRIVE must be defined as 1541 or 1571"
.elseif DRIVE = 1541
        PP_BASE = $1801
.elseif DRIVE = 1571
        PP_BASE = $4001
.else
        .error "DRIVE must be 1541 or 1571"
.endif

.org $300

_flop_main:
        SEI
        LDA  #$ee
        STA  $1c0c
        LDA  #$0b
        STA  $180c
        LDA  $1c00                ;
        AND  #$f3                 ; motor off, LED off
        STA  $1c00                ;
        LDA  #$24                 ;
        STA  $c2                  ; current halftrack = 36

_main_loop:
        LDX  #$45                 ;
        TXS                       ; reset stack
        TYA                       ; return value from last call
        JSR  _send_byte           ; Send byte to ack to the host that
                                  ; we are now in the main loop and
                                  ; ready for commands.
        LDA  #>(_main_loop-1)
        PHA                       ; set RTS to main_loop
        LDA  #<(_main_loop-1)
        PHA
        JSR  _read_command
        ASL                       ; * 2 for 16 bit index
        TAX
        LDA  _command_table+1,X
        PHA
        LDA  _command_table,X
        PHA
        RTS                       ; -> to command function

;----------------------------------------
; read out track w/out waiting for Sync
_read_track:
        JSR  _send_byte           ; parallel-send data byte to C64
        LDA  #$ff                 ;
        STA  $1800                ; send handshake
        LDX  #$20                 ; read $2000 GCR bytes
        STX  $c0                  ; (index for read loop)
        CLV                       ;
        BNE  _read_gcr_loop       ; read without waiting for Sync

;----------------------------------------
; read out track after waiting for sync
_read_after_sync:
        JSR  _send_byte           ; parallel-send data byte to C64

_in_sync:
        BIT  $1c00
        BMI  _in_sync             ; wait for end of Sync

        LDA  #$ff
        STA  $1800                ; send handshake
        LDX  #$20                 ; read $2000 GCR bytes
        STX  $c0

        LDX  $1c01                ; read GCR byte
        CLV
_wait_for_byte:
        BVC  _wait_for_byte
_read_gcr_loop:
        BVS  _read_gcr_1          ; wait for next GCR byte
        BVS  _read_gcr_1
        BVS  _read_gcr_1
        BVS  _read_gcr_1
        BVS  _read_gcr_1
        BVS  _read_gcr_1
        BVS  _read_gcr_1
        LDX  #$ff                 ; if pause too long, send 0xff  
        BVS  _read_gcr_1
        EOR  #$ff                 ; toggle handshake value
        BVS  _read_gcr_2          ; read and transfer GCR byte
        STX  PP_BASE              ; PA, port A (8 bit parallel data)
        BVS  _read_gcr_2          ; read and transfer GCR byte
        STA  $1701,x                ; send handshake (send 0xff byte)
        INY                       ;
_rtp6:
        BNE  _read_gcr_loop
        DEC  $c0                  ; total byte counter hb
        BEQ  _read_track_end
_rtp5:
        BVC  _read_gcr_loop
_read_gcr_1:
        LDX  $1c01                ; read GCR byte
        CLV
        EOR  #$ff                 ; toggle handshake flag
        STX  PP_BASE              ; PA, port A (8 bit parallel data)
        STA  $1800                ; send handshake
        INY
_rtp4:
        BNE  _read_gcr_loop
        DEC  $c0
_rtp3:
        BNE  _read_gcr_loop
_read_track_end:
        STY  $1800                ; send handshake: $00
        RTS                       ; done reading
_read_gcr_2:
        LDX  $1c01                ; read GCR byte
        CLV                       ;
        STX  PP_BASE              ; PA, port A (8 bit parallel data)
        STA  $1800                ; send handshake
        INY                       ;
_rtp2:
        BNE  _read_gcr_loop
        DEC  $c0                  ; total byte counter hb
_rtp1:
        BNE  _read_gcr_loop
        STY  $1800                ; send handshake: $00
        RTS                       ; done reading
        
        
;----------------------------------------
; read out track after index hole
_read_after_ihs:
        JSR  _send_byte           ; parallel-send data byte to C64
        LDA  #$10                 ; send L1 command to WD177x so we can query status
        STA  $2000               
        LDX #$20                  ; we do this here to satisfy 16/32 cycle wait
_ihsr_busywait:
        DEX
        BNE _ihsr_busywait;
        LDA #$02                  ; index hole is bit 1 in WD177x status register
_ihsr_wait_end:
        BIT  $2000                ; in case index hole is currently visible,
        BNE  _ihsr_wait_end       ; wait for its end
_ihsr_wait_start:
        BIT  $2000                ; now, wait for beginning of index hole
        BEQ  _ihsr_wait_start     ;

_ihsr_in_sync:
        BIT  $1c00
        BMI  _ihsr_in_sync        ; wait for end of Sync

        LDA  #$ff
        STA  $1800                ; send handshake
        LDX  #$20                 ; read $2000 GCR bytes
        STX  $c0

        LDX  $1c01                ; read GCR byte
        CLV
_ihsr_wait_byte:
        BVC  _ihsr_wait_byte
_ihsr_read_gcr_loop:
        BVS  _ihsr_read_gcr_1     ; wait for next GCR byte
        BVS  _ihsr_read_gcr_1
        BVS  _ihsr_read_gcr_1
        BVS  _ihsr_read_gcr_1
        BVS  _ihsr_read_gcr_1
        BVS  _ihsr_read_gcr_1
        BVS  _ihsr_read_gcr_1
        LDX  #$ff                 ; if pause too long, send 0xff (Sync?)
        BVS  _ihsr_read_gcr_1
        EOR  #$ff                 ; toggle handshake value
        BVS  _ihsr_read_gcr_2     ; read and transfer GCR byte
        STX  PP_BASE              ; PA, port A (8 bit parallel data)
        BVS  _ihsr_read_gcr_2     ; read and transfer GCR byte
        STA  $1701,x                ; send handshake (send 0xff byte)
        INY                       ;
_ihsr_rtp6:
        BNE  _ihsr_read_gcr_loop
        DEC  $c0                  ; total byte counter hb
        BEQ  _ihsr_read_track_end
_ihsr_rtp5:
        BVC  _ihsr_read_gcr_loop
_ihsr_read_gcr_1:
        LDX  $1c01                ; read GCR byte
        CLV
        EOR  #$ff                 ; toggle handshake flag
        STX  PP_BASE              ; PA, port A (8 bit parallel data)
        STA  $1800                ; send handshake
        INY
_ihsr_rtp4:
        BNE  _ihsr_read_gcr_loop
        DEC  $c0
_ihsr_rtp3:
        BNE  _ihsr_read_gcr_loop
_ihsr_read_track_end:
        STY  $1800                ; send handshake: $00
        RTS                       ; done reading
_ihsr_read_gcr_2:
        LDX  $1c01                ; read GCR byte
        CLV                       ;
        STX  PP_BASE              ; PA, port A (8 bit parallel data)
        STA  $1800                ; send handshake
        INY                       ;
_ihsr_rtp2:
        BNE  _ihsr_read_gcr_loop
        DEC  $c0                  ; total byte counter hb
_ihsr_rtp1:
        BNE  _ihsr_read_gcr_loop
        STY  $1800                ; send handshake: $00
        RTS                       ; done reading

;----------------------------------------
; Density Scan for current track
_scan_density:
        LDX  #$05                 ;
_scL1:
        STY  $c3,X                ; reset bit-rate statistic
        DEX                       ;
        BPL  _scL1                ;
_sc_retry:
        CLV                       ;
_scW1:
        BVC  _scW1                ; wait for GCR byte
        CLV                       ;
        LDA  $1c01                ; read GCR byte
        PHA                       ;
        PLA                       ; (busy wait timing)
        PHA                       ;
        PLA                       ;
_scL2:
        NOP                       ;
        BVS  _scJ1                ;
        BVS  _scJ2                ;
        BVS  _scJ3                ; measure bit-rate between bytes
        BVS  _scJ4                ;
        BVS  _scJ5                ;
        BVS  _scJ6                ;
        BNE  _sc_retry            ; -> time too long, retry with next pair
_scJ1:
        LDX  #$00                 ; bit-rate = 0
        BEQ  _scJ7                ;
_scJ2:
        LDX  #$01                 ; bit-rate = 1
        BNE  _scJ7                ;
_scJ3:
        LDX  #$02                 ; bit-rate = 2
        BNE  _scJ7                ;
_scJ4:
        LDX  #$03                 ; bit-rate = 3
        BNE  _scJ7                ;
_scJ5:
        LDX  #$04                 ; bit-rate = 4
        BNE  _scJ7                ;
_scJ6:
        LDX  #$05                 ; bit-rate = 5
        BNE  _scJ7                ;
_scJ7:
        CLV                       ;
        ; INC  $00c3,X            ; adjust statistic for bit-rate X
.byte $fe,$c3,$00                 ; INC  $00c3,X (not supported by C64asm)
        INY                       ;
        BPL  _scL2                ;

        LDY  #$00                 ;
_scL3:
        LDA  $00c4,Y              ; transfer density statistic 1-4 to C64
        JSR  _send_byte           ; parallel-send data byte to C64
        INY                       ;
        CPY  #$04                 ;
        BNE  _scL3                ;

        LDY  #$00                 ;
        RTS                       ;

;----------------------------------------
; step motor to destination halftrack
_step_dest:
        JSR  _read_byte           ; read byte from parallel data port
_step_dest_internal:
        LDX  #$01                 ; step value: step up
        CMP  $c2                  ; compare with current track (CARRY!!!)
        BEQ  _step_dest_end       ; destination track == current -> RTS
        PHA                       ; push destination track
        SBC  $c2                  ; calculate track difference
        BPL  _step_up             ; destination track > current ->
        EOR  #$ff                 ; else negate track difference
        LDX  #$ff                 ; step value: step down
_step_up:
        TAY                       ; # of tracks to step
_step_loop:
        TXA                       ; step value
        CLC                       ;
        ADC  $1c00                ;
        AND  #$03                 ;
        STA  $c0                  ; temp store
        LDA  $1c00                ;
        AND  #$fc                 ; mask off stepper bits
        ORA  $c0                  ;
        STA  $1c00                ; perform half step
        LDA  #$04                 ;
        STA  $c1                  ;
        LDA  #$00                 ; busy wait $0400 times
        STA  $c0                  ;
_stepL1:
        DEC  $c0                  ;
        BNE  _stepL1              ;
        DEC  $c1                  ;
        BNE  _stepL1              ;
        DEY                       ;
        BNE  _step_loop           ; repeat for # of halftracks
        PLA                       ; pull destination track
        STA  $c2                  ; current track = destination
_step_dest_end:
        RTS

;----------------------------------------
; adjust routines to density value
_adjust_density:
        JSR  _read_byte           ; read byte from parallel data port
        STA  _rtp1+1
        STA  _ihsr_rtp2+1  
        CLC                       ;
        ADC  #$04                 ;
        STA  _rtp2+1              ; adjust read routines to the
        STA  _ihsr_rtp2+1      
    	ADC  #$11                 ; density (timing) value read
        STA  _rtp3+1              ; from computer
        STA  _ihsr_rtp3+1  
        ADC  #$04                 ;
        STA  _rtp4+1              ;
        STA  _ihsr_rtp2+1  
        ADC  #$13                 ;
        STA  _rtp5+1              ;
        STA  _ihsr_rtp2+1  
        ADC  #$06                 ;
        STA  _rtp6+1              ;
        STA  _ihsr_rtp2+1  

;----------------------------------------
; set $1c00 bits (head/motor)
_set_1c00:
        JSR  _read_byte           ; read byte from parallel data port
        STA  $c0                  ; $1c00 mask
        JSR  _read_byte           ; read byte from parallel data port
        STA  $c1                  ; new bit value for $1c00
        LDA  $1c00                ;
        AND  $c0                  ; mask off $1c00 bits
        ORA  $c1                  ; set new $1c00 bits
        STA  $1c00                ;
        RTS                       ;

;----------------------------------------
; detect 'killer tracks' (all SYNC)
_detect_killer:

;        LDX #$10                  ; check for 16 non-SYNC bytes in a row
;        STX  $c0                  ;

        LDX  #$80                 ;
        STY  $C0                  ; Y = 0 (look for 256 non-SYNC bytes in a row)

_dkL1:
        LDA  $1c00                ; wait for SYNC
        BPL  _dk_sync             ; if SYNC found, check for 'killer track'
        DEY                       ;
        BNE  _dkL1                ; wait max. $8000 times for at least one SYNC
        DEX                       ;
        BNE  _dkL1                ;
        LDY  #$40                 ; track doesn't contain SYNC
        RTS                       ; -> $40 = track has no SYNC

_dk_sync:                         ; try to read some bytes within $10000 cycles
        LDX  #$00                 ;
        LDA  $1c01                ; read GCR byte
        CLV                       ;
_dkL2:
        DEY                       ;
        BNE  _dkWait              ; wait max $10000 times
        DEX                       ;
        BEQ  _dk_killer           ; timeout, not enough bytes found ->
_dkWait:
        BVC  _dkL2                ;
        CLV                       ;
        DEC  $c0                  ; check for at least $c0 bytes in track
        BNE  _dkWait              ;
        LDY  #$00                 ; track contains something
        RTS                       ; -> $00 = track OK

_dk_killer:
        LDY  #$80                 ; track only contains sync
        RTS                       ; -> $80 = killer track (too many syncs)

;----------------------------------------
; write a track on destination
_write_track:
        JSR  _read_byte           ; read byte from parallel data port
        STA  _wtB1+1              ; can change Sync Branch value
_wtL1:
        BIT  $1c00                ; wait for end of Sync, if writing
_wtB1:
        BMI  _wtL1                ;  halftracks, and 'adjust target'
                                  ;  selected, else BMI $0503
        LDA  #$ce                 
        STA  $1c0c
        TYA
        DEC  $1c03                ; CA data direction head (0->$ff: write)
        STA  $1800                ; send handshake

        LDX  #$00
        BEQ _shake

_write:
        BVC  _write               ; wait for byte ready
        STX  $1c01                ; write GCR byte to disk

_shake:
        ; (cycle count - we have ~32 cycles before next byte is ready)
        CLV                       ; clear byte ready (0+2 = 2)
        EOR  #$ff                 ; toggle handshake value (2+2 = 4)
        LDX  PP_BASE              ; get new parallel byte from host (4+4 = 8)
        STA  $1800                ; send handshake (4+8 = 12)
        BEQ  _wtL5                ; $00 byte = end of track (2+12 = 14)
        CPX  #$01                 ; did we get $01 byte? (2+14 = 16)
        BNE  _write               ; no -> write normal byte ((2+1) + 16 = 20)
        LDX  #$00                 ; change to $00 byte, weak/bad GCR (2+19 = 21)
        BEQ  _write               ; always branch back to write it
                                  ;  ((2+1) + 21 = 24 cycles worst case)
_wtL5:
        BVC  _wtL5
        CLV
        LDA  #$ee
        STA  $1c0c
        STX  $1c03                ; CA data direction head ($ff->0: read)
        STX  $1800                ; send handshake
        LDY  #$00
        RTS
        
;----------------------------------------
; write a track on destination after 1571 ihs
_ihs_write_track:
        JSR  _read_byte           ; read byte from parallel data port
        STA  _ihsw_wtB1+1         ; can change Sync Branch value
_ihsw_wtL1:
        BIT  $1c00                ; wait for end of Sync, if writing
_ihsw_wtB1:
        BMI  _ihsw_wtL1           ; halftracks, and 'adjust target'
                                  ; selected, else BMI $0503

        LDA  #$10                 ; send L1 command to WD117x so we can fetch status
        STA  $2000                ; we do this here to satisfy 16 cycle wait
        LDA  $180f                ; time requirement between command and status access
        PHA
        ORA  #$20
        TAX
        STX  $180f                ; enable 2MHz mode for tighter loops
        LDX  #$ce                 ; do this here for fast enabling
        
        LDA  #$02                 ; index hole is bit 1 in WD177x status register
_ihsw_wait_end:
        BIT  $2000                ; in case index hole is currently visible,
        BNE  _ihsw_wait_end       ; wait for its end
_ihsw_wait_start:
        BIT  $2000                ; wait for beginning of index hole
        BEQ  _ihsw_wait_start

        TYA
        STA  $1800                ; send handshake
        DEC  $1c03                ; CA data direction head (0->$ff: write)
        STX  $1c0c                ; enable output

        LDX  #$00
        BEQ _ihsw_shake
_ihsw_write:
        BIT  $180f                ; At 2MHz the V flag method is not reliable
        BMI  _ihsw_write          ; wait for byte ready
        STX  $1c01                ; write GCR byte to disk
_ihsw_shake:
        ; (at 2MHz, we have ~64 cycles before next byte is ready - no sweat)
        EOR  #$ff                 ; toggle handshake value
        LDX  PP_BASE              ; get new parallel byte from host
        STA  $1800                ; send handshake
        BEQ  _ihsw_wtL5           ; $00 byte = end of track
        CPX  #$01                 ; did we get $01 byte?
        BNE  _ihsw_write          ; no -> write normal byte
        LDX  #$00                 ; change to $00 byte, weak/bad GCR
        BEQ  _ihsw_write          ; always branch back to write it
_ihsw_wtL5:
        LDA  #$ee
_ihsw_wtL6:
        BIT  $180f
        BMI  _ihsw_wtL6
        STA  $1c0c                ; disable output as soon as possible
        STX  $1c03                ; CA data direction head ($ff->0: read)
        CLV
        STX  $1800                ; send handshake
        PLA
        STA  $180f                ; turn off 2MHz mode
        LDY  #$00
        RTS

;----------------------------------------
; read $1c00 motor/head status
_read_1c00:
        LDY  $1c00
        RTS

; ----------------------------------------
_send_byte:
        JMP  _send_byte_1         ; parallel-send data byte to C64

;----------------------------------------

        LDX  #$00
        STX  $b80c
        DEX
        STX  $b808
        LDX  #$04
        STX  $b80c
        BNE  _sbJ1

;----------------------------------------
_send_byte_1:
        LDX  #$ff                 ;
        STX  PP_BASE+2            ; data direction port A = output
_sbJ1:
        LDX  #$10                 ;
_sbL1:
        BIT  $1800                ; wait for ATN IN = 1
        BPL  _sbL1                ;
        STA  PP_BASE              ; PA, port A (8 bit parallel data)
        STX  $1800                ; handshake: ATN OUT = 1
        DEX                       ;
_sbL2:
        BIT  $1800                ;
        BMI  _sbL2                ; wait for ATN IN = 0
        STX  $1800                ; ATN OUT = 0
        RTS                       ;

;----------------------------------------
; read 1 byte with 4 byte command header
_read_command:
        LDY  #$04                 ; command header is 4 bytes long
_rcL1:
        JSR  _read_byte           ; read byte from parallel data port
        CMP  _command_header-1,Y  ; check with command header sequence:
        BNE  _read_command        ; $00,$55,$aa,$ff
        DEY                       ;
        BNE  _rcL1                ;
_read_byte:
        JMP  _read_byte_1         ; read byte from parallel data port

;----------------------------------------
        LDX  #$00
        STX  $b80c
        STX  $b808
        LDX  #$04
        STX  $b80c
        BNE  _rbJ1

_read_byte_1:
        LDX  #$00                 ;
        STX  PP_BASE+2            ; data direction port A = input
_rbJ1:
        LDX  #$10                 ;
_rbL1:
        BIT  $1800                ; wait for ATN IN = 1
        BPL  _rbL1                ;
        STX  $1800                ; handshake: ATN OUT = 1
        DEX                       ;
_rbL2:
        BIT  $1800                ;
        BMI  _rbL2                ; wait for ATN IN = 0
        LDA  PP_BASE              ; PA, port A (8 bit parallel data)
        STX  $1800                ; ATN OUT = 0
        RTS                       ;

;----------------------------------------
; send parallel port test sequence (0,1,2,...,$ff bytes) to C64
_send_count:
        TYA                       ;
        JSR  _send_byte           ; parallel-send data byte to C64
        INY                       ;  (send 0,1,2,...,$ff)
        BNE  _send_count          ;
        RTS                       ;

;----------------------------------------
_perform_ui:
        LDA  #$12                 ;
        STA  $22                  ; current track = 18
        JMP  $eb22                ; UI command (?)

;----------------------------------------
; measure destination track length
_measure_trk_len:
        LDX  #$20
        LDA  #$ce
        STA  $1c0c
        DEC  $1c03                ; CA data direction head (0->$ff: write)

        LDA  #$55                 ;
        STA  $1c01                ; write $55 byte
_mtL1:
        BVC  _mtL1                ;
        CLV                       ;
        INY                       ; write $2000 times
        BNE  _mtL1                ;
        DEX                       ;
        BNE  _mtL1                ;

        LDA  #$ff                 ;
        STA  $1c01                ; write $ff byte (Sync mark)
_mtL2:
        BVC  _mtL2                ;
        CLV                       ;
        INX                       ; write 5 times (short Sync)
        CPX  #$05                 ;
        BNE  _mtL2                ;

        LDA  #$ee
        STA  $1c0c
        STY  $1c03                ; CA data direction head ($ff->0: read)
_mtJ1:
        LDA  $1c00                ;
        BPL  _mt_end              ; 1st time: Sync, 2nd time: no Sync ->

_mtL3:
        BVC  _mtJ1                ; if no more bytes available ->
        CLV                       ;
        INX                       ; X/Y = counter: GCR bytes in one spin
        BNE  _mtL3                ;
        INY                       ;
        BNE  _mtL3                ;
_mt_end:
        TXA                       ; (0) : Track 'too long'
        JMP  _send_byte           ; parallel-send data byte to C64

;----------------------------------------
; align a short sync to all tracks on a disk
; Pete Rittwage 3/7/2010
_align_disk:
        JSR  _read_byte           ; read byte from parallel data port
        STA  _delay_loop+1         ; can change delay loop by 10ms
      
        LDA  #$ce
        STA  $1c0c
        DEC  $1c03                ; CA data direction head (0->$ff: write)
        
        LDA #$52  	 ; track 41	
       	STA $cf

 _admain:
	JSR _step_dest_internal
	;DEC  $1c03                ; CA data direction head (0->$ff: write)
	LDA  #$ff                 ;
        STA  $1c01                ; write $ff byte (Sync mark)
_adL1:
        BVC  _adL1                ;
        STA  $1c01                ; write $ff byte (Sync mark)
_adL2:
        BVC  _adL2                ;
        ;INC $1c03		 ; CA data direction head (ff>$0: read)

_delay_loop:
	LDY #$00
_dly:
	LDA #$00       ;SET TI ONE-SHOT MODE, WITH NO PB7
       	STA $180b
       	LDA #$e8       ;WRITE COUNT LSBY
       	STA $1804
       	LDA #$03       ;WRITE COUNT MSBY AND START TIMER
       	STA $1805
       	LDA #$40       ;SELECT T1 INTERRUPT MASK
_chkt1:
	BIT $180d      ; T1 COUNTED DOWN?
       	BEQ _chkt1      ;NO. WAIT UNTIL IT HAS
       	LDA $1804      ;YES. CLEAR T1 INTERRUPT FLAG
	DEY
	BNE _dly

     	DEC $cf
	DEC $cf
	LDA $cf
	BNE _admain 
	
        LDA  #$ee
        STA  $1c0c
        INC  $1c03                ; CA data direction head (0->$ff: write)
        RTS

;----------------------------------------
_verify_code:
        LDY  #$00
        STY  $c0
        LDA  #$03
        STA  $c1
_verify_L1:
        LDA  ($c0),Y
        JSR  _send_byte           ; parallel-send data byte to C64
        INY
        BNE  _verify_L1           ;
        INC  $c1
        LDA  $c1
        CMP  #$08
        BNE  _verify_L1
        RTS

;----------------------------------------
; completely fill a track with given byte
; used for unformat/kill

_fill_track:
        LDA  #$ce
        STA  $1c0c
        DEC  $1c03                ; CA data direction head (0->$ff: write)

	JSR  _read_byte           ; read byte from parallel data port
        LDX  #$20                 ;
        STA  $1c01                ; send byte to head
_ftL1:
        BVC  _ftL1                ;
        CLV                       ;
        INY                       ; write $2000 ($20 x $100) times
        BNE  _ftL1                ;
        DEX                       ;
        BNE  _ftL1                ;

        LDA  #$ee
        STA  $1c0c
        INC $1C03
        RTS
        
;----------------------------------------
; Command Jump table, return value: Y
_command_table:
.byte <(_step_dest-1),>(_step_dest-1)             ; step motor to destination halftrack
.byte <(_set_1c00-1),>(_set_1c00-1)               ; set $1c00 bits (head/motor)
.byte <(_perform_ui-1),>(_perform_ui-1)           ; track $22 = 17, UI command: $eb22
.byte <(_read_track-1),>(_read_track-1)           ; read out track w/out waiting for Sync
.byte <(_read_after_sync-1),>(_read_after_sync-1) ; read out track after Sync
.byte <(_read_after_ihs-1),>(_read_after_ihs-1)   ; read out track after IHS
.byte <(_adjust_density-1),>(_adjust_density-1)   ; adjust read routines to density value
.byte <(_detect_killer-1),>(_detect_killer-1)     ; detect 'killer tracks'
.byte <(_scan_density-1),>(_scan_density-1)       ; perform Density Scan
.byte <(_read_1c00-1),>(_read_1c00-1)             ; read $1c00 motor/head status
.byte <(_send_count-1),>(_send_count-1)           ; send 0,1,2,...,$ff bytes to C64
.byte <(_write_track-1),>(_write_track-1)         ; write a track on destination
.byte <(_ihs_write_track-1),>(_ihs_write_track-1) ; write track after variable Sync length
.byte <(_measure_trk_len-1),>(_measure_trk_len-1) ; measure destination track length
.byte <(_align_disk-1),>(_align_disk-1)           ; align sync on all tracks
.byte <(_verify_code-1),>(_verify_code-1)         ; send floppy side code back to PC
.byte <(_fill_track-1),>(_fill_track-1)           ; zero out (unformat) a track


_command_header:
.byte $ff,$aa,$55,$00                             ; command header code (reverse order)
