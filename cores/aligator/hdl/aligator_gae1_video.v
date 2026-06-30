// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 / chip GAE1) — Compositor de los 2 tilemaps (LINE-BUFFER).
//
//  REDISEÑO (2026-06-23): las 2 capas se RENDERIZAN POR LÍNEA a sus line buffers (motor
//  aligator_gae1_tilemap, FSM espejo del de sprites, fetch gated por gfx_ok) y aquí sólo se
//  LEEN por X (hpos) y se compone la prioridad fija single-monitor (gaelco2_v.cpp screen_update):
//  fill(0) -> tm1 -> tm0 -> sprites. tm0 TAPA tm1; pen 0 transparente deja ver la capa inferior.
//  Motivo del rediseño: el prefetch on-the-fly con LEAD fijo no era robusto a la latencia SDRAM
//  variable (4 clientes en el banco gfx) -> streaking del gradiente. Ver aligator_gae1_tilemap.v.
//
//  Scroll (screen_update): xoff0=0x14, xoff1=0x10, yoff=1; uniforme + LINESCROLL por línea
//  (vregs[L][15]). Se renderiza la línea SIGUIENTE (next_vpos) mientras se muestra la actual.
//  Los 4 regs de scroll + las 2 líneas de linescroll se leen del puerto wrd en rotación.
//
//  Salida: índice BASE de paleta del ganador (color*32+pen = {color7,pen5}, 12b) + opaco.
// ============================================================================
`default_nettype none

module aligator_gae1_video (
    input  wire        clk,
    input  wire        ce,           // ce_pix
    input  wire [9:0]  hpos,         // 0..319 (área visible)
    input  wire [8:0]  vpos,         // 0..239
    input  wire        frame_end,    // última línea del frame -> wrap de next_vpos (fila 0 fresca)

    input  wire [15:0] vreg0, vreg1, // bank=[11:9], linescroll_en=[15]

    // puerto de word genérico de aligator_vmem (regs de scroll + linescroll), latencia 1 ce
    output wire [14:0] wrd_a,
    input  wire [15:0] wrd_q,

    // tilemap L0
    output wire [13:0] tp0_idx, input wire [31:0] tp0_q,
    output wire [21:0] rom_a0,  input wire [7:0] d0_p0, d0_p1, d0_p2, d0_p3, input wire gfx0_ok,
    // tilemap L1
    output wire [13:0] tp1_idx, input wire [31:0] tp1_q,
    output wire [21:0] rom_a1,  input wire [7:0] d1_p0, d1_p1, d1_p2, d1_p3, input wire gfx1_ok,

    // salida (registrada): índice base + opaco
    output reg  [11:0] pal_index,   // color*32 + pen (0..4095). 0 = backdrop
    output reg         opaque
);
    // ===== línea a renderizar (la siguiente) + bancos ping-pong =====
    reg [8:0] vpos_d;
    always @(posedge clk) vpos_d <= vpos;
    wire        line_change = (vpos != vpos_d);
    wire [8:0]  next_vpos   = frame_end ? 9'd0 : vpos + 9'd1;
    // +16 vertical: la visarea Y de MAME (gaelco2.cpp set_visarea(...,16,256-1)) empieza en 16, igual que
    //   thoop2/squash. La línea de DISPLAY next_vpos corresponde a la fila de BITMAP next_vpos+16. Sin esto
    //   todo sale 16px abajo y la rejilla del self-test deja un HUECO arriba. Validado golden==MAME 0.00%.
    wire [8:0]  render_line = next_vpos + 9'd16;   // fila de bitmap a renderizar (para tile Y + linescroll)
    wire        rbank = vpos[0];          // se MUESTRA vpos
    wire        wbank = next_vpos[0];     // se RENDERIZA next_vpos

    reg start_r;
    always @(posedge clk) start_r <= line_change;

    // ===== lectura rotativa de scroll + LINESCROLL (de la línea a renderizar = next_vpos) =====
    reg [2:0] scnt = 3'd0;
    reg [8:0] scroll0y, scroll1y;
    reg [9:0] scroll0x, scroll1x;        // x uniforme (fallback)
    reg [9:0] ls0, ls1;                  // linescroll x (ya con xoff)
    assign wrd_a = (scnt==3'd4) ? (15'h1000 + {6'd0, render_line}) :   // linescroll L0 por fila de BITMAP (+16)
                   (scnt==3'd5) ? (15'h1200 + {6'd0, render_line}) :   // linescroll L1

                                  (15'h1400 + {12'd0, scnt});
    always @(posedge clk) if (ce) begin
        scnt <= (scnt==3'd5) ? 3'd0 : scnt + 3'd1;
        case (scnt)
            3'd0: scroll0y <= wrd_q[8:0] + 9'd1;
            3'd1: scroll0x <= wrd_q[9:0] + 10'h14;
            3'd2: scroll1y <= wrd_q[8:0] + 9'd1;
            3'd3: scroll1x <= wrd_q[9:0] + 10'h10;
            3'd4: ls0      <= wrd_q[9:0] + 10'h14;
            3'd5: ls1      <= wrd_q[9:0] + 10'h10;
        endcase
    end
    wire [9:0] scroll0x_eff = vreg0[15] ? ls0 : scroll0x;
    wire [9:0] scroll1x_eff = vreg1[15] ? ls1 : scroll1x;

    wire [2:0] bank0 = vreg0[11:9];
    wire [2:0] bank1 = vreg1[11:9];

    // ===== 2 renderizadores de línea (line buffers) =====
    wire [11:0] lb_q0, lb_q1;
    // El line buffer se lee por hpos directo (0..319). El offset horizontal de fase del pipeline se
    // dobla en el SCROLL (tmx = sx + scroll - TMOFF), así no hay wrap del buffer en el borde izq.
    // TMOFF = offset horizontal del tilemap (calibración secundaria). HAY 2 COSAS sin cerrar (2026-06-26):
    //  (1) shift de la capa de barras (calibrable con TMOFF; a 14 casaban en sim).
    //  (2) BUG PRIMARIO: el tilemap NO pinta las ~14 columnas de la DERECHA (banda negra/corte del borde del
    //      marco), CONSTANTE sea cual sea TMOFF (grid en sim: contenido solo 0..305 vs golden 0..319). Hay que
    //      arreglar (2) PRIMERO (corte del render por la derecha) y luego recalibrar TMOFF con el frame completo.
    // De momento TMOFF=3 (baseline) para depurar (2) aislada. (14 arreglaba barras pero "cortaba" en HW.)
`ifdef ALIGATOR_TMOFF
    localparam [9:0] TMOFF = `ALIGATOR_TMOFF;
`else
    localparam [9:0] TMOFF = 10'd0;   // 0 = sc=scroll (como golden). El -14px del tilemap NO se arregla con
                                      // scroll (wrappea el borde dcho); es desfase de pipeline (LAT=14) -> fix
                                      // = compensar la LECTURA del lb como los sprites (SPR_HDLY). Ver lb_rx.
