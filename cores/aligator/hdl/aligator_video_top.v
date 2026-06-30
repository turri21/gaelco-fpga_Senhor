// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 / chip GAE1) — TOP de vídeo: timing + compositor + sprites + paleta.
//
//  Une aligator_video_timing + aligator_gae1_video (2 tilemaps 5bpp, prioridad fija) +
//  aligator_gae1_sprite (motor de sprites por línea, doble line-buffer, sombras RMW) +
//  aligator_gae1_palette (RGB555 + shadow/highlight) -> RGB 5-5-5 + sync/blank/DE + vblank_irq.
//
//  Prioridad single-monitor (gaelco2_v.cpp): fill(0) -> tm1 -> tm0 -> SPRITES. Los sprites se
//  pre-renderizan a un line-buffer (por screen-X) y se combinan con el índice del tilemap:
//   - sprite normal (idx!=0): TAPA el tilemap (idx propio = color*32+pen).
//   - sprite de sombra (color==0x7f): mete la variante (pen 1..15) en bits altos del índice del FONDO.
//
//  Latencia hpos->RGB = LAT ce_pix. El line-buffer se lee con hpos retrasada SPR_HDLY para alinear
//  con el pal_index del tilemap (calibrable, como HPHASE del tilemap).
// ============================================================================
`default_nettype none

module aligator_video_top #(
    parameter integer LAT      = 14,  // latencia hpos->RGB (ce_pix)
    parameter integer DEADJ    = 0,   // ajuste fino de fase sync/DE vs RGB
    parameter integer SPR_HDLY = 15   // hpos->pal_index (alinea el line-buffer de sprites; CALIBRADO vs golden: SAD 1.9/px)
)(
    input  wire        clk,
    input  wire        clk96,      // motor de SPRITES (fix overrun: render a 96, doble presupuesto/línea)
    input  wire        rst,
    input  wire        ce_pix,

    input  wire [15:0] vreg0, vreg1, vreg2,

    // VRAM (de aligator_vmem): par de tile L0/L1 + word genérico (scroll) + word sprites + paleta
    output wire [13:0] tp0_idx, input wire [31:0] tp0_q,
    output wire [13:0] tp1_idx, input wire [31:0] tp1_q,
    output wire [14:0] wrd_a,   input wire [15:0] wrd_q,
    output wire [14:0] spr_a,   input wire [15:0] spr_q,
    output wire [11:0] pal_a,   input wire [15:0] pal_q,
    // gfx (SDRAM, DW32 4 planos): 2 tilemaps + sprites
    output wire [21:0] rom_a0,  input wire [31:0] gfx0_data, input wire gfx0_ok,
    output wire [21:0] rom_a1,  input wire [31:0] gfx1_data, input wire gfx1_ok,
    output wire [21:0] rom_as,  input wire [31:0] gfxs_data, input wire gfxs_ok,

    // salida de vídeo (interfaz jtframe, COLORW=5)
    output wire [4:0]  vga_r, vga_g, vga_b,
    output wire        hsync, vsync, hblank, vblank, de,
    output wire        vblank_irq
);
    // ---- timing ----
    wire [9:0] hpos; wire [8:0] vpos; wire frame_end;
    wire hs_i, vs_i, hb_i, vb_i, de_i;
    aligator_video_timing u_timing (
        .clk(clk), .rst(rst), .ce_pix(ce_pix),
        .hpos(hpos), .vpos(vpos), .frame_end(frame_end),
        .hsync(hs_i), .vsync(vs_i), .hblank(hb_i), .vblank(vb_i),
        .de(de_i), .vblank_irq(vblank_irq)
    );

    // ---- 4 byte-lanes de la lectura DW32 de gfx -> planos p0..p3 ----
    // byte-lanes DW32 -> planos. El bcache de jtframe ensambla DW32 = {second_word, first_word}
    // (jtframe_romrq_bcache:110-120). Mi blob: first=p0,p1 second=p2,p3 -> gfx_data={p2,p3,p0,p1}.
    // => plano0 en [15:8], plano1 en [7:0], plano2 en [31:24], plano3 en [23:16].
    wire [7:0] d0_p0=gfx0_data[15:8], d0_p1=gfx0_data[7:0], d0_p2=gfx0_data[31:24], d0_p3=gfx0_data[23:16];
    wire [7:0] d1_p0=gfx1_data[15:8], d1_p1=gfx1_data[7:0], d1_p2=gfx1_data[31:24], d1_p3=gfx1_data[23:16];
    wire [7:0] ds_p0=gfxs_data[15:8], ds_p1=gfxs_data[7:0], ds_p2=gfxs_data[31:24], ds_p3=gfxs_data[23:16];

    // ---- compositor de tilemaps -> índice base de paleta ----
    wire [11:0] pal_index; wire opaque;
    aligator_gae1_video u_video (
        .clk(clk), .ce(ce_pix), .hpos(hpos), .vpos(vpos), .frame_end(frame_end),
        .vreg0(vreg0), .vreg1(vreg1),
        .wrd_a(wrd_a), .wrd_q(wrd_q),
        .tp0_idx(tp0_idx), .tp0_q(tp0_q),
        .rom_a0(rom_a0), .d0_p0(d0_p0), .d0_p1(d0_p1), .d0_p2(d0_p2), .d0_p3(d0_p3), .gfx0_ok(gfx0_ok),
        .tp1_idx(tp1_idx), .tp1_q(tp1_q),
        .rom_a1(rom_a1), .d1_p0(d1_p0), .d1_p1(d1_p1), .d1_p2(d1_p2), .d1_p3(d1_p3), .gfx1_ok(gfx1_ok),
        .pal_index(pal_index), .opaque(opaque)
    );

    // ---- motor de SPRITES (clk96; doble line-buffer ping-pong por línea) ----
    // FIX OVERRUN: el motor de sprites corre a clk96 -> DOBLE presupuesto de celdas por línea (a 48 MHz
    // no llegaba a pintar todas las celdas en escenas cargadas -> faltaban mitades/trozos). El resto del
    // vídeo (timing, compositor, paleta, salida) sigue a clk48/ce_pix. Cruce de dominio:
    //   * line buffers: ESCRITURA@96 (render), LECTURA ASÍNCRONA por hpos@48 (ping-pong -> sin R/W mismo banco).
    //   * start/render_line/wbank: generados en el dominio 96 muestreando vpos (clk96 = 2x clk48 fase-alineado).
    //   * spr vmem port (lectura) y gfxs (SDRAM) ya están a 96.
    reg [8:0] vpos_d;
    always @(posedge clk) vpos_d <= vpos;
    wire line_change = (vpos != vpos_d);            // (48) solo para el contador boot_skip de sim
    wire rbank = vpos[0];                           // banco que MUESTRA el display (lectura async @48)

    // SOLO-SIM: saltar la basura de spriteRAM del boot. En replay la escena ya está limpia.
    wire boot_skip;
`ifdef ALIGATOR_SCENE
    assign boot_skip = 1'b0;
