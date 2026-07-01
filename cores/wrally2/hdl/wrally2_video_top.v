// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 / chip GAE1) — TOP de vídeo: timing + compositor + sprites + paleta.
//
//  Une wrally2_video_timing + wrally2_gae1_video (2 tilemaps 5bpp, prioridad fija) +
//  wrally2_gae1_sprite (motor de sprites por línea, doble line-buffer, sombras RMW) +
//  wrally2_gae1_palette (RGB555 + shadow/highlight) -> RGB 5-5-5 + sync/blank/DE + vblank_irq.
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

module wrally2_video_top #(
    parameter integer LAT      = 14,  // latencia hpos->RGB (ce_pix)
    parameter integer DEADJ    = 0,   // ajuste fino de fase sync/DE vs RGB
    parameter integer SPR_HDLY = 15   // hpos->pal_index (alinea el line-buffer de sprites; CALIBRADO vs golden: SAD 1.9/px)
)(
    input  wire        clk,
    input  wire        clk96,      // motor de SPRITES (fix overrun: render a 96, doble presupuesto/línea)
    input  wire        rst,
    input  wire        ce_pix,
    input  wire        index,      // single: pantalla a mostrar 0=izquierda (tm0), 1=derecha (tm1)
    input  wire        twin,       // 1=TWIN: 768px izda(tm0)|dcha(tm1) + sprites de ambos monitores

    input  wire [15:0] vreg0, vreg1, vreg2,

    // VRAM (de wrally2_vmem): par de tile L0/L1 + word genérico (scroll) + word sprites + paleta
    output wire [13:0] tp0_idx, input wire [31:0] tp0_q,
    output wire [13:0] tp1_idx, input wire [31:0] tp1_q,
    output wire [14:0] wrd_a,   input wire [15:0] wrd_q,
    output wire [14:0] spr_a,   input wire [15:0] spr_q,
    output wire [14:0] spr2_a,  input wire [15:0] spr2_q,   // 2º motor de sprites (TWIN, derecho)
    output wire [11:0] pal_a,   input wire [15:0] pal_q,
    // gfx (SDRAM, DW32 4 planos): 2 tilemaps + 2 motores de sprites (gfxs izdo / gfxs2 derecho-twin)
    output wire [21:0] rom_a0,  input wire [31:0] gfx0_data, input wire gfx0_ok,
    output wire [21:0] rom_a1,  input wire [31:0] gfx1_data, input wire gfx1_ok,
    output wire [21:0] rom_as,  input wire [31:0] gfxs_data, input wire gfxs_ok,
    output wire [21:0] rom_as2, input wire [31:0] gfxs2_data, input wire gfxs2_ok,

    // salida de vídeo (interfaz jtframe, COLORW=5)
    output wire [4:0]  vga_r, vga_g, vga_b,
    output wire        hsync, vsync, hblank, vblank, de,
    output wire        vblank_irq
);
    // ---- timing ----
    wire [9:0] hpos; wire [8:0] vpos; wire frame_end;
    wire hs_i, vs_i, hb_i, vb_i, de_i;
    wrally2_video_timing u_timing (
        .clk(clk), .rst(rst), .ce_pix(ce_pix), .twin(twin),
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
    wire [7:0] ds2_p0=gfxs2_data[15:8], ds2_p1=gfxs2_data[7:0], ds2_p2=gfxs2_data[31:24], ds2_p3=gfxs2_data[23:16];

    // ---- compositor de tilemaps -> índice base de paleta ----
    wire [11:0] pal_index; wire opaque;
    wrally2_gae1_video u_video (
        .clk(clk), .ce(ce_pix), .hpos(hpos), .vpos(vpos), .frame_end(frame_end),
        .index(index), .twin(twin),
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
`ifdef WRALLY2_SCENE
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

    // ---- DOS MOTORES DE SPRITES (uno por monitor, a presupuesto completo c/u = fiel a las 2 PCBs) ----
    // u_spr_l: subset IZDO (bit15==0), slot gfxs + lista spr. u_spr_r: subset DCHO (bit15==1), slot gfxs2 +
    // lista spr2. Cada motor corre en modo PER-MONITOR (twin=0 interno) -> sólo dibuja SU subset (early-out
    // descarta el otro) -> mitad de celdas/línea -> NO hay overrun (validado: single 0 cortes). Su line-buffer
    // local 0..383 reproduce EXACTAMENTE la semántica del antiguo motor único twin (lb 0..383 izda / 384..767
    // dcha) al leerse derecho con hpos_lb-384. GATING por modo: en single-left sólo arranca/pide u_spr_l (sin
    // carga SDRAM/VRAM extra -> 0 regresión); en single-right sólo u_spr_r; en twin AMBOS en paralelo.
    wire start_l = line_change96 & ~boot_skip & (twin | ~index);   // activo en twin + single-left
    wire start_r = line_change96 & ~boot_skip & (twin |  index);   // activo en twin + single-right
    reg spr_start_l, spr_start_r;
    always @(posedge clk96 or posedge rst) begin
        if (rst) begin spr_start_l <= 1'b0; spr_start_r <= 1'b0; end
        else     begin spr_start_l <= start_l; spr_start_r <= start_r; end
    end

    // line-buffer leído con hpos retrasada SPR_HDLY para alinear con el pal_index del tilemap (display @48)
    reg [9:0] hd [0:31];
    integer hh;
    always @(posedge clk) if (ce_pix) begin
        hd[0] <= hpos;
        for (hh=1; hh<32; hh=hh+1) hd[hh] <= hd[hh-1];
    end
    wire [9:0] hpos_lb = hd[SPR_HDLY-1];

    // direcciones de lectura del line-buffer por motor:
    //   izdo: hpos_lb (0..383). dcho: twin -> hpos_lb-384 (mitad dcha); single-right -> hpos_lb (0..383).
    wire [9:0] lb_x_l = hpos_lb;
    wire [9:0] lb_x_r = twin ? (hpos_lb - 10'd384) : hpos_lb;
    wire [16:0] lb_q_l, lb_q_r, lb_q;
`ifndef WRALLY2_DUAL_SPR
    // ===== MODO POR DEFECTO (shippable HW): UN solo motor de sprites (index/twin internos = diseño original
    // validado 0.00%). single/left/right PERFECTOS; twin con OVERRUN en líneas muy densas (límite de presupuesto
    // de 1 motor; en parte fiel al límite real de sprites/línea del GAE1). RAZÓN: el DOBLE motor (twin fiel) NO
    // CABE en la FPGA (Cyclone V): dual=195%, dual-shrink~108%; el motor único cabe (~95%). El doble motor queda
    // tras `WRALLY2_DUAL_SPR` (sim / FPGA futura más grande). LBDEPTH=1024: el motor único hace twin interno
    // (escribe 0..767) -> necesita 1024. Tie del 2º slot (gfxs2/spr2). =====
    wrally2_gae1_sprite #(.LBDEPTH(1024)) u_spr_l (
        .clk(clk96), .ce(1'b1), .start(spr_start_l | spr_start_r), .line(render_line),
        .index(index), .twin(twin),
        .vreg0(vreg0), .vreg1(vreg1), .busy(),
        .spr_a(spr_a), .spr_q(spr_q),
        .rom_a(rom_as), .d_p0(ds_p0), .d_p1(ds_p1), .d_p2(ds_p2), .d_p3(ds_p3), .gfx_ok(gfxs_ok),
        .lb_x(hpos_lb), .lb_q(lb_q_l),
        .wbank(wbank), .rbank(rbank)
    );
    assign lb_q_r  = 17'd0;
    assign rom_as2 = 22'd0;
    assign spr2_a  = 15'd0;
    assign lb_q    = lb_q_l;
`else
    // ===== DOBLE MOTOR (twin FIEL, sin overrun) — bajo `WRALLY2_DUAL_SPR`. NO CABE en la FPGA actual (~108-195%);
    // validado 0.00% en sim (4 modos). Para FPGA futura más grande o si se optimiza más el área. =====
    wrally2_gae1_sprite u_spr_l (
        .clk(clk96), .ce(1'b1), .start(spr_start_l), .line(render_line),
        .index(1'b0), .twin(1'b0),
        .vreg0(vreg0), .vreg1(vreg1), .busy(),
        .spr_a(spr_a), .spr_q(spr_q),
        .rom_a(rom_as), .d_p0(ds_p0), .d_p1(ds_p1), .d_p2(ds_p2), .d_p3(ds_p3), .gfx_ok(gfxs_ok),
        .lb_x(lb_x_l), .lb_q(lb_q_l),
        .wbank(wbank), .rbank(rbank)
    );
    wrally2_gae1_sprite u_spr_r (
        .clk(clk96), .ce(1'b1), .start(spr_start_r), .line(render_line),
        .index(1'b1), .twin(1'b0),
        .vreg0(vreg0), .vreg1(vreg1), .busy(),
        .spr_a(spr2_a), .spr_q(spr2_q),
        .rom_a(rom_as2), .d_p0(ds2_p0), .d_p1(ds2_p1), .d_p2(ds2_p2), .d_p3(ds2_p3), .gfx_ok(gfxs2_ok),
        .lb_x(lb_x_r), .lb_q(lb_q_r),
        .wbank(wbank), .rbank(rbank)
    );
    // selección del motor que alimenta este píxel: twin -> por posición (hpos_lb>=384 = monitor dcho);
    // single -> el motor de la pantalla elegida (index). Reproduce el lb único del motor twin previo.
    wire        rsel = twin ? (hpos_lb >= 10'd384) : index;
    assign lb_q = rsel ? lb_q_r : lb_q_l;
`endif

    // ---- combinación sprite sobre tilemap (combinacional) -> índice base + variante ----
    wire        spr_v   = lb_q[16];
    wire [3:0]  spr_var = lb_q[15:12];
    wire [11:0] spr_idx = lb_q[11:0];
    wire [11:0] base_idx = (spr_v && spr_idx!=12'd0) ? spr_idx : pal_index;
    wire [3:0]  variant  = spr_v ? spr_var : 4'd0;

`ifdef WRALLY2_DBGBAND
    // diag: dispara EN el pixel magenta (rgb=31,0,31) en la mitad izquierda (hpos<384) -> ¿dónde y qué?
    integer nmag=0;
    always @(posedge clk) if (ce_pix && r5==5'd31 && g5==5'd0 && b5==5'd31 && hpos<10'd384 && nmag<20) begin
        nmag <= nmag+1;
        $display("MAG vpos=%0d hpos=%0d spr_v=%b base=%h pal_q=%h", vpos, hpos, spr_v, base_idx, pal_q);
    end
`endif

    // ---- paleta: pal_a = base_idx -> pal_q (lectura vmem registrada por CLK, NO por ce_pix:
    // catch-up dentro de la ventana de 6 clk -> mismo PÍXEL que base_idx). La variante va DIRECTA
    // (combinacional, mismo píxel) para alinear con pal_q; registrarla con ce_pix la atrasaría 1px
    // y aplicaría la sombra al color del píxel siguiente (bug cazado con el test de sombra spr3). ----
    assign pal_a = base_idx;
    wire [4:0] r5, g5, b5;
    wrally2_gae1_palette u_pal (.pal_word(pal_q), .variant(variant), .r(r5), .g(g5), .b(b5));

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

`ifdef WRALLY2_GFXTRACE
    integer dbgn=0;
    always @(posedge clk) if (ce_pix && gfx0_ok && rom_a0!=22'd0 && dbgn<10) begin
        $display("GFXTRACE rom_a0=%h gfx0_data=%h", rom_a0, gfx0_data);
        dbgn <= dbgn + 1;
    end
`endif
endmodule

`default_nettype wire
