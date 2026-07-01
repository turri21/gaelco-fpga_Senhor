// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 / chip GAE1) — Compositor de los 2 tilemaps (LINE-BUFFER).
//
//  REDISEÑO (2026-06-23): las 2 capas se RENDERIZAN POR LÍNEA a sus line buffers (motor
//  wrally2_gae1_tilemap, FSM espejo del de sprites, fetch gated por gfx_ok) y aquí sólo se
//  LEEN por X (hpos) y se compone la prioridad fija single-monitor (gaelco2_v.cpp screen_update):
//  fill(0) -> tm1 -> tm0 -> sprites. tm0 TAPA tm1; pen 0 transparente deja ver la capa inferior.
//  Motivo del rediseño: el prefetch on-the-fly con LEAD fijo no era robusto a la latencia SDRAM
//  variable (4 clientes en el banco gfx) -> streaking del gradiente. Ver wrally2_gae1_tilemap.v.
//
//  Scroll (screen_update): xoff0=0x14, xoff1=0x10, yoff=1; uniforme + LINESCROLL por línea
//  (vregs[L][15]). Se renderiza la línea SIGUIENTE (next_vpos) mientras se muestra la actual.
//  Los 4 regs de scroll + las 2 líneas de linescroll se leen del puerto wrd en rotación.
//
//  Salida: índice BASE de paleta del ganador (color*32+pen = {color7,pen5}, 12b) + opaco.
// ============================================================================
`default_nettype none

module wrally2_gae1_video (
    input  wire        clk,
    input  wire        ce,           // ce_pix
    input  wire [9:0]  hpos,         // 0..319 (área visible)
    input  wire [8:0]  vpos,         // 0..239
    input  wire        frame_end,    // última línea del frame -> wrap de next_vpos (fila 0 fresca)
    input  wire        index,        // single: pantalla a mostrar 0=izquierda (tilemap0), 1=derecha (tilemap1)
    input  wire        twin,         // 1=TWIN: izda (hpos<384)=tilemap0 | dcha (hpos>=384)=tilemap1

    input  wire [15:0] vreg0, vreg1, // bank=[11:9], linescroll_en=[15]

    // puerto de word genérico de wrally2_vmem (regs de scroll + linescroll), latencia 1 ce
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
    // FIX del corte/banda del tilemap (validado en aligator V013, mismo motor): el desfase del pipeline
    // de display NO se compensa con el scroll (wrappea el borde dcho); se compensa en la LECTURA del lb
    // como los sprites (SPR_HDLY). El motor renderiza sx 0..383 a un lb de 512 -> margen a ambos lados.
    //   TMOFF = 0 (sc = scroll, como golden).  lb_rx = (hpos - 14) & 0x1ff  (mueve el tilemap +14 a la dcha).
`ifdef WRALLY2_TMOFF
    localparam [9:0] TMOFF = `WRALLY2_TMOFF;
`else
    localparam [9:0] TMOFF = 10'd0;   // sc = scroll (como golden); el -14px es desfase de pipeline (ver lb_rx)
