// ============================================================================
//  Big Karnak (Gaelco, 1991) — bigkarnk_sound.v: subsistema de SONIDO.
//
//  LO NUEVO de Big Karnak frente a los demas Gaelco Tipo-1 (squash/thoop/biomtoy,
//  que cuelgan el OKI directo del bus del 68000): aqui hay una CPU de sonido
//  DEDICADA (MC6809E) con su propia ROM, que controla un YM3812 (OPL2) + OKIM6295.
//
//  Referencia de wiring JTFRAME: cores/kunio (jtframe_sys6809 + jtopl2).
//  Diferencias Big Karnak vs kunio:
//    - PCM = OKIM6295 (jt6295), NO MSM5205 (jt5205).
//    - El FIRQ del 6809 lo dispara el SOUNDLATCH (68k -> 0x70000f), no el OPL.
//
//  Mapa del 6809 (gaelco.cpp bigkarnk_snd_map):
//    0x0000-0x07ff  RAM (2 KB, interna a jtframe_sys6809)
//    0x0800-0x0801  OKIM6295 r/w
//    0x0a00-0x0a01  YM3812 r/w
//    0x0b00         soundlatch read  (ack del FIRQ)
//    0x0c00-0xffff  ROM (audiocpu region 0x10000 = 64 KB)
//
//  RELOJES (XTAL 8 MHz):  6809 E = 2 MHz (8/4) · YM3812 = 4 MHz (8/2) · OKI ~1 MHz (8/8).
//  Los cen_* los genera el game-top a partir de clk48 y se pasan por puerto.
//  ⚠ cen exactos a CALIBRAR contra MAME (sonido); la ESTRUCTURA es la fiel.
// ============================================================================
`default_nettype none

module bigkarnk_sound(
    input              clk,        // clk de juego (48 MHz)
    input              rst,

    input              cen_cpu,    // enable 6809 E (~2 MHz)
    input              cen_fm,     // enable YM3812 (~4 MHz)
    input              cen_oki,    // enable OKIM6295 (~1 MHz)

    // --- comunicacion con el 68000 ---
    input              snd_irq,    // flanco: el 68k escribio el soundlatch (0x70000f) -> FIRQ
    input      [ 7:0]  snd_latch,  // dato del soundlatch

    // --- ROM del 6809 (64 KB) ---
    output     [15:0]  rom_addr,
    output reg         rom_cs,
    input      [ 7:0]  rom_data,
    input              rom_ok,

    // --- ROM de samples del OKI (256 KB) ---
    output     [17:0]  pcm_addr,
    output             pcm_cs,
    input      [ 7:0]  pcm_data,
    input              pcm_ok,

    // --- salida de audio ---
    output signed [13:0] pcm,      // OKI 14-bit
    output signed [15:0] fm,       // YM3812 16-bit
    output             sample
);
`ifndef NOSOUND
    wire [15:0] A;
    wire        cpu_rnw;
    wire [ 7:0] cpu_dout, ram_dout, fm_dout, oki_dout;
    reg  [ 7:0] cpu_din;
    wire        firq_n;

    reg         ram_cs, oki_cs, fm_cs, latch_cs;

    // ----------------- decodificacion del mapa del 6809 -----------------
    always @(*) begin
        ram_cs   = 0;
        oki_cs   = 0;
        fm_cs    = 0;
        latch_cs = 0;
        rom_cs   = 0;
        if      ( A < 16'h0800 )            ram_cs   = 1;   // 0000-07ff
        else if ( A[15:8] == 8'h08 )        oki_cs   = 1;   // 0800-08xx
        else if ( A[15:8] == 8'h0a )        fm_cs    = 1;   // 0a00-0axx
        else if ( A[15:8] == 8'h0b )        latch_cs = 1;   // 0b00
        else if ( A >= 16'h0c00 )           rom_cs   = 1;   // 0c00-ffff
    end

    assign rom_addr = A;

    always @(*) begin
        cpu_din = rom_cs   ? rom_data  :
                  ram_cs   ? ram_dout  :
                  fm_cs    ? fm_dout   :
                  oki_cs   ? oki_dout  :
                  latch_cs ? snd_latch :
                  8'hff;
    end

    // ----------------- FIRQ desde el soundlatch -----------------
    // El 68k escribe 0x70000f -> snd_irq (flanco) -> set FF -> FIRQ del 6809.
    // El 6809 ackea leyendo el latch (latch_cs) -> clear FF.
    jtframe_ff u_firq(
        .clk     ( clk      ),
        .rst     ( rst      ),
        .cen     ( 1'b1     ),
        .din     ( 1'b1     ),
        .q       (          ),
        .qn      ( firq_n   ),
        .set     ( 1'b0     ),       // activo alto
        .clr     ( latch_cs ),       // activo alto: ack al leer el latch
        .sigedge ( snd_irq  )        // flanco que dispara el FF
    );

    // ----------------- MC6809E -----------------
    // CENDIV(0): cen ES el enable del bus E del 6809 (kunio usa el mismo patron).
    // RAM_AW(11) = 2 KB interna (0x0000-0x07ff).
    jtframe_sys6809 #(.RAM_AW(11),.CENDIV(0)) u_cpu(
        .rstn       ( ~rst     ),
        .clk        ( clk      ),
        .cen        ( cen_cpu  ),
        .cpu_cen    (          ),
        .VMA        (          ),
        // interrupciones
        .nIRQ       ( 1'b1     ),    // YM3812 IRQ no cableado al 6809 en bigkarnk (se poll-ea status)
        .nFIRQ      ( firq_n   ),
        .nNMI       ( 1'b1     ),
        .irq_ack    (          ),
        // bus sharing
        .bus_busy   ( 1'b0     ),
        // interfaz de memoria
        .A          ( A        ),
        .RnW        ( cpu_rnw  ),
        .ram_cs     ( ram_cs   ),
        .rom_cs     ( rom_cs   ),
        .rom_ok     ( rom_ok   ),
        .ram_dout   ( ram_dout ),
        .cpu_dout   ( cpu_dout ),
        .cpu_din    ( cpu_din  )
    );

    // ----------------- YM3812 (OPL2) @ 4 MHz -----------------
    jtopl2 u_opl(
        .rst    ( rst      ),
        .clk    ( clk      ),
        .cen    ( cen_fm   ),
        .din    ( cpu_dout ),
        .addr   ( A[0]     ),
        .cs_n   ( ~fm_cs   ),
        .wr_n   ( cpu_rnw  ),
        .dout   ( fm_dout  ),
        .irq_n  (          ),     // no se usa (poll de status)
        .snd    ( fm       ),
        .sample (          )
    );

    // ----------------- OKIM6295 @ ~1 MHz (sin banco) -----------------
    // Strobe de escritura: pulso de 1 clk en el flanco de un acceso de escritura del 6809.
    reg oki_wr_d;
    always @(posedge clk) oki_wr_d <= oki_cs & ~cpu_rnw;
    wire oki_wr_pulse = (oki_cs & ~cpu_rnw) & ~oki_wr_d;
    wire oki_wrn = ~oki_wr_pulse;

    assign pcm_cs = 1'b1;

    jt6295 #(.INTERPOL(0), .SAMPLE(0)) u_oki(
        .rst      ( rst      ),
        .clk      ( clk      ),
        .cen      ( cen_oki  ),
        .ss       ( 1'b1     ),       // PIN7_HIGH
        .wrn      ( oki_wrn  ),
        .din      ( cpu_dout ),
        .dout     ( oki_dout ),
        .rom_addr ( pcm_addr ),       // 256 KB (oki ROM = 0x40000), mapeo directo, sin banco
        .rom_data ( pcm_data ),
        .rom_ok   ( pcm_ok   ),
        .sound    ( pcm      ),
        .sample   ( sample   )
    );
`else
    assign rom_addr = 0;  initial rom_cs = 0;
    assign pcm_addr = 0;  assign pcm_cs = 0;
    assign pcm = 0;       assign fm = 0;  assign sample = 0;
`endif
endmodule

`default_nettype wire
