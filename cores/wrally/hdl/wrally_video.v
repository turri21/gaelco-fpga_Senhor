// ============================================================================
//  World Rally (Gaelco) — Datapath de VIDEO de tilemaps (composicion + paleta)
//
//  Instancia los DOS motores de capa (wrally_tilemap), aplica el SCROLL desde los
//  vregs, mezcla (L1 fondo opaco, L0 encima con pen 0 transparente) y resuelve el
//  color por la paleta xBRG_444 -> RGB888. Sprites = aparte (FASE 4).
//
//  Convencion de coordenadas (fijada de golpe, = spike render_visible verif. vs MAME):
//    X = hpos + 8 ;  Y = vpos + 16            (origen del visarea 368x232)
//    L0: tmx=(X + vreg_l0x + 4)&1023, tmy=(Y + vreg_l0y)&511   (el +4 es de L0)
//    L1: tmx=(X + vreg_l1x   )&1023, tmy=(Y + vreg_l1y)&511
//  vregs (108000-108007): word0=L0 scrollY, word1=L0 scrollX, word2=L1 scrollY,
//                         word3=L1 scrollX.
//
//  Memorias SINCRONAS (block-RAM, latencia registrada 1): dos puertos VRAM, dos de
//  gfx y uno de paleta. Pipeline total hpos->RGB = 4 flancos (2 del tilemap, 1 de
//  la paleta, 1 del registro de salida).  Puertos VRAM/gfx duplicados por capa: el
//  arbitraje/time-mux a un solo banco fisico se resolvera en integracion.
// ============================================================================
`default_nettype none

module wrally_video (
    input  wire        clk,
    input  wire        ce,

    input  wire [9:0]  hpos,        // 0..367 (X visible)
    input  wire [8:0]  vpos,        // 0..231 (Y visible)

    // scroll crudo (palabras de vregs)
    input  wire [15:0] vreg_l0y,    // word0
    input  wire [15:0] vreg_l0x,    // word1
    input  wire [15:0] vreg_l1y,    // word2
    input  wire [15:0] vreg_l1x,    // word3

    // puerto VRAM + gfx de la capa 0
    output wire [13:0] vram_a0,
    input  wire [31:0] vram_q0,
    output wire [18:0] rom_a0,
    input  wire [7:0]  d0_i07, d0_i09, d0_i11, d0_i13,
    input  wire        gfx_ok0,   // handshake slot SDRAM gfx capa 0

    // puerto VRAM + gfx de la capa 1
    output wire [13:0] vram_a1,
    input  wire [31:0] vram_q1,
    output wire [18:0] rom_a1,
    input  wire [7:0]  d1_i07, d1_i09, d1_i11, d1_i13,
    input  wire        gfx_ok1,   // handshake slot SDRAM gfx capa 1

    // puerto de PALETA (1024 entradas xBRG_444)
    output wire [9:0]  pal_a,
    input  wire [15:0] pal_q,

    // salida RGB888 (registrada)
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    // nivel de prioridad del TILE ganador (para la mezcla con sprite en wrally_video_top), alineado con r/g/b
    output reg  [2:0]  tile_level,
    // índice de paleta del TILE ganador (0..0x1ff), 1 ciclo ANTES de r/g/b. Lo usa wrally_video_top
    // para el compositing de SOMBRA de sprite: idx_sombra = (tidx_pre & 0x3ff) + (shadowlevel<<10).
    output reg  [9:0]  tidx_pre
);
    // ---- scroll: coordenada del espacio del tilemap para cada capa ----
    wire [16:0] X = {7'b0, hpos} + 17'd8;
    wire [16:0] Y = {8'b0, vpos} + 17'd16;
    wire [16:0] s0x = X + {1'b0, vreg_l0x} + 17'd4;
    wire [16:0] s0y = Y + {1'b0, vreg_l0y};
    wire [16:0] s1x = X + {1'b0, vreg_l1x};
    wire [16:0] s1y = Y + {1'b0, vreg_l1y};
    wire [9:0] t0x = s0x[9:0];      // &1023
    wire [8:0] t0y = s0y[8:0];      // &511
    wire [9:0] t1x = s1x[9:0];
    wire [8:0] t1y = s1y[8:0];

    // ---- dos motores de capa (en lockstep: misma coordenada el mismo ciclo) ----
    wire [3:0] pen0, pen1;
    wire [4:0] color0, color1;
    wire       prio0, prio1;

    wrally_tilemap u_l0 (
        .clk(clk), .ce(ce), .tmx(t0x), .tmy(t0y), .layer(1'b0),
        .vram_a(vram_a0), .vram_q(vram_q0),
        .rom_a(rom_a0), .d_i07(d0_i07), .d_i09(d0_i09), .d_i11(d0_i11), .d_i13(d0_i13),
        .gfx_ok(gfx_ok0),
        .pen(pen0), .color(color0), .prio(prio0)
    );
    wrally_tilemap u_l1 (
        .clk(clk), .ce(ce), .tmx(t1x), .tmy(t1y), .layer(1'b1),
        .vram_a(vram_a1), .vram_q(vram_q1),
        .rom_a(rom_a1), .d_i07(d1_i07), .d_i09(d1_i09), .d_i11(d1_i11), .d_i13(d1_i13),
        .gfx_ok(gfx_ok1),
        .pen(pen1), .color(color1), .prio(prio1)
    );

    // ---- mezcla de TILES con PRIORIDAD (MAME wrally.cpp:293-304): gana el NIVEL mas alto ----
    //   L1 fondo (opaco): nivel 1, o 3 si CAT1 (prio1) & pen1!=0
    //   L0: nivel 2 (CAT0, pen!=0) ; 4 (CAT1, pen 1-7) ; 6 (CAT1, pen 8-15)
    //   (los niveles 5 y 7 = sprites baja/alta prioridad, se resuelven en wrally_video_top con tile_level)
    //   Para el TITULO (todo CAT0) se reduce a "L0 sobre L1 si pen0!=0" = el mezclador plano anterior.
    reg [8:0] tidx; reg [2:0] tlvl;
    always @* begin
        tidx = {color1, pen1};                            // L1 fondo
        tlvl = (prio1 & (|pen1)) ? 3'd3 : 3'd1;
        if (|pen0) begin
            if (~prio0) begin                             // L0 CAT0 -> nivel 2
                if (3'd2 > tlvl) begin tidx = {color0, pen0}; tlvl = 3'd2; end
            end else if (~pen0[3]) begin                  // L0 CAT1 pen 1-7 -> nivel 4
                if (3'd4 > tlvl) begin tidx = {color0, pen0}; tlvl = 3'd4; end
            end else begin                                // L0 CAT1 pen 8-15 -> nivel 6
                tidx = {color0, pen0}; tlvl = 3'd6;
            end
        end
    end
    assign pal_a = {1'b0, tidx};      // entradas 0..511 = tiles (0x200+ = sprites)

    // ---- paleta xBRG_444 -> RGB (1 ciclo) + tile_level retrasado 2 ce para alinear con r/g/b ----
    wire [7:0] pr, pg, pb;
    wrally_palette u_pal (.pal_word(pal_q), .r(pr), .g(pg), .b(pb));
    reg [2:0] tlvl_d1;
    always @(posedge clk) if (ce) begin
        r <= pr; g <= pg; b <= pb;
        tlvl_d1 <= tlvl; tile_level <= tlvl_d1;
        tidx_pre <= {1'b0, tidx};      // 1 ciclo antes de r/g/b (r va +2 desde tidx) -> listo en palb_a
    end

`ifdef SIMULATION
    // VIDDBG: ¿produce pixeles cada capa? cuenta pen!=0 de L0 (frente) y L1 (fondo) +
    // muestrea codigos/colores. Si pen1 (fondo) ~0 -> el tilemap de fondo no compone
    // (codigo de tile 0/blanco o lectura VRAM/gfx mala). Imprime cada ~2^20 ce.
    // PIXDBG: captura la cadena completa en 2 pixeles fijos (fondo y centro) 1x/frame.
    //   BG  = hpos~35,vpos~200 (en MAME = azul de fondo del auto-test)
    //   CEN = hpos~180,vpos~80 (zona de las barras de gradiente)
    // Imprime cuando vpos cambia a 200/80 en hpos objetivo. tidx/pal/rgb ~alineados (region uniforme).
    reg [9:0] fcnt=0; reg vpd=0;
    always @(posedge clk) if (ce) begin
        if (vpos==9'd0 && !vpd) fcnt <= fcnt + 1'b1;  // contador de frame (flanco vpos !=0 -> 0)
        vpd <= (vpos==9'd0);
        if (fcnt<31 && fcnt>=10) begin   // frames 10-30 (ya en estado "negro+bloques"; MAME limpio desde f4)
            if (vpos==9'd200 && hpos==10'd35)
                $display("PIXDBG f=%0d BG  vram_a1=%h vram_q1=%h | vram_a0=%h vram_q0=%h | pen1=%h col1=%h pen0=%h col0=%h tidx=%h",
                         fcnt, vram_a1, vram_q1, vram_a0, vram_q0, pen1,color1, pen0,color0, tidx);
            if (vpos==9'd80 && hpos==10'd180)
                $display("PIXDBG f=%0d VREGS L0y=%h L0x=%h L1y=%h L1x=%h (MAME: fff0 8045 ffef 0046)",
                         fcnt, vreg_l0y, vreg_l0x, vreg_l1y, vreg_l1x);
        end
    end
`endif

endmodule

`default_nettype wire
