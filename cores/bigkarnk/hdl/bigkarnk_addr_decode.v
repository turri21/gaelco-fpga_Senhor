// ============================================================================
//  Big Karnak (Gaelco) — Decodificador de direcciones del bus del 68000
//
//  Mapa EXACTO de MAME (src/mame/gaelco/gaelco.cpp bigkarnk_map):
//    000000-07FFFF  ROM de programa (512 KB)
//    100000-101FFF  videoram (8 KB, SIN cifrar)   -> tilemaps L0/L1
//    102000-103FFF  screenram(8 KB, SIN cifrar)
//    108000-108007  vregs (4x u16 scroll)
//    10800C-10800D  irqack / watchdog (CLR INT6)
//    200000-2007FF  paleta (1024 entradas xBGR-555)
//    440000-440FFF  sprite RAM (4 KB)
//    700000 DSW1   700002 DSW2   700004 P1   700006 P2   700008 SERVICE
//    70000B  LS259 outlatch (coin lockout/counter; select 0x70 -> a[6:4])
//    70000F  soundlatch (escritura) -> FIRQ del 6809
//    FF8000-FFFFFF  work RAM (32 KB)  (Big Karnak NO lleva DS5002)
//
//  Decodificacion por rango (como el hardware real). Combinacional puro.
// ============================================================================
`default_nettype none

module bigkarnk_addr_decode (
    input  wire [23:0] addr,    // direccion de BYTE del 68000 (A0 implicito por UDS/LDS)
    input  wire        as,      // 1 = ciclo de bus valido (address strobe)

    output wire        cs_rom,      // 000000-07FFFF  ROM
    output wire        cs_vram,     // 100000-101FFF  videoram
    output wire        cs_scrram,   // 102000-103FFF  screenram
    output wire        cs_vregs,    // 108000-108007  registros de video
    output wire        cs_clrint,   // 10800C-10800D  CLR INT6
    output wire        cs_pal,      // 200000-2007FF  paleta
    output wire        cs_spr,      // 440000-440FFF  sprite RAM
    output wire        cs_dsw1,     // 700000-700001  DSW1
    output wire        cs_dsw2,     // 700002-700003  DSW2
    output wire        cs_p1,       // 700004-700005  P1
    output wire        cs_p2,       // 700006-700007  P2
    output wire        cs_service,  // 700008-700009  SERVICE
    output wire        cs_outlatch, // 70000B (+select 0x70)  LS259
    output wire        cs_sndlatch, // 70000F         soundlatch -> FIRQ 6809
    output wire        cs_wram      // FF8000-FFFFFF  work RAM
);
    assign cs_rom   = as & (addr[23:19] == 5'b00000);                                   // 000000-07FFFF (512KB)
    // 100000-103FFF: videoram (100000-101FFF) + screenram (102000-103FFF). addr[13]=0 video, =1 screen.
    wire blk_1xxx   = as & (addr[23:20] == 4'h1) & (addr[19:14] == 6'b000000);          // 100000-103FFF
    assign cs_vram  = blk_1xxx & ~addr[13];                                             // 100000-101FFF
    assign cs_scrram= blk_1xxx &  addr[13];                                             // 102000-103FFF
    assign cs_pal   = as & (addr[23:20] == 4'h2) & (addr[19:11] == 9'b0);               // 200000-2007FF
    assign cs_spr   = as & (addr[23:16] == 8'h44) & (addr[15:12] == 4'h0);              // 440000-440FFF
    assign cs_wram  = as & (addr[23:16] == 8'hFF) & addr[15];                           // FF8000-FFFFFF (32KB)

    // Bloque 108xxx: vregs (108000-108007) y CLR INT (10800C-10800D).
    wire blk_108 = as & (addr[23:12] == 12'h108);
    assign cs_vregs  = blk_108 & (addr[11:3] == 9'd0);                                  // 108000-108007 (8 bytes)
    assign cs_clrint = blk_108 & (addr[11:2] == 10'b0000000011);                        // 10800C-10800F

    // Bloque 7000xx: I/O. El 68000 no tiene A0 (byte por UDS/LDS) -> decodificar por word (a[7:1]).
    wire blk_70 = as & (addr[23:8] == 16'h7000);
    assign cs_dsw1     = blk_70 & (addr[7:1] == 7'h00);                                 // 700000-700001
    assign cs_dsw2     = blk_70 & (addr[7:1] == 7'h01);                                 // 700002-700003
    assign cs_p1       = blk_70 & (addr[7:1] == 7'h02);                                 // 700004-700005
    assign cs_p2       = blk_70 & (addr[7:1] == 7'h03);                                 // 700006-700007
    assign cs_service  = blk_70 & (addr[7:1] == 7'h04);                                 // 700008-700009
    // outlatch: 0x70000B con select 0x70 (responde a 0b,1b,..,7b; el bit lo da a[6:4]).
    assign cs_outlatch = blk_70 & ~addr[7] & (addr[3:0] == 4'hB);                       // 70000B (+select)
    assign cs_sndlatch = blk_70 & (addr[7:1] == 7'h07);                                 // 70000E-70000F (byte bajo 0F)
endmodule

`default_nettype wire
