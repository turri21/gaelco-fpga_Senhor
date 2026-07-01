// ============================================================================
//  World Rally (Gaelco) — CAPA de sprites en TIEMPO REAL (doble buffer).
//
//  Envuelve `wrally_sprite_engine` (doble line-buffer) y lo pilota en ping-pong:
//  mientras se MUESTRA la línea N (leyendo el banco N[0]), RENDERIZA la línea N+1 en
//  el otro banco. El motor corre a `clk` COMPLETO (ce=1), no a ce_pix, para tener
//  presupuesto de sobra (un scanline entero) para escanear los ~510 sprites.
//
//  Esquema de bancos (VTOTAL líneas, VVIS visibles):
//    - mostrar línea D (vpos=D)  -> rbank = D[0], buffer ya renderizado el scanline anterior
//    - render de next = (vpos==VTOTAL-1)?0:vpos+1  en wbank = next[0]
//    => la línea 0 se renderiza cuando vpos=VTOTAL-1 (último, en vblank) y está lista al envolver.
//
//  Disparo: 1 pulso de `start` en cada cambio de scanline (vpos cambia). Requiere que
//  el motor acabe dentro del scanline: clk debe ser >~6x el pixel clock (se cumple en
//  MiSTer). Si `busy` sigue alto al cambiar de línea => violación de presupuesto (el TB
//  lo vigila).
// ============================================================================
`default_nettype none

module wrally_sprite_layer #(
    parameter VVIS   = 232,
    parameter VTOTAL = 264
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce_pix,        // solo para muestrear el avance de línea
    input  wire [8:0]  vpos,          // línea visible actual (0..VVIS-1) / vblank
    input  wire [9:0]  hpos,          // x visible actual (0..367) = lb_x

    // sprite RAM (async)
    output wire [10:0] spr_a,
    input  wire [15:0] spr_q,
    // gfx ROM (registrada 1 ciclo)
    output wire [18:0] rom_a,
    input  wire [7:0]  d_i07, d_i09, d_i11, d_i13,
    input  wire        gfx_ok,        // 1 = d_iXX valido para rom_a (stall del motor con SDRAM).
                                      //     Atar a 1'b1 con memoria de latencia fija (BRAM/sim).

    // salida: pixel de sprite del banco que se MUESTRA esta línea
    output wire [11:0] lb_q,          // {shadow_en, shadowlevel[2:0], color[3:0], pen[3:0]}; pen 0 = transparente
    output wire        lb_high,       // high_priority del pixel (para la prioridad sprite-vs-tile)
    output wire        busy
);
    // detectar cambio de scanline (vpos cambia una vez por línea)
    reg [8:0] vpos_d;
    always @(posedge clk) vpos_d <= vpos;
    wire line_change = (vpos != vpos_d);

    // línea a renderizar este scanline = la que se MOSTRARÁ el siguiente
    wire [8:0] next_vpos = (vpos == VTOTAL-1) ? 9'd0 : (vpos + 9'd1);

    wire       rbank = vpos[0];           // banco que se muestra ahora
    wire       wbank = next_vpos[0];      // banco donde renderizar

    reg        start;
    always @(posedge clk or posedge rst) begin
        if (rst) start <= 1'b0;
        else     start <= line_change;    // 1 pulso de clk por scanline
    end

    wrally_sprite_engine u_spr (
        .clk(clk), .ce(1'b1), .gfx_ok(gfx_ok),   // gfx_ok=0 -> PADDR espera el dato (sin congelar todo)
        .start(start), .line(next_vpos + 9'd16),   // screenY = vpos_visible + 16
        .busy(busy), .done(),
        .spr_a(spr_a), .spr_q(spr_q),
        .rom_a(rom_a), .d_i07(d_i07), .d_i09(d_i09), .d_i11(d_i11), .d_i13(d_i13),
        .lb_x(hpos), .lb_q(lb_q), .lb_high(lb_high),
        .wbank(wbank), .rbank(rbank)
    );

`ifdef SPR_BARDBG
    // READ-side: cada display line, ¿qué lee el mezclador en x=289..294? (vpos aquí es la línea mostrada)
    always @(posedge clk) if (ce_pix) begin
        if (hpos==10'd291 && lb_q[3:0]!=4'd0)
            $display("READ vpos=%0d hpos=%0d rbank=%b lb_q=%h", vpos, hpos, rbank, lb_q);
    end
`endif
endmodule

`default_nettype wire
