// ============================================================================
//  World Rally (Gaelco) — TOP de vídeo para HW: timing + datapath COMPLETO + MiSTer.
//
//  Une `wrally_video_timing` (FASE 1) + `wrally_video` (tilemaps, verificado) +
//  `wrally_sprite_layer` (sprites en tiempo real, doble buffer, verificado) con el
//  MEZCLADOR sprite-sobre-tilemap, y entrega RGB + sync/blank/DE + ce_pix al `sys/`
//  de MiSTer, más `vblank_irq` para la IRQ6 del 68000.
//
//  Alineación de pipeline: `wrally_video` saca RGB con latencia LATV=4 (ce_pix) desde
//  hpos. El camino de sprite (lb_q -> índice de paleta 0x200+(color<<4)+pen -> RGB) se
//  retrasa LATV para casar: 3 registros del {color,pen} + 1 de la lectura de paleta.
//  Los sync/blank/DE también se retrasan LATV para alinear con el RGB de salida.
//
//  Memorias como puertos: VRAM/paleta/sprite-RAM/gfx. La paleta necesita 2 PUERTOS de
//  lectura (A = tilemap dentro de wrally_video; B = sprites aquí) -> block-RAM dual-port.
// ============================================================================
`default_nettype none

module wrally_video_top #(
    parameter integer DEADJ = 0,  // fase DE/sync vs RGB (ce). ÓPTIMO=0 (2026-07-01, re-barrido contra
                                  // SNAPSHOT REAL DE MAME de frames exactos -oracle definitivo, no golden-):
                                  // DEADJ=0 -> SIM(frame 240 título)==MAME 0 DIFF pixel-perfect + nieve sin
                                  // shift. El barrido viejo (2026-06-11: +1:3460) usaba un golden que aún NO
                                  // era MAME-exacto -> eligió +1, dejando 1px de shift UNIFORME vs MAME (=el
                                  // "público recortado por la dcha": la col dcha de cada sprite caía sobre tilemap).
    parameter integer SPADJ = 1   // fase SPRITE vs TILEMAP (ce). ÓPTIMO=+1 (relativo a DEADJ; el shift de
                                  // DEADJ es UNIFORME y NO cambia el skew sprite-vs-tilemap). Sprite iba 1 ce adelantado.
)(
    input  wire        clk,
    input  wire        clk96,    // reloj SDRAM (2x clk): el MOTOR de sprites corre aqui para tener
                                 // presupuesto/scanline suficiente (a clk solo no termina -> rayas)
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [15:0] vreg_l0y, vreg_l0x, vreg_l1y, vreg_l1x,

    // --- memorias de tilemap (capa 0 y 1) ---
    output wire [13:0] vram_a0,  input  wire [31:0] vram_q0,
    output wire [18:0] rom_a0,   input  wire [7:0]  d0_i07, d0_i09, d0_i11, d0_i13,
    output wire [13:0] vram_a1,  input  wire [31:0] vram_q1,
    output wire [18:0] rom_a1,   input  wire [7:0]  d1_i07, d1_i09, d1_i11, d1_i13,
    input  wire        gfx0_ok, gfx1_ok,   // handshake slots SDRAM gfx tilemap (prefetch en wrally_tilemap)
    // --- paleta: puerto A (tilemap) y puerto B (sprites) ---
    output wire [9:0]  pal_a,    input  wire [15:0] pal_q,
    output wire [12:0] palb_a,   input  wire [15:0] palb_q,   // 13 bits: sprite normal (banco 0) o SOMBRA (banco shadowlevel)
    // --- sprite RAM + gfx de sprites ---
    output wire [10:0] spr_a,    input  wire [15:0] spr_q,
    output wire [18:0] srom_a,   input  wire [7:0]  sd_i07, sd_i09, sd_i11, sd_i13,
    input  wire        spr_gfx_ok,   // 1 = sd_iXX valido para srom_a (stall motor sprite con SDRAM)
    input  wire        spr_en,       // 0 = bypass de la capa de sprite (solo tilemap). v1: 0


    // --- salida de vídeo (interfaz MiSTer) ---
    output wire [7:0]  vga_r, vga_g, vga_b,
    output wire        hsync, vsync, hblank, vblank, de,
    output wire        ce_pix_o,
    output wire        vblank_irq
);
    // GFXLEAD = latencia EXTRA que anade el prefetch de gfx de wrally_tilemap (LEAD alli=7).
    // Se compensa SUMANDOLA a LATV (sync/DE) y a la cadena de sprites (SPN) -> shift UNIFORME,
    // el skew relativo (DEADJ/SPADJ) NO cambia. DEBE coincidir con `LEAD` de wrally_tilemap.
    localparam integer GFXLEAD = 7;
    localparam LATV = 5 + GFXLEAD;   // latencia hpos->RGB de wrally_video (ce_pix): 5 base (tras el
                           // registro de entrada de wrally_tilemap) + GFXLEAD del prefetch de gfx

    // ---- timing ----
    wire [9:0] hpos; wire [8:0] vpos;
    wire hs_i, vs_i, hb_i, vb_i, de_i;
    wrally_video_timing u_timing (
        .clk(clk), .rst(rst), .ce_pix(ce_pix),
        .hpos(hpos), .vpos(vpos),
        .hsync(hs_i), .vsync(vs_i), .hblank(hb_i), .vblank(vb_i),
        .de(de_i), .vblank_irq(vblank_irq)
    );

    // ---- tilemaps -> RGB + tile_level (prioridad), alineado con r_tm/g_tm/b_tm ----
    wire [7:0] r_tm, g_tm, b_tm;
    wire [2:0] tile_level;
    wire [9:0] tidx_pre;       // índice de paleta del tile (1 ce antes de r_tm) para sombra de sprite
    wrally_video u_video (
        .clk(clk), .ce(ce_pix), .hpos(hpos), .vpos(vpos),
        .vreg_l0y(vreg_l0y), .vreg_l0x(vreg_l0x), .vreg_l1y(vreg_l1y), .vreg_l1x(vreg_l1x),
        .vram_a0(vram_a0), .vram_q0(vram_q0), .rom_a0(rom_a0),
        .d0_i07(d0_i07), .d0_i09(d0_i09), .d0_i11(d0_i11), .d0_i13(d0_i13),
        .vram_a1(vram_a1), .vram_q1(vram_q1), .rom_a1(rom_a1),
        .d1_i07(d1_i07), .d1_i09(d1_i09), .d1_i11(d1_i11), .d1_i13(d1_i13),
        .gfx_ok0(gfx0_ok), .gfx_ok1(gfx1_ok),
        .pal_a(pal_a), .pal_q(pal_q),
        .r(r_tm), .g(g_tm), .b(b_tm), .tile_level(tile_level), .tidx_pre(tidx_pre)
    );

    // ---- sprites en tiempo real (doble buffer) ----
    wire [11:0] sp_lbq;      // {shadow_en, shadowlevel[2:0], color[3:0], pen[3:0]} para hpos actual
    wire       sp_lbq_high;  // high_priority del pixel de sprite
    // MOTOR de sprites a clk48 (= MISMO dominio que spr_q en wrally_vmem; clk96 rompia el
    // esquema de lectura de 3 ciclos -> sprites basura). El presupuesto/scanline (3072 clk48)
    // basta gracias al EARLY-OUT de la FSM (sprites fuera de linea saltan lecturas w2/w3).
    // La lectura del line-buffer (lb_q por hpos) es async -> el display sigue alineado a clk/ce_pix.
    // VVIS/VTOTAL DEBEN casar con wrally_video_timing (232/250 desde 2026-07-01, antes 232/260 y el default
    // 264 del módulo NO casaba -> la línea 0 se renderizaba en el wrap con line equivocada; ahora correcto).
    wrally_sprite_layer #(.VVIS(232), .VTOTAL(250)) u_spr (
        .clk(clk), .rst(rst), .ce_pix(ce_pix), .vpos(vpos), .hpos(hpos),
        .spr_a(spr_a), .spr_q(spr_q),
        .rom_a(srom_a), .d_i07(sd_i07), .d_i09(sd_i09), .d_i11(sd_i11), .d_i13(sd_i13),
        .gfx_ok(spr_gfx_ok),
        .lb_q(sp_lbq), .lb_high(sp_lbq_high), .busy()
    );

    // ---- alineación del camino de sprite a LATV=5 (tap parametrizable con SPADJ) ----
    // Cadena de registros del {color,pen}; palb_a sale del tap SPN (combinacional) ->
    // palb_q llega 1 ce_pix después, alineado con el registro SPN+1 (de donde sale el pen).
    // SPN=3 reproduce el diseño original (sp3->palb_a, sp4->pen). SPADJ desplaza el tap
    // para corregir el skew sprite-vs-tilemap (la latencia L_sp del sprite_layer).
    // SPN = tap base (3+SPADJ) + GFXLEAD: el camino de tile ahora sale GFXLEAD ce_pix mas tarde
    // (prefetch de gfx), asi que el sprite se retrasa lo mismo para seguir alineado (SPN=LATV-1).
    localparam integer SPN = 3 + SPADJ + GFXLEAD;
    reg [12:0] spr_sr [0:SPN+2];             // {high_prio, shadow_en, shadowlevel[2:0], color[3:0], pen[3:0]}; tap móvil con SPADJ
    integer si;
    always @(posedge clk) if (ce_pix) begin
        spr_sr[0] <= {sp_lbq_high, sp_lbq};
        for (si = 1; si <= SPN+2; si = si + 1) spr_sr[si] <= spr_sr[si-1];
    end
    // índice = 0x200 + (color<<4) + pen = {2'b10, color[3:0], pen[3:0]}. (Sprite NORMAL; el sprite
    // SOMBRA -bit[11]- queda invisible aquí: pen=0 -> transparente. El compositing de sombra real
    // -re-leer paleta en banco shadowlevel<<10- se añadirá con un dump de gameplay para validar la alineación.)
    // SOMBRA (MAME): si el sprite en el tap SPN es sombra (bit11), palb_a apunta al tile de debajo
    // en el banco OSCURECIDO: {shadowlevel, tidx_pre} = tidx_pre + (shadowlevel<<10). Si no, sprite
    // normal: 0x200 + (color<<4) + pen. tidx_pre (1 ce antes de r_tm) se alinea con spr_sr[SPN].
    wire       spr_shadow_a = spr_sr[SPN][11];
    wire [2:0] spr_sl_a     = spr_sr[SPN][10:8];
    wire       spr_pen_a    = (spr_sr[SPN][3:0] != 4'd0);  // ¿hay pen? (coche/baliza bajo la sombra)
    // SOMBRA (MAME mix_sprites 182-184): si hay pen!=0 (coche bajo la luz) -> el PEN DEL COCHE en el banco
    // shadowlevel ((0x200+color+pen) + shadowlevel<<10) = el coche con el tinte de luz, NO desaparece.
    // Si pen==0 -> sombra sobre fondo (tile de debajo en banco shadowlevel = el haz ilumina la carretera).
    // Si no es sombra -> sprite normal.
    assign palb_a = (spr_shadow_a & spr_pen_a) ? {spr_sl_a, 2'b10, spr_sr[SPN][7:0]} // coche+sombra
                  : spr_shadow_a               ? {spr_sl_a, tidx_pre}                // sombra sobre fondo
                  :                              {3'b0, 2'b10, spr_sr[SPN][7:0]};     // sprite normal
    wire [3:0] spr_pen    = spr_sr[SPN+1][3:0];   // pen alineado con palb_q
    wire       spr_high   = spr_sr[SPN+1][12];    // high_priority alineado con el pen
    wire       spr_shadow = spr_sr[SPN+1][11];    // es-sombra alineado con palb_q/r_sp

    // decodifica el color del sprite (xBRG_444 -> RGB)
    wire [7:0] r_sp, g_sp, b_sp;
    wrally_palette u_spal (.pal_word(palb_q), .r(r_sp), .g(g_sp), .b(b_sp));

    // ---- mezclador con PRIORIDAD por NIVEL (MAME wrally.cpp:293-304): gana el nivel mas alto ----
    //   sprite: nivel 5 (prioridad baja) o 7 (alta = code>=0x3700) ; pen 0 = transparente (nivel 0).
    //   tile_level (de wrally_video) = 1..6. El sprite tapa al tile SOLO si su nivel es MAYOR -> p.ej.
    //   un tile L0 CAT1 pen 8-15 (nivel 6) queda POR ENCIMA de un sprite de prioridad baja (nivel 5).
    //   Para el TITULO (tiles CAT0 = niveles 1-2, sprites nivel 5/7) se reduce a "sprite sobre tile".
    // un pixel de sprite "existe" si tiene pen!=0 (normal) O es sombra (oscurece aunque pen=0).
    wire       spr_present = spr_shadow | (spr_pen != 4'd0);
    wire [2:0] spr_level = spr_present ? (spr_high ? 3'd7 : 3'd5) : 3'd0;
    wire       use_spr   = spr_en & (spr_level > tile_level);
    wire [7:0] mix_r = use_spr ? r_sp : r_tm;
    wire [7:0] mix_g = use_spr ? g_sp : g_tm;
    wire [7:0] mix_b = use_spr ? b_sp : b_tm;

    // ---- sync/blank/DE retrasados (LATV+DEADJ) para alinear con el RGB ----
    localparam integer SD = LATV + DEADJ;   // profundidad del retardo de sync/DE
    reg [SD-1:0] hs_sr, vs_sr, hb_sr, vb_sr, de_sr;
    always @(posedge clk) if (ce_pix) begin
        hs_sr <= {hs_sr[SD-2:0], hs_i};
        vs_sr <= {vs_sr[SD-2:0], vs_i};
        hb_sr <= {hb_sr[SD-2:0], hb_i};
        vb_sr <= {vb_sr[SD-2:0], vb_i};
        de_sr <= {de_sr[SD-2:0], de_i};
    end
    assign hsync  = hs_sr[SD-1];
    assign vsync  = vs_sr[SD-1];
    assign hblank = hb_sr[SD-1];
    assign vblank = vb_sr[SD-1];
    assign de     = de_sr[SD-1];

    // negro fuera del área visible (DE alineado con el RGB)
    assign vga_r = de ? mix_r : 8'd0;
    assign vga_g = de ? mix_g : 8'd0;
    assign vga_b = de ? mix_b : 8'd0;
    assign ce_pix_o = ce_pix;

endmodule

`default_nettype wire