`endif
    wire [9:0] sc0x = (scroll0x_eff - TMOFF) & 10'h3ff;
    wire [9:0] sc1x = (scroll1x_eff - TMOFF) & 10'h3ff;
    // Compensación del pipeline de display (como SPR_HDLY de los sprites): lee el lb con offset.
    // Parametrizable para barrer en sim. El motor renderiza sx 0..383 -> hay margen a ambos lados.
`ifdef ALIGATOR_TMRD
    wire [9:0] lb_rx = (hpos + `ALIGATOR_TMRD) & 10'h1ff;
`else
    wire [9:0] lb_rx = (hpos - 10'd14) & 10'h1ff;   // -14 = mueve el tilemap +14 a la derecha (compensa el -14)
`endif

    aligator_gae1_tilemap u_l0 (
        .clk(clk), .ce(1'b1), .start(start_r), .line(render_line),
        .scroll_x(sc0x), .scroll_y(scroll0y), .bank(bank0), .busy(),
        .tp_idx(tp0_idx), .tp_q(tp0_q),
        .rom_a(rom_a0), .d_p0(d0_p0), .d_p1(d0_p1), .d_p2(d0_p2), .d_p3(d0_p3), .gfx_ok(gfx0_ok),
        .lb_x(lb_rx), .lb_q(lb_q0), .wbank(wbank), .rbank(rbank)
    );
    aligator_gae1_tilemap u_l1 (
        .clk(clk), .ce(1'b1), .start(start_r), .line(render_line),
        .scroll_x(sc1x), .scroll_y(scroll1y), .bank(bank1), .busy(),
        .tp_idx(tp1_idx), .tp_q(tp1_q),
        .rom_a(rom_a1), .d_p0(d1_p0), .d_p1(d1_p1), .d_p2(d1_p2), .d_p3(d1_p3), .gfx_ok(gfx1_ok),
        .lb_x(lb_rx), .lb_q(lb_q1), .wbank(wbank), .rbank(rbank)
    );

    // ===== prioridad fija: tm0 sobre tm1 sobre backdrop (pen 0 transparente) =====
    wire [4:0] pen0 = lb_q0[4:0]; wire [6:0] color0 = lb_q0[11:5];
    wire [4:0] pen1 = lb_q1[4:0]; wire [6:0] color1 = lb_q1[11:5];
    wire op0 = (pen0 != 5'd0);
`ifdef ALIGATOR_L0ONLY
    wire op1 = 1'b0;
`else
    wire op1 = (pen1 != 5'd0);
`endif
    always @(posedge clk) if (ce) begin
        if (op0)      begin pal_index <= {color0, pen0}; opaque <= 1'b1; end
        else if (op1) begin pal_index <= {color1, pen1}; opaque <= 1'b1; end
        else          begin pal_index <= 12'd0;          opaque <= 1'b0; end
    end
endmodule

`default_nettype wire
