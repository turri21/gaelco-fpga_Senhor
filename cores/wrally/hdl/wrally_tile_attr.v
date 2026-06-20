// ============================================================================
//  World Rally (Gaelco) — Decodificador de atributos de TILE
//
//  Formato de MAME (wrally.cpp get_tile_info), 2 words VRAM por tile:
//    data  (word par):  [13:0] = code (tile 16x16)
//    data2 (word impar): [4:0]=color(paleta)  [5]=prioridad(categoria)
//                        [6]=flipX  [7]=flipY
//  La capa se selecciona por el bit 12 de la direccion de VRAM (Layer<<12).
//  Combinacional puro -> verificable.
// ============================================================================
`default_nettype none

module wrally_tile_attr (
    input  wire [15:0] data,    // word par de la VRAM
    input  wire [15:0] data2,   // word impar de la VRAM
    output wire [13:0] code,
    output wire [4:0]  color,
    output wire        prio,     // categoria/prioridad: por encima/debajo de sprites (data2[5])
    output wire        flipx,
    output wire        flipy
);
    assign code     = data[13:0];
    assign color    = data2[4:0];
    assign prio     = data2[5];
    assign flipx    = data2[6];
    assign flipy    = data2[7];
endmodule

`default_nettype wire
