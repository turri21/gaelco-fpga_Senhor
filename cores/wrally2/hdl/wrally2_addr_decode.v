// ============================================================================
//  World Rally 2 (Gaelco, Tipo-2 gaelco2.cpp) — Decodificador de direcciones del bus del 68000
//
//  Mapa EXACTO de MAME (gaelco2.cpp wrally2_state::wrally2_map) — DISTINTO de aligator:
//    000000-0FFFFF  ROM de programa (1 MB)
//    200000-20FFFF  VRAM 64KB (GAE1: sprites + tilemaps + linescroll + scroll regs)
//    202890-2028FF  sound registers (GAE1)
//    210000-211FFF  paleta 8KB (xRRRRRGGGGGBBBBB)
//    212000-213FFF  RAM extra (no decodificada aparte: cae en cs_wram? NO -> tratar como RAM; ver nota)
//    218004-218009  video registers (vregs)
//    300000-300001  IN0 (P1 + DSW2)     300002-300003  IN1 (DSW1)
//    300004-300005  IN2 (P2 + COIN)     300006-300007  IN3 (SERVICE)
//    400000-40003F  LS259 (IC6): q5=ADC clk, q6=ADC cs, q0/q1=coin counters (select A3-A5)
//    FE0000-FE7FFF  work RAM 32KB (privada)
//    FE8000-FEFFFF  work RAM COMPARTIDA con DS5002 (32KB)
//
//  Decodificacion por rango. Combinacional puro. (68000 sin A0: byte por UDS/LDS.)
// ============================================================================
`default_nettype none

module wrally2_addr_decode (
    input  wire [23:0] addr,    // direccion de BYTE del 68000
    input  wire        as,      // 1 = ciclo de bus valido (address strobe)

    output wire        cs_rom,      // 000000-0FFFFF  ROM
    output wire        cs_vram,     // 200000-20FFFF  VRAM (menos el sub-rango de sonido)
    output wire        cs_sound,    // 202890-2028FF  sound registers (GAE1)
    output wire        cs_pal,      // 210000-211FFF  paleta
    output wire        cs_xram,     // 212000-213FFF  RAM extra (8KB)
    output wire        cs_vregs,    // 218004-218009  video registers
    output wire        cs_in0,      // 300000-300001  IN0 (P1 + DSW2)
    output wire        cs_in1,      // 300002-300003  IN1 (DSW1)
    output wire        cs_in2,      // 300004-300005  IN2 (P2 + COIN)
    output wire        cs_in3,      // 300006-300007  IN3 (SERVICE)
    output wire        cs_latch,    // 400000-40003F  LS259 (ADC clk/cs + coin counters)
    output wire        cs_wram,     // FE0000-FE7FFF  work RAM privada
    output wire        cs_shram     // FE8000-FEFFFF  work RAM compartida con DS5002
);
    assign cs_rom  = as & (addr[23:20] == 4'h0);                         // 000000-0FFFFF

    // 200000-20FFFF: VRAM (64KB). El sub-rango 202890-2028FF son los regs de sonido (prioridad).
    wire blk_20    = as & (addr[23:16] == 8'h20);                        // 200000-20FFFF
    assign cs_sound= blk_20 & (addr[15:8] == 8'h28) & (addr[7:1] >= 7'h48); // 202890-2028FF (word>=0x2890)
    assign cs_vram = blk_20 & ~cs_sound;                                 // VRAM (resto)

    assign cs_pal  = as & (addr[23:16] == 8'h21) & (addr[15:13] == 3'b0);// 210000-211FFF (8KB)
    assign cs_xram = as & (addr[23:13] == 11'h109);                      // 212000-213FFF RAM extra (8KB)

    // 218004-218009: vregs (6 bytes = words 0x002,0x003,0x004).
    wire blk_218   = as & (addr[23:12] == 12'h218);
    assign cs_vregs= blk_218 & (addr[11:1] >= 11'h002) & (addr[11:1] <= 11'h004); // 218004-218009

    assign cs_in0  = as & (addr[23:1] == 23'h180000);                    // 300000-300001
    assign cs_in1  = as & (addr[23:1] == 23'h180001);                    // 300002-300003
    assign cs_in2  = as & (addr[23:1] == 23'h180002);                    // 300004-300005
    assign cs_in3  = as & (addr[23:1] == 23'h180003);                    // 300006-300007

    // 400000-40003F: LS259 IC6. select A3-A5 -> 8 salidas; cs_latch alto en todo el rango.
    assign cs_latch= as & (addr[23:6] == 18'h10000);                     // 0x400000>>6 = 0x10000

    assign cs_wram = as & (addr[23:15] == 9'b1111_1110_0);               // FE0000-FE7FFF (privada)
    assign cs_shram= as & (addr[23:15] == 9'b1111_1110_1);               // FE8000-FEFFFF (compartida DS5002)
endmodule

`default_nettype wire