`endif
    wire [9:0] sc0x = (scroll0x_eff - TMOFF) & 10'h3ff;
    wire [9:0] sc1x = (scroll1x_eff - TMOFF) & 10'h3ff;
`ifdef WRALLY2_TMRD
    wire [9:0] lb_rx = (hpos + `WRALLY2_TMRD) & 10'h1ff;
`else
    wire [9:0] lb_rx = (hpos - 10'd14) & 10'h1ff;   // -14: NO cambia con el M10K lectura-registrada del lb del
                                                    // tilemap (el +1 clk se asienta dentro del periodo de píxel
                                                    // -> lb_q refleja el lb_x actual cuando ce_pix lo muestrea).
                                                    // Validado 0.00% vs mame_left con -14.
`endif
    // TWIN: la mitad DERECHA (hpos>=384) lee el line-buffer de tilemap[1] con hpos-384 (su X 0..383).
    wire [9:0] lb_rx1 = twin ? ((hpos - 10'd384 - 10'd14) & 10'h1ff) : lb_rx;

    wrally2_gae1_tilemap u_l0 (
        .clk(clk), .ce(1'b1), .start(start_r), .line(render_line),
        .scroll_x(sc0x), .scroll_y(scroll0y), .bank(bank0), .busy(),
        .tp_idx(tp0_idx), .tp_q(tp0_q),
        .rom_a(rom_a0), .d_p0(d0_p0), .d_p1(d0_p1), .d_p2(d0_p2), .d_p3(d0_p3), .gfx_ok(gfx0_ok),
        .lb_x(lb_rx), .lb_q(lb_q0), .wbank(wbank), .rbank(rbank)
    );
    wrally2_gae1_tilemap u_l1 (
        .clk(clk), .ce(1'b1), .start(start_r), .line(render_line),
        .scroll_x(sc1x), .scroll_y(scroll1y), .bank(bank1), .busy(),
        .tp_idx(tp1_idx), .tp_q(tp1_q),
        .rom_a(rom_a1), .d_p0(d1_p0), .d_p1(d1_p1), .d_p2(d1_p2), .d_p3(d1_p3), .gfx_ok(gfx1_ok),
        .lb_x(lb_rx1), .lb_q(lb_q1), .wbank(wbank), .rbank(rbank)
    );

    // ===== SELECCIÓN DE PANTALLA (index): wrally2 dual = 1 tilemap por pantalla (NO 2 capas como
    // aligator). Pantalla IZQUIERDA = tilemap[0] (color 0x00-3f). Pantalla DERECHA = tilemap[1]
    // (color 0x40-7f). Ambos tilemaps SE RENDERIZAN siempre (u_l0/u_l1); aquí se elige cuál mostrar.
    //   index=0 -> izquierda (tilemap[0]).  index=1 -> derecha (tilemap[1]).
    // El modo TWIN (Fase 2) leerá lb_q1 con hpos-384 para la mitad derecha; aquí (single) se muestra
    // la pantalla elegida a ancho completo (384). =====
    wire [4:0] pen0 = lb_q0[4:0]; wire [6:0] color0 = lb_q0[11:5];
    // Layer 1 (pantalla DERECHA) usa la paleta 0x40-0x7f: +0x40 al color del TILEMAP. El motor de tilemap
    // guarda el color SIN offset (es agnóstico de capa); aquí, en el compositor, se aplica el +0x40 SÓLO al
    // tilemap del derecho (FIX 2026-06-30: faltaba -> el fondo/logo de gaelco-presents del derecho en PARTIDA
    // salía NEGRO porque indexaba la paleta del izquierdo 0x00-0x3f, oscura en juego. Los sprites del derecho
    // ya llevan el 0x40 vía bit15, por eso el título -casi todo sprites- no lo destapaba). color1[6]=0 siempre.
    wire [4:0] pen1 = lb_q1[4:0]; wire [6:0] color1 = lb_q1[11:5] | 7'h40;
    // qué pantalla pinta este pixel: TWIN -> izda(hpos<SEAM)=tm0 / dcha=tm1; SINGLE -> index.
    // SEAM = 384 + 14: el selector debe cambiar cuando el tilemap1 ya lee contenido VÁLIDO. lb_rx1 =
    // (hpos-384-14) -> lb_rx1>=0 sólo desde hpos>=398; antes envuelve al pre-roll VACÍO del monitor
    // derecho (banda magenta de la costura). Con SEAM=398 el monitor izdo extiende su borde hasta la
    // costura y el derecho arranca con contenido. (El 14 = mismo offset de pipeline que lb_rx.)
    //   VALIDADO 2026-06-27: twin replay título = 0.00% vs MAME en AMBAS mitades. (Ajustable: WRALLY2_SEAM.)
`ifdef WRALLY2_SEAM
    wire        show1 = twin ? (hpos >= `WRALLY2_SEAM) : index;
`else
    wire        show1 = twin ? (hpos >= 10'd398) : index;
`endif
    wire        op_s  = show1 ? (pen1 != 5'd0) : (pen0 != 5'd0);
    wire [11:0] pal_s = show1 ? {color1, pen1} : {color0, pen0};
    always @(posedge clk) if (ce) begin
        if (op_s) begin pal_index <= pal_s;  opaque <= 1'b1; end
        else      begin pal_index <= 12'd0;  opaque <= 1'b0; end
    end
endmodule

`default_nettype wire
