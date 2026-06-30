// ============================================================================
//  Alligator Hunt (Gaelco, 1994, Tipo-2 gaelco2.cpp / chip GAE1) — jtaligator_game.v
//
//  jtcore (memgen, desde cfg/mem.yaml) AUTO-GENERA jtaligator_game_sdram.v (GAMETOP) que
//  instancia este modulo + slots SDRAM + dwnld + board/OSD/video-out de jtframe.
//
//  Buses SDRAM por NOMBRE: main_* (prog 68k DW16, 1MB), gfx0/gfx1/gfxs_* (gfx DW32, 16MB).
//  SIN OKI (el sonido lo hace el GAE1). DS5002: firmware -> BRAM runtime (fase posterior).
//
//  ESTADO: FASE "BUS gaelco2" — CPU + memoria (VRAM 64KB plana + paleta 8KB) + vregs + I/O +
//  RAM compartida DS5002, todo al mapa gaelco2. El MOTOR de vídeo GAE1 (2 tilemaps 5bpp +
//  linescroll + sprites + sombras) es la FASE GRANDE siguiente: aquí va un STUB que SOLO genera
//  el timing (vblank_irq -> el 68k corre su bucle por IRQ) y saca NEGRO. Objetivo de esta fase:
//  validar en sim que el 68k arranca y escribe VRAM/paleta con el bus nuevo. gfx*_cs=0 (sin pedir).
// ============================================================================
`default_nettype none

module jtaligator_game(
    `include "jtframe_game_ports.inc"
    // --- descarga (RUNTIME, desde la .mra) del SCRATCH del DS5002 (mismo download que el PROM) ---
    //  El wrapper generado las cablea a dallas_waddr/dallas_dd/dallas_we (parche patch_scratch_runtime.py).
    ,input  wire        scr_dl_clk
    ,input  wire [14:0] scr_dl_addr
    ,input  wire [ 7:0] scr_dl_data
    ,input  wire        scr_dl_we
);
    // ===================== RELOJES / CEN =====================
    // Logica del juego a clk48; SDRAM (slots) a clk=clk96 (JTFRAME_SDRAM96). Igual que WRally.
    wire clkg = clk48;

    // pxl_cen = clk48/6 = 8 MHz. pxl2_cen = clk48/3 = 16 MHz.
    reg [2:0] pxdiv = 3'd0;
    always @(posedge clkg) pxdiv <= (pxdiv==3'd5) ? 3'd0 : pxdiv + 3'd1;
    assign pxl_cen  = (pxdiv==3'd0);
    assign pxl2_cen = (pxdiv==3'd0) || (pxdiv==3'd3);
    wire ce_pix = (pxdiv==3'd0);

    // mcu_cen = clk48/4 = 12 MHz (cristal del DS5002; el wrapper lo divide /12 -> ~1 MIPS real)
    reg [1:0] mcudiv = 2'd0;
    always @(posedge clkg) mcudiv <= mcudiv + 2'd1;
    // PAUSA: dip_pause (jtframe, activo-bajo: 1=corre, 0=pausa) congela el DS5002 a la vez que el 68k
    // (game_run en u_main) -> el handshake de RAM compartida queda coherente. El vídeo (ce_pix) sigue.
    wire mcu_cen = (mcudiv==2'd0) & dip_pause;

    // ===================== ENTRADAS (gaelco2: IN0/IN1/COIN) =====================
    wire [15:0] in0, in1, in_coin;
    aligator_inputs u_inputs (
        .dipsw(dipsw[15:0]),
        .joystick1(joystick1[6:0]), .joystick2(joystick2[6:0]),
        .coin(coin[1:0]),         // jtframe activo-bajo -> DIRECTO
        .start(cab_1p[1:0]),      // start (cabina) jtframe activo-bajo -> DIRECTO
        .service(service),        // boton de servicio activo-bajo -> DIRECTO
        .port_in0(in0), .port_in1(in1), .port_coin(in_coin)
    );

    // ===================== CPU + memoria (aligator_main) =====================
    wire        flip_screen;
    wire [15:0] vmem_addr; wire vmem_uds, vmem_lds, vmem_we;
    wire        vmem_cs_vram, vmem_cs_pal;
    wire [15:0] vmem_wdata;
    wire [15:0] cpu_vram_rd, cpu_pal_rd;
    wire [15:0] vreg0, vreg1, vreg2;
    wire [19:1] rom68k_addr;
    wire        sndreg_cs, sndreg_we; wire [15:0] snd_rdata;
    wire signed [15:0] snd_l, snd_r; wire snd_sample_w;

    // REPLAY de escena (ALIGATOR_SCENE): CPU en reset, vregs de la escena precargada -> render sin bootear.
`ifdef ALIGATOR_SCENE
    wire cpu_rst = 1'b1;
    reg [15:0] scene_vreg [0:7];
    initial $readmemh("scene_vregs.hex", scene_vreg);
    wire [15:0] vv0 = scene_vreg[2], vv1 = scene_vreg[3], vv2 = scene_vreg[4];
`else
    wire cpu_rst = rst;
    wire [15:0] vv0 = vreg0, vv1 = vreg1, vv2 = vreg2;
`endif

    aligator_main u_main (
        .clk(clkg), .rst(cpu_rst), .game_run(dip_pause),
        .vblank_irq(vblank_irq),
        .prog_addr(rom68k_addr), .prog_cs(main_cs), .prog_data(main_data), .prog_data_ok(main_ok),
        .in0(in0), .in1(in1), .in_coin(in_coin),
        .flip_screen(flip_screen),
        .vmem_addr(vmem_addr), .vmem_uds(vmem_uds), .vmem_lds(vmem_lds), .vmem_we(vmem_we),
        .vmem_cs_vram(vmem_cs_vram), .vmem_cs_pal(vmem_cs_pal),
        .vmem_wdata(vmem_wdata),
        .vmem_vram_rdata(cpu_vram_rd), .vmem_pal_rdata(cpu_pal_rd),
        .vreg0(vreg0), .vreg1(vreg1), .vreg2(vreg2),
        .sndreg_cs(sndreg_cs), .sndreg_we(sndreg_we), .snd_rdata(snd_rdata),
        .mcu_cen(mcu_cen), .mcurom_addr(dallas_addr), .mcurom_en(), .mcurom_data(dallas_data),
        // descarga del SCRATCH del DS5002 en runtime (mismo download que el PROM del firmware)
        .scr_dl_clk(scr_dl_clk), .scr_dl_addr(scr_dl_addr), .scr_dl_data(scr_dl_data), .scr_dl_we(scr_dl_we)
    );
    assign main_addr = rom68k_addr;

    // ===================== SONIDO GAE1 (7 canales estéreo, samples en las ROMs de gfx) =====================
    wire [21:0] rom_asnd;
    aligator_gae1_sound u_snd (
        .clk(clkg), .rst(rst),
        .cs_sound(sndreg_cs), .cpu_aw(vmem_addr[7:1]), .cpu_we(sndreg_we),
        .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_wdata(vmem_wdata), .cpu_rdata(snd_rdata),
        .rom_addr(rom_asnd), .rom_cs(snd_cs), .rom_data(snd_data), .rom_ok(snd_ok),
        .snd_l(snd_l), .snd_r(snd_r), .sample(snd_sample_w)
    );
    assign snd_addr = rom_asnd;

    // ===================== memorias de video (aligator_vmem: VRAM 64KB + paleta 8KB) =====================
    wire [13:0] tp0_idx, tp1_idx; wire [31:0] tp0_q, tp1_q;
    wire [14:0] wrd_a;  wire [15:0] wrd_q;
    wire [14:0] spr_a;  wire [15:0] spr_q;
    wire [11:0] pal_a;  wire [15:0] pal_q;
    aligator_vmem u_vmem (
        .clk(clkg), .clk96(clk96),     // lectura del motor de sprites @96 (fix overrun)
        .cpu_addr(vmem_addr), .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_we(vmem_we),
        .cs_vram(vmem_cs_vram), .cs_pal(vmem_cs_pal),
        .cpu_wdata(vmem_wdata),
        .cpu_vram_rdata(cpu_vram_rd), .cpu_pal_rdata(cpu_pal_rd),
        .tp0_idx(tp0_idx), .tp0_q(tp0_q), .tp1_idx(tp1_idx), .tp1_q(tp1_q),
        .wrd_a(wrd_a), .wrd_q(wrd_q), .spr_a(spr_a), .spr_q(spr_q),
        .pal_a(pal_a), .pal_q(pal_q)
    );

    // ===================== VIDEO (motor GAE1, STEP A = tilemaps) =====================
    wire vblank_irq;
    wire hs_w, vs_w, hb_w, vb_w, de_w;
    wire [21:0] rom_a0, rom_a1, rom_as;
    wire [4:0] r5, g5, b5;
    aligator_video_top u_video (
        .clk(clkg), .clk96(clk96), .rst(rst), .ce_pix(ce_pix),
        .vreg0(vv0), .vreg1(vv1), .vreg2(vv2),
        .tp0_idx(tp0_idx), .tp0_q(tp0_q), .tp1_idx(tp1_idx), .tp1_q(tp1_q),
        .wrd_a(wrd_a), .wrd_q(wrd_q), .spr_a(spr_a), .spr_q(spr_q), .pal_a(pal_a), .pal_q(pal_q),
        .rom_a0(rom_a0), .gfx0_data(gfx0_data), .gfx0_ok(gfx0_ok),
        .rom_a1(rom_a1), .gfx1_data(gfx1_data), .gfx1_ok(gfx1_ok),
        .rom_as(rom_as), .gfxs_data(gfxs_data), .gfxs_ok(gfxs_ok),
        .vga_r(r5), .vga_g(g5), .vga_b(b5),
        .hsync(hs_w), .vsync(vs_w), .hblank(hb_w), .vblank(vb_w), .de(de_w),
        .vblank_irq(vblank_irq)
    );

    // gfx tilemap SDRAM (DW32, 4 planos). gfxs (sprites) tied-off hasta la fase de sprites.
    assign gfx0_addr = rom_a0; assign gfx0_cs = 1'b1;
    assign gfx1_addr = rom_a1;
`ifdef ALIGATOR_L0ONLY
    assign gfx1_cs = 1'b0;     // DIAG: sin contienda SDRAM de la 2ª capa
`else
    assign gfx1_cs = 1'b1;
`endif
    assign gfxs_addr = rom_as; assign gfxs_cs = 1'b1;

    assign red   = r5;
    assign green = g5;
    assign blue  = b5;
    assign HS    = hs_w;
    assign VS    = vs_w;
    assign LHBL  = ~hb_w;
    assign LVBL  = ~vb_w;

    // ===================== AUDIO (GAE1 STUB) =====================
    assign snd_left  = snd_l;       // GAE1 estéreo (JTFRAME_STEREO)
    assign snd_right = snd_r;
    assign sample    = snd_sample_w;

    // ===================== sin usar de momento =====================
    assign debug_view = 8'd0;
    assign dip_flip   = 1'b0;

    // ===================== TRAZA DE SIM =====================
`ifdef SIMULATION
    integer wr_vram=0, wr_pal=0, n_progrd=0;
    reg [19:1] pcmax=0; reg [19:0] hb=0;
    always @(posedge clkg) begin
        if (main_cs && main_ok) begin n_progrd<=n_progrd+1; if (rom68k_addr>pcmax) pcmax<=rom68k_addr; end
        if (vmem_we && vmem_cs_vram) wr_vram<=wr_vram+1;
        if (vmem_we && vmem_cs_pal ) wr_pal <=wr_pal +1;
        hb<=hb+1'b1;
        if (hb==20'd0) $display("HB pc=%h PCmax=%h progrd=%0d vram=%0d pal=%0d vregs=%h,%h,%h",
                                {rom68k_addr,1'b0}, {pcmax,1'b0}, n_progrd, wr_vram, wr_pal,
                                vreg0, vreg1, vreg2);
    end
`endif

endmodule

`default_nettype wire