`elsif SIMULATION
    reg [15:0] frm = 0;
    always @(posedge clk) if (line_change && vpos==9'd0) frm <= frm + 16'd1;
    assign boot_skip = (frm < 16'd150);
`else
    assign boot_skip = 1'b0;
`endif

    // --- arranque de línea generado en el dominio clk96 (muestreo mesócrono de vpos/frame_end) ---
    reg [8:0] vpos96, vpos96_d; reg fe96;
    always @(posedge clk96) begin vpos96 <= vpos; vpos96_d <= vpos96; fe96 <= frame_end; end
    wire       line_change96 = (vpos96 != vpos96_d);
    // WRAP a 0 en frame_end -> la línea 0 se renderiza FRESCA. +16 = visarea Y de MAME (gaelco2).
    wire [8:0] next_vpos96   = fe96 ? 9'd0 : vpos96 + 9'd1;
    wire [8:0] render_line   = next_vpos96 + 9'd16;     // fila de bitmap a renderizar (Y del sprite)
    wire       wbank         = next_vpos96[0];          // banco que RENDERIZA el motor @96

    reg spr_start;
    always @(posedge clk96 or posedge rst) begin
        if (rst) spr_start <= 1'b0; else spr_start <= line_change96 & ~boot_skip;
    end

    // line-buffer leído con hpos retrasada SPR_HDLY para alinear con el pal_index del tilemap (display @48)
    reg [9:0] hd [0:31];
    integer hh;
    always @(posedge clk) if (ce_pix) begin
        hd[0] <= hpos;
        for (hh=1; hh<32; hh=hh+1) hd[hh] <= hd[hh-1];
    end
    wire [9:0] hpos_lb = hd[SPR_HDLY-1];
    wire [16:0] lb_q;
    aligator_gae1_sprite u_spr (
        .clk(clk96), .ce(1'b1), .start(spr_start), .line(render_line),
        .vreg0(vreg0), .vreg1(vreg1), .busy(),
        .spr_a(spr_a), .spr_q(spr_q),
        .rom_a(rom_as), .d_p0(ds_p0), .d_p1(ds_p1), .d_p2(ds_p2), .d_p3(ds_p3), .gfx_ok(gfxs_ok),
        .lb_x(hpos_lb[8:0]), .lb_q(lb_q),
        .wbank(wbank), .rbank(rbank)
    );

    // ---- combinación sprite sobre tilemap (combinacional) -> índice base + variante ----
    wire        spr_v   = lb_q[16];
    wire [3:0]  spr_var = lb_q[15:12];
    wire [11:0] spr_idx = lb_q[11:0];
    wire [11:0] base_idx = (spr_v && spr_idx!=12'd0) ? spr_idx : pal_index;
    wire [3:0]  variant  = spr_v ? spr_var : 4'd0;

    // ---- paleta: pal_a = base_idx -> pal_q (lectura vmem registrada por CLK, NO por ce_pix:
    // catch-up dentro de la ventana de 6 clk -> mismo PÍXEL que base_idx). La variante va DIRECTA
    // (combinacional, mismo píxel) para alinear con pal_q; registrarla con ce_pix la atrasaría 1px
    // y aplicaría la sombra al color del píxel siguiente (bug cazado con el test de sombra spr3). ----
    assign pal_a = base_idx;
    wire [4:0] r5, g5, b5;
    aligator_gae1_palette u_pal (.pal_word(pal_q), .variant(variant), .r(r5), .g(g5), .b(b5));

    // ---- sync/blank/DE retrasados LAT (+DEADJ) para alinear con el RGB ----
    localparam integer SD = LAT + DEADJ;
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

    // negro fuera del área visible
    assign vga_r = de ? r5 : 5'd0;
    assign vga_g = de ? g5 : 5'd0;
    assign vga_b = de ? b5 : 5'd0;

`ifdef ALIGATOR_GFXTRACE
    integer dbgn=0;
    always @(posedge clk) if (ce_pix && gfx0_ok && rom_a0!=22'd0 && dbgn<10) begin
        $display("GFXTRACE rom_a0=%h gfx0_data=%h", rom_a0, gfx0_data);
        dbgn <= dbgn + 1;
    end
`endif
endmodule

`default_nettype wire
