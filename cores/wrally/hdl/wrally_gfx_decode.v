// ============================================================================
//  World Rally (Gaelco) — Decodificador de gfx de tile/sprite (16x16, 4bpp)
//
//  Layout `wrally_tilelayout16` (MAME), región gfx 2 MB partida a 1 MB (RGN_FRAC):
//    1ª mitad: bytes pares=i13, impares=i11    2ª mitad: pares=i09, impares=i07
//    planos {½+8,½+0,8,0} -> píxel bit0,1 de la 1ª mitad; bit2,3 de la 2ª.
//  Derivado (y VERIFICADO visualmente con el tilesheet, gráficos reconocibles):
//    romaddr = code*32 + row + (col>=8 ? 16 : 0)   // índice en cada ROM de 512KB
//    bit     = 7 - col[2:0]                          // MAME numera bits MSB-first
//    pix4    = { i07[bit], i09[bit], i11[bit], i13[bit] }  (i07=MSB ... i13=LSB)
//
//  El módulo da la DIRECCIÓN común a las 4 ROMs y, con los 4 bytes leídos, el píxel.
//  flipX/flipY se aplican fuera (en el motor de tile/sprite) sobre row/col.
// ============================================================================
`default_nettype none

module wrally_gfx_decode (
    input  wire [13:0] code,
    input  wire [3:0]  row,     // 0..15 (ya con flipY aplicado fuera si procede)
    input  wire [3:0]  col,     // 0..15 (ya con flipX aplicado fuera si procede)
    output wire [18:0] romaddr, // misma direccion para i07/i09/i11/i13 (512KB c/u)
    input  wire [7:0]  d_i07,   // bytes leidos en romaddr
    input  wire [7:0]  d_i09,
    input  wire [7:0]  d_i11,
    input  wire [7:0]  d_i13,
    output wire [3:0]  pix      // 0..15 (indice de pen dentro del bloque de color)
);
    // code*32 + (col>=8 ? 16 : 0) + row
    assign romaddr = {code, 5'b00000} + {14'b0, col[3], row};

    wire [2:0] b = 3'd7 - col[2:0];   // bit dentro del byte (MSB-first)
    assign pix = { d_i07[b], d_i09[b], d_i11[b], d_i13[b] };
endmodule

`default_nettype wire
