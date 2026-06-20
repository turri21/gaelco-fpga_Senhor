// ============================================================================
//  World Rally (Gaelco) — Conversor de color de paleta xBRG_444 -> RGB888
//
//  Formato de cada entrada de paleta (16 bits), confirmado en MAME emupal.h:
//      xBRG_444 = xxxxBBBBRRRRGGGG
//        [15:12] x (sin uso)   [11:8] B   [7:4] R   [3:0] G
//  Cada canal de 4 bits se expande a 8 replicando el nibble (pal4bit: c -> {c,c}),
//  que es la expansion estandar de MAME (4 bits -> 0,0x11,0x22,...,0xFF).
//
//  Combinacional puro -> verificable al 100% (ver tb_palette).
// ============================================================================
`default_nettype none

module wrally_palette (
    input  wire [15:0] pal_word,   // entrada de la RAM de paleta (xBRG_444)
    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b
);
    wire [3:0] b4 = pal_word[11:8];
    wire [3:0] r4 = pal_word[7:4];
    wire [3:0] g4 = pal_word[3:0];

    assign r = {r4, r4};   // 4 bits -> 8 bits por replicacion del nibble
    assign g = {g4, g4};
    assign b = {b4, b4};
endmodule

`default_nettype wire
