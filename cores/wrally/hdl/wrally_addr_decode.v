// ============================================================================
//  World Rally (Gaelco) — Decodificador de direcciones del bus del 68000
//
//  Genera los chip-selects de cada region a partir de la direccion de BYTE del
//  68000 (A[23:0]) y un strobe de acceso valido (as = address strobe / bus cycle).
//  Mapa EXACTO de MAME (src/mame/gaelco/wrally.cpp main_map) — ver arquitectura.md:
//
//    000000-0FFFFF  ROM de programa (1 MB)
//    100000-103FFF  VRAM (16 KB, CIFRADA en escritura)
//    108000-108007  registros de video (vregs: scroll)
//    10800C-10800D  CLR INT video (ack de interrupcion)
//    200000-203FFF  paleta (16 KB, xBRG_444)
//    440000-440FFF  sprite RAM (4 KB)
//    700000         DSW        700002  P1_P2     700004  WHEEL    700008  SYSTEM
//    70000B         LS259 outlatch (monedas/luces/ctrl ADC)
//    70000D         OKI bankswitch          70000F  OKI read/write
//    FEC000-FEFFFF  work RAM (16 KB, COMPARTIDA con el DS5002FP)
//
//  Decodificacion por rango (como el hardware real): no se decodifican todos los
//  bits, basta con los rangos. Combinacional puro -> testeable al 100%.
// ============================================================================
`default_nettype none

module wrally_addr_decode (
    input  wire [23:0] addr,    // direccion de BYTE del 68000 (A23..A0; A0 implicito por UDS/LDS)
    input  wire        as,      // 1 = ciclo de bus valido (address strobe)

    output wire        cs_rom,      // 000000-0FFFFF  ROM
    output wire        cs_vram,     // 100000-103FFF  VRAM (cifrada)
    output wire        cs_vregs,    // 108000-108007  registros de video
    output wire        cs_clrint,   // 10800C-10800D  CLR INT video
    output wire        cs_pal,      // 200000-203FFF  paleta
    output wire        cs_spr,      // 440000-440FFF  sprite RAM
    output wire        cs_dsw,      // 700000-700001  DSW
    output wire        cs_p1p2,     // 700002-700003  P1_P2
    output wire        cs_wheel,    // 700004-700005  WHEEL (volante/joystick)
    output wire        cs_system,   // 700008-700009  SYSTEM (monedas/servicio)
    output wire        cs_outlatch, // 70000B         LS259 (coin/leds/ADC)
    output wire        cs_okibank,  // 70000D         OKI bankswitch
    output wire        cs_oki,      // 70000F         OKI read/write
    output wire        cs_wram      // FEC000-FEFFFF  work RAM (compartida DS5002)
);

    // Rangos amplios por los bits altos (A23..A20 / A16..) — como el decodificador real.
    assign cs_rom   = as & (addr[23:20] == 4'h0);                    // 000000-0FFFFF
    assign cs_vram  = as & (addr[23:20] == 4'h1) & (addr[19:14] == 6'b000000); // 100000-103FFF
    assign cs_pal   = as & (addr[23:20] == 4'h2) & (addr[19:14] == 6'b000000); // 200000-203FFF
    assign cs_spr   = as & (addr[23:16] == 8'h44) & (addr[15:12] == 4'h0);     // 440000-440FFF
    assign cs_wram  = as & (addr[23:16] == 8'hFE) & (addr[15:14] == 2'b11);    // FEC000-FEFFFF

    // Bloque 108xxx: vregs (108000-108007) y CLR INT (10800C-10800D).
    wire blk_108 = as & (addr[23:12] == 12'h108);
    assign cs_vregs  = blk_108 & (addr[11:3] == 9'd0);              // 108000-108007 (8 bytes)
    assign cs_clrint = blk_108 & (addr[11:2] == 10'b0000000011);    // 10800C-10800F (ack)

    // Bloque 7000xx: puertos de I/O. Se distinguen por A[7:0] (par/impar segun UDS/LDS).
    wire blk_70 = as & (addr[23:8] == 16'h7000);
    assign cs_dsw      = blk_70 & (addr[7:1] == 7'h00);            // 700000-700001
    assign cs_p1p2     = blk_70 & (addr[7:1] == 7'h01);            // 700002-700003
    assign cs_wheel    = blk_70 & (addr[7:1] == 7'h02);            // 700004-700005
    assign cs_system   = blk_70 & (addr[7:1] == 7'h04);            // 700008-700009
    // Registros de BYTE IMPAR (70000B/D/F): el 68000 NO tiene pin A0 (la seleccion de byte va
    // por UDS/LDS), asi que addr[0] siempre es 0 -> hay que decodificar por la palabra (addr[7:1])
    // y la logica de acceso usa LDS (byte bajo). Antes se usaba addr[7:0]==0x0F -> NUNCA matcheaba
    // (A0=0) -> el OKI/okibank/outlatch jamas se seleccionaban (el 68000 se colgaba esperando el
    // status del OKI que leia 0xFFFF). FIX 2026-06-15.
    assign cs_outlatch = blk_70 & (addr[7:1] == 7'h05);            // 70000A-70000B (byte bajo 0B)
    assign cs_okibank  = blk_70 & (addr[7:1] == 7'h06);            // 70000C-70000D (byte bajo 0D)
    assign cs_oki      = blk_70 & (addr[7:1] == 7'h07);            // 70000E-70000F (byte bajo 0F)

endmodule

`default_nettype wire
