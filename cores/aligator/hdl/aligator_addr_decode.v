// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 gaelco2.cpp) — Decodificador de direcciones del bus del 68000
//
//  Mapa EXACTO de MAME (gaelco2.cpp alighunt_map):
//    000000-0FFFFF  ROM de programa (1 MB)
//    200000-20FFFF  VRAM 64KB (GAE1: sprites + tilemaps + linescroll + scroll regs). vram_w
//    202890-2028FF  sound registers (GAE1)            (sub-rango dentro de 20xxxx; tiene prioridad)
//    210000-211FFF  paleta 8KB (xRRRRRGGGGGBBBBB)
//    218004-218009  video registers (vregs)
//    300000-300001  IN0 (DSW1 + P1)   300002-300003  IN1 (DSW2 + P2)
//    320000-320001  COIN + SERVICE
//    500000-500001  coin lockout/counters (alighunt_coin_w)   500006-500007 nopw
//    FE0000-FE7FFF  work RAM 32KB (privada)
//    FE8000-FEFFFF  work RAM COMPARTIDA con DS5002 (32KB) (= ventana MCU 0x8000-0xffff)
//
//  Decodificacion por rango. Combinacional puro. (68000 sin A0: byte por UDS/LDS.)
// ============================================================================
`default_nettype none

module aligator_addr_decode (
    input  wire [23:0] addr,    // direccion de BYTE del 68000
    input  wire        as,      // 1 = ciclo de bus valido (address strobe)

    output wire        cs_rom,      // 000000-0FFFFF  ROM
    output wire        cs_vram,     // 200000-20FFFF  VRAM (menos el sub-rango de sonido)
    output wire        cs_sound,    // 202890-2028FF  sound registers (GAE1)
    output wire        cs_pal,      // 210000-211FFF  paleta
    output wire        cs_vregs,    // 218004-218009  video registers
    output wire        cs_in0,      // 300000-300001  IN0 (DSW1+P1)
    output wire        cs_in1,      // 300002-300003  IN1 (DSW2+P2)
    output wire        cs_coin,     // 320000-320001  COIN + SERVICE
    output wire        cs_coinw,    // 500000-500001  coin lockout/counters
    output wire        cs_wram,     // FE0000-FE7FFF  work RAM privada
    output wire        cs_shram     // FE8000-FEFFFF  work RAM compartida con DS5002
);
    assign cs_rom  = as & (addr[23:20] == 4'h0);                         // 000000-0FFFFF

    // 200000-20FFFF: VRAM (64KB). El sub-rango 202890-2028FF son los regs de sonido (prioridad).
    wire blk_20    = as & (addr[23:16] == 8'h20);                        // 200000-20FFFF
    assign cs_sound= blk_20 & (addr[15:8] == 8'h28) & (addr[7:1] >= 7'h48); // 202890-2028FF (word>=0x2890)
    assign cs_vram = blk_20 & ~cs_sound;                                 // VRAM (resto)

    assign cs_pal  = as & (addr[23:16] == 8'h21) & (addr[15:13] == 3'b0);// 210000-211FFF (8KB)

    // 218004-218009: vregs (6 bytes = words 0x002,0x003,0x004).
    wire blk_218   = as & (addr[23:12] == 12'h218);
    assign cs_vregs= blk_218 & (addr[11:1] >= 11'h002) & (addr[11:1] <= 11'h004); // 218004-218009

    assign cs_in0  = as & (addr[23:1] == 23'h180000);                    // 300000-300001
    assign cs_in1  = as & (addr[23:1] == 23'h180001);                    // 300002-300003
    assign cs_coin = as & (addr[23:1] == 23'h190000);                    // 320000-320001
    assign cs_coinw= as & (addr[23:1] == 23'h280000);                    // 500000-500001

    assign cs_wram = as & (addr[23:15] == 9'b1111_1110_0);               // FE0000-FE7FFF (privada)
    assign cs_shram= as & (addr[23:15] == 9'b1111_1110_1);               // FE8000-FEFFFF (compartida DS5002)
endmodule

`default_nettype wire
