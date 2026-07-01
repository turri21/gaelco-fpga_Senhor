// ============================================================================
//  Alligator Hunt (Gaelco, 1994, Tipo-2 gaelco2.cpp / chip GAE1) — jtwrally2_game.v
//
//  jtcore (memgen, desde cfg/mem.yaml) AUTO-GENERA jtwrally2_game_sdram.v (GAMETOP) que
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

module jtwrally2_game(
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

    // ===================== MODO DUAL-MONITOR (OSD "Monitor": status[14:13]) =====================
    // 0=Left(single izda) 1=Right(single dcha) 2=Twin(768). disp_index=status[13], disp_twin=status[14].
    // Sim: macros WRALLY2_TWIN / WRALLY2_RIGHT fuerzan el modo (el harness no driverea status).
`ifdef WRALLY2_TWIN
    wire disp_twin = 1'b1;  wire disp_index = 1'b0;
`elsif WRALLY2_RIGHT
    wire disp_twin = 1'b0;  wire disp_index = 1'b1;
`else
    wire disp_twin  = status[14];
    wire disp_index = status[13];
`endif

    // pxl_cen: SINGLE = clk48/6 = 8 MHz (384px). TWIN = clk48/3 = 16 MHz (768px) -> mantiene vblank ~60Hz
    // (HTOTAL 512->1024). El cambio de modo reinicia el contador (glitch breve OK).
    reg [2:0] pxdiv = 3'd0;
    wire [2:0] pxmax = disp_twin ? 3'd2 : 3'd5;        // /3=16MHz (twin) : /6=8MHz (single)
    always @(posedge clkg) pxdiv <= (pxdiv>=pxmax) ? 3'd0 : pxdiv + 3'd1;
    assign pxl_cen  = (pxdiv==3'd0);
    // pxl2_cen: la cadena de vídeo de MiSTer deriva pxl1_cen = pxl2_cen & ~pxl_cen y lo usa para CLOCKEAR
    // jtframe_resync (el regenerador de sync). FIX TWIN (root cause 2026-06-30): antes en twin pxl2_cen=pxl_cen
    // (pxdiv==0) -> pxl1_cen = pxl_cen & ~pxl_cen = 0 SIEMPRE -> el resync NO avanza -> sync muerto -> el
    // escalador rechaza el modo twin (0x0 / "último válido"). Solución: en twin pxl2_cen en OTRA fase (pxdiv==1)
    // -> pxl1_cen = (pxdiv==1) = 16MHz (un tick por píxel) -> el resync late y regenera sync válido. (No es un
    // 2x real -no posible desde clk48 a 32MHz- pero el resync sólo necesita UN tick/píxel; los FX 2x van off en
    // twin y el scandoubler de arcade_video genera su propio 2x desde ce_pix.) SINGLE intacto (rama de la dcha).
    assign pxl2_cen = disp_twin ? (pxdiv==3'd1) : ((pxdiv==3'd0) || (pxdiv==3'd3));
    wire ce_pix = (pxdiv==3'd0);

    // mcu_cen = DS5002 @ 13 MHz (XTAL 26MHz/2, gaelco2.cpp:2892) = cen fraccional 13/48 (acumulador).
    // OBLIGATORIO 13/13 (68k+MCU): el boot del handshake es CYCLE-SENSITIVE -> a 12/12 (o 12/13) DEADLOCKA en
    // sim (KEY=0); sólo 13/13 completa (KEY=10, MCU pc->0x618). El jitter del cen fraccional evita una carrera.
    // El cen tiene gaps de 3-4 clk48 (mínimo 3) -> el SDC del mc8051 DEBE usar multicycle-3 (no 4), si no las
    // rutas violan en HW ("Coprocessor Not Ready"). Ver wrally2_clk48_96.sdc.
    // ===================== mcu_cen: REGULAR clk48/4 = 12 MHz (FIX HW 2026-06-30) =====================
    //  CAMBIO CLAVE: el cen del DS5002 era FRACCIONAL 13/48 (13 MHz exacto, XTAL real 26/2) pero con gaps
    //  IRREGULARES (3-4 clk48). En HW el MCU NO ejecutaba el firmware (scratch writes=0, V005 en .123) pese
    //  a funcionar en sim. La UNICA diferencia con aligator (que SI arranca el DS5002 en HW) era ese cen
    //  irregular. El cen REGULAR clk48/4 (= aligator) COMPLETA el handshake en sim (mcuW=4004, scratch=36,
    //  igual que el fraccional, sin regresion) y hace el MCU identico al de aligator. Precio: ~8% lento
    //  (12 vs 13 MHz, como aligator). El fraccional queda tras WR2_CEN_FRAC para referencia/futuro.
`ifdef WR2_CEN_FRAC
    reg [5:0] mcuacc = 6'd0;
    reg       mcu_cen_r = 1'b0;
    always @(posedge clkg) begin
        if (mcuacc >= 6'd35) begin mcuacc <= mcuacc + 6'd13 - 6'd48; mcu_cen_r <= 1'b1; end  // 35 = 48-13
        else                 begin mcuacc <= mcuacc + 6'd13;        mcu_cen_r <= 1'b0; end
    end
    wire mcu_cen = mcu_cen_r & dip_pause;
`else
    reg [1:0] mcudiv = 2'd0;
    always @(posedge clkg) mcudiv <= mcudiv + 2'd1;
    // PAUSA: dip_pause (jtframe, activo-bajo: 1=corre, 0=pausa) congela el DS5002 a la vez que el 68k.
    wire mcu_cen = (mcudiv==2'd0) & dip_pause;
`endif

    // ===================== ENTRADAS (gaelco2 wrally2: IN0=P1+DSW2 / IN1=DSW1 / IN2=P2+COIN / IN3=SERVICE) =====================
    wire [15:0] in0, in1, in2, in3;
    wrally2_inputs u_inputs (
        .clk(clkg),               // para el toggle de la marcha
        .dipsw(dipsw[15:0]),
        .joystick1(joystick1[5:0]), .joystick2(joystick2[5:0]),
        .coin(coin[1:0]),         // jtframe activo-bajo -> DIRECTO
        .start(cab_1p[1:0]),      // start (cabina) jtframe activo-bajo -> DIRECTO
        .service(service),        // SERVICE1 activo-bajo -> DIRECTO
        .test(dip_test),          // SERVICE3 = test mode (activo-bajo)
        .port_in0(in0), .port_in1(in1), .port_in2(in2), .port_in3(in3)
    );

    // ===================== CPU + memoria (wrally2_main) =====================
    wire        flip_screen;
    wire [15:0] vmem_addr; wire vmem_uds, vmem_lds, vmem_we;
    wire        vmem_cs_vram, vmem_cs_pal;
    wire [15:0] vmem_wdata;
    wire [15:0] cpu_vram_rd, cpu_pal_rd;
    wire [15:0] vreg0, vreg1, vreg2;
    wire [19:1] rom68k_addr;
    wire        sndreg_cs, sndreg_we; wire [15:0] snd_rdata;
    // TELEMETRIA DS5002 (HW): salidas dbg_* de wrally2_main (counters del handshake)
    wire [15:0] dbg_mcu_pcmax, dbg_mcu_fetch, dbg_mcuw, dbg_mcu_scrw;
    wire [ 7:0] dbg_key;
    wire signed [15:0] snd_l, snd_r; wire snd_sample_w;

    // REPLAY de escena (WRALLY2_SCENE): CPU en reset, vregs de la escena precargada -> render sin bootear.
`ifdef WRALLY2_SCENE
    wire cpu_rst = 1'b1;
    reg [15:0] scene_vreg [0:7];
    initial $readmemh("scene_vregs.hex", scene_vreg);
    wire [15:0] vv0 = scene_vreg[2], vv1 = scene_vreg[3], vv2 = scene_vreg[4];
`else
    wire cpu_rst = rst;
    wire [15:0] vv0 = vreg0, vv1 = vreg1, vv2 = vreg2;
`endif

    wrally2_main u_main (
        .clk(clkg), .rst(cpu_rst), .game_run(dip_pause),
        .vblank_irq(vblank_irq),
        .prog_addr(rom68k_addr), .prog_cs(main_cs), .prog_data(main_data), .prog_data_ok(main_ok),
        .in0(in0), .in1(in1), .in2(in2), .in3(in3),
        // volantes ADC: eje X del stick analógico (joyana_l1/l2, byte bajo), signed->offset-binary
        // (centro 0x80, como el default 0x8A de MAME). paddle_* NO sirve: el wrapper memgen NO lo conecta
        // y jtframe_game_instance.v tiene el bug paddle_1..4 (falta paddle_0). joyana_* SÍ se conecta.
        // CALIBRACIÓN HW pendiente: si el volante responde al eje equivocado -> usar [15:8]; REVERSE -> invertir.
        .paddle0({~joyana_l1[7], joyana_l1[6:0]}),
        .paddle1({~joyana_l2[7], joyana_l2[6:0]}),
        .flip_screen(flip_screen),
        .vmem_addr(vmem_addr), .vmem_uds(vmem_uds), .vmem_lds(vmem_lds), .vmem_we(vmem_we),
        .vmem_cs_vram(vmem_cs_vram), .vmem_cs_pal(vmem_cs_pal),
        .vmem_wdata(vmem_wdata),
        .vmem_vram_rdata(cpu_vram_rd), .vmem_pal_rdata(cpu_pal_rd),
        .vreg0(vreg0), .vreg1(vreg1), .vreg2(vreg2),
        .sndreg_cs(sndreg_cs), .sndreg_we(sndreg_we), .snd_rdata(snd_rdata),
        .mcu_cen(mcu_cen), .mcurom_addr(dallas_addr), .mcurom_en(), .mcurom_data(dallas_data),
        // TELEMETRIA DS5002 (HW): counters/valores del handshake (ver bloque UART abajo)
        .dbg_mcu_pcmax(dbg_mcu_pcmax), .dbg_mcu_fetch(dbg_mcu_fetch),
        .dbg_mcuw(dbg_mcuw), .dbg_mcu_scrw(dbg_mcu_scrw), .dbg_key(dbg_key),
        // carga del scratch del DS5002 en runtime (desde la .mra, mismo download que el PROM)
        .scr_dl_clk(scr_dl_clk), .scr_dl_addr(scr_dl_addr), .scr_dl_data(scr_dl_data), .scr_dl_we(scr_dl_we)
    );
    assign main_addr = rom68k_addr;

    // ===================== SONIDO GAE1 (7 canales estéreo, samples en las ROMs de gfx) =====================
    wire [21:0] rom_asnd;
    wrally2_gae1_sound u_snd (
        .clk(clkg), .rst(rst),
        .cs_sound(sndreg_cs), .cpu_aw(vmem_addr[7:1]), .cpu_we(sndreg_we),
        .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_wdata(vmem_wdata), .cpu_rdata(snd_rdata),
        .rom_addr(rom_asnd), .rom_cs(snd_cs), .rom_data(snd_data), .rom_ok(snd_ok),
        .snd_l(snd_l), .snd_r(snd_r), .sample(snd_sample_w)
    );
    assign snd_addr = rom_asnd;

    // ===================== memorias de video (wrally2_vmem: VRAM 64KB + paleta 8KB) =====================
    wire [13:0] tp0_idx, tp1_idx; wire [31:0] tp0_q, tp1_q;
    wire [14:0] wrd_a;  wire [15:0] wrd_q;
    wire [14:0] spr_a;  wire [15:0] spr_q;
    wire [14:0] spr2_a; wire [15:0] spr2_q;   // 2º motor de sprites (twin)
    wire [11:0] pal_a;  wire [15:0] pal_q;
    wrally2_vmem u_vmem (
        .clk(clkg), .clk96(clk96),     // lectura del motor de sprites @96 (fix overrun)
        .cpu_addr(vmem_addr), .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_we(vmem_we),
        .cs_vram(vmem_cs_vram), .cs_pal(vmem_cs_pal),
        .cpu_wdata(vmem_wdata),
        .cpu_vram_rdata(cpu_vram_rd), .cpu_pal_rdata(cpu_pal_rd),
        .tp0_idx(tp0_idx), .tp0_q(tp0_q), .tp1_idx(tp1_idx), .tp1_q(tp1_q),
        .wrd_a(wrd_a), .wrd_q(wrd_q), .spr_a(spr_a), .spr_q(spr_q),
        .spr2_a(spr2_a), .spr2_q(spr2_q),
        .pal_a(pal_a), .pal_q(pal_q)
    );

    // ===================== VIDEO (motor GAE1, STEP A = tilemaps) =====================
    wire vblank_irq;
    wire hs_w, vs_w, hb_w, vb_w, de_w;
    wire [21:0] rom_a0, rom_a1, rom_as, rom_as2;
    wire [4:0] r5, g5, b5;
    // disp_index/disp_twin definidos arriba (OSD status[14:13] / macros de sim).
    wrally2_video_top u_video (
        .clk(clkg), .clk96(clk96), .rst(rst), .ce_pix(ce_pix),
        .index(disp_index), .twin(disp_twin),
        .vreg0(vv0), .vreg1(vv1), .vreg2(vv2),
        .tp0_idx(tp0_idx), .tp0_q(tp0_q), .tp1_idx(tp1_idx), .tp1_q(tp1_q),
        .wrd_a(wrd_a), .wrd_q(wrd_q), .spr_a(spr_a), .spr_q(spr_q),
        .spr2_a(spr2_a), .spr2_q(spr2_q), .pal_a(pal_a), .pal_q(pal_q),
        .rom_a0(rom_a0), .gfx0_data(gfx0_data), .gfx0_ok(gfx0_ok),
        .rom_a1(rom_a1), .gfx1_data(gfx1_data), .gfx1_ok(gfx1_ok),
        .rom_as(rom_as), .gfxs_data(gfxs_data), .gfxs_ok(gfxs_ok),
        .rom_as2(rom_as2), .gfxs2_data(gfxs2_data), .gfxs2_ok(gfxs2_ok),
        .vga_r(r5), .vga_g(g5), .vga_b(b5),
        .hsync(hs_w), .vsync(vs_w), .hblank(hb_w), .vblank(vb_w), .de(de_w),
        .vblank_irq(vblank_irq)
    );

    // gfx tilemap SDRAM (DW32, 4 planos). gfxs (sprites) tied-off hasta la fase de sprites.
    assign gfx0_addr = rom_a0; assign gfx0_cs = 1'b1;
    assign gfx1_addr = rom_a1;
`ifdef WRALLY2_L0ONLY
    assign gfx1_cs = 1'b0;     // DIAG: sin contienda SDRAM de la 2ª capa
`else
    assign gfx1_cs = 1'b1;
`endif
    assign gfxs_addr = rom_as; assign gfxs_cs = 1'b1;
    // 2º motor de sprites (twin/single-right). cs GATEADO: en single-left (twin=0,index=0) NO pide
    // -> 0 carga SDRAM extra -> sin regresión del modo single-left validado.
    assign gfxs2_addr = rom_as2; assign gfxs2_cs = disp_twin | disp_index;

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

    // ===================== TELEMETRIA UART DS5002 (HW, sintetizable) =====================
    //  Diagnostico EN PLACA del "Coprocessor Not Ready": el handshake DS5002 va bien en SIM (KEY
    //  fefc04=0xffff @0x2f9e, MCU pc->0x618) pero falla en HW. Esta telemetria saca por uart_tx
    //  (game UART -> USER_IO -> /dev/ttyS1 con UART activo en el OSD) un paquete de 16 bytes 8N1
    //  9600 baud, repetido. Parser host: mister/parse_uart_dbg.py. Responde:
    //    ¿corre el MCU?  -> dbg_mcu_fetch sube (fetch de ROM) y dbg_mcu_pcmax avanza.
    //    ¿llega a 0x618 o se atasca? -> dbg_mcu_pcmax (0x0618=OK ; ~0x0235=bucle del handshake).
    //    ¿el 68k escribe la LLAVE? -> dbg_key>0 (68k escribio fefc04).
    //    ¿el MCU responde? -> dbg_mcuw>0 (MCU escribe la shram).
    //    + dbg_68k_pcmax: ¿el 68k progresa hasta 0x2f9e (codigo de la KEY)? (byte addr).
`ifdef JTFRAME_GAME_UART
    localparam [23:0] U_SAT24 = 24'hFFFFFF;
    // dbg_68k_pcmax: max de rom68k_addr (PC del 68k); rom68k_addr es WORD addr [19:1] -> a BYTE addr.
    reg [19:1] tl_pamax = 19'd0;
    always @(posedge clkg) begin
        if (rst)                        tl_pamax <= 19'd0;
        else if (rom68k_addr > tl_pamax) tl_pamax <= rom68k_addr;
    end
    wire [23:0] dbg_68k_pcmax = {4'd0, tl_pamax, 1'b0};   // byte addr (A0=0)

    // Paquete de 16 bytes (sync 0x55,0xAA + payload LE + terminador 0x0A). Una sola pagina (no rota).
    //   [0]=55 [1]=AA  [2:3]=mcu_pcmax(LE)  [4:5]=mcu_fetch(LE)  [6:7]=mcuw(LE)  [8]=key
    //   [9:11]=68k_pcmax(byteaddr,LE)  [12:13]=mcu_scrw(LE)  [14]=pad(0)  [15]=0A
    wire tl_pkt_start;
    wire [8*16-1:0] tl_data = {
        8'h0A,                  // [15] terminador
        8'd0,                   // [14] pad
        dbg_mcu_scrw,           // [12:13] MCU scratch-write count (LE) = corre firmware REAL
        dbg_68k_pcmax,          // [9:11] 68k PC max (byte addr, LE)
        dbg_key,                // [8]    KEY count (68k escribe fefc04)
        dbg_mcuw,               // [6:7]  MCU shram-write count (LE)
        dbg_mcu_fetch,          // [4:5]  MCU fetch count (LE)
        dbg_mcu_pcmax,          // [2:3]  MCU PC max (LE)
        8'hAA, 8'h55 };         // [1] [0] sync
    localparam integer UART_NB = 16;
    wrally2_dbg_uart #(.NB(UART_NB), .DIV(5000)) u_dbg_uart (   // clkg=clk48 / 9600 = 5000
        .clk(clkg), .rst(rst), .data(tl_data), .pkt_start(tl_pkt_start), .txd(uart_tx)
    );
`ifdef SIMULATION
    // VOLCADO del paquete en sim (valida la cadena empaquetado->parser SIN build). Formato = bytes hex
    //  que espera parse_uart_dbg.py:  grep "^PKT" sim.log | sed 's/PKT //' | python3 parse_uart_dbg.py
    integer tlk;
    always @(posedge clkg) if (!rst && tl_pkt_start) begin
        $write("PKT");
        for (tlk=0; tlk<UART_NB; tlk=tlk+1) $write(" %02x", tl_data[8*tlk +: 8]);
        $write("\n");
    end
`endif
`endif

    // ===================== TRAZA DE SIM =====================
`ifdef SIMULATION
    integer wr_vram=0, wr_pal=0, n_progrd=0, mcu_fetch=0, mcu_shwr=0, mcu_rst=0;
    reg [19:1] pcmax=0; reg [19:0] hb=0; reg [14:0] dallas_prev=0, mcu_pcmax=0;
    reg mcuw_prev=0, rdw_prev=0;  // flanco de mcu_xwr/xrd (eventos REALES, no nivel multi-ciclo)
    integer mcu_rdn=0;
    // --- diag HANDSHAKE 68k->shram (2026-06-26): la LLAVE en MAME es 68k escribe fefc04=0xffff @PC0x2f9e ---
    //  shidx(fefc04)=0x3e02. Confirmar si NUESTRO 68k llega a ese write. + trayectoria PC del 68k vs MAME
    //  (MAME: ff12 clear-loop -> 2f9e KEY -> 3330). word de 0x2f9e = 0x17cf; 0xff12=0x7f89; 0x3330=0x1998.
    integer k68w=0, n68log=0, key_seen=0;
    reg sw_prev=0;
    reg seen_2f9e=0, seen_3330=0, seen_ff12=0;   // landmarks de ejecución del 68k (fetch de ROM)
    // --- diag GENÉRICO de escrituras del 68k: ¿escribe a ALGO? ¿wr_ack funciona? ---
    integer nwr=0, nwrlog=0; reg wrcyc_prev=0;
    // probe RAW del bus (independiente de wr_ack): ¿el 68k baja ASn+DS en un ciclo de ESCRITURA?
    integer nwrbus=0; reg wrbus_prev=0;
    // TRAYECTORIA del 68k desde reset (primeras 80 direcciones de fetch ROM distintas) vs MAME (2400->240a->1b18e->1b198)
    reg [19:1] pc_last=0; integer npc=0;
    // --- diag ADC: ¿el juego accede al LS259 (q5=adcclk q6=adccs)? (sólo en modo Pot Wheel / gameplay) ---
    integer nlatch=0, nlatchlog=0; reg latch_prev=0;
    always @(posedge clkg) begin
        latch_prev <= u_main.latch_we;
        if (u_main.latch_we & ~latch_prev) begin
            nlatch <= nlatch+1;
            if (nlatchlog<20) begin nlatchlog <= nlatchlog+1;
                $display("LS259 wr#%0d sel=%0d dat=%b%s", nlatch, u_main.latch_sel, u_main.oEdb[0],
                         (u_main.latch_sel==3'd5)?" (ADC clk)":(u_main.latch_sel==3'd6)?" (ADC cs)":""); end
        end
        if (main_cs && main_ok) begin n_progrd<=n_progrd+1; if (rom68k_addr>pcmax) pcmax<=rom68k_addr; end
        if (vmem_we && vmem_cs_vram) wr_vram<=wr_vram+1;
        if (vmem_we && vmem_cs_pal ) wr_pal <=wr_pal +1;
        dallas_prev <= dallas_addr;
        if (dallas_addr != dallas_prev) mcu_fetch <= mcu_fetch+1;
        if (dallas_addr > mcu_pcmax) mcu_pcmax <= dallas_addr;
        if (dallas_addr<15'd8 && dallas_prev>=15'd8) mcu_rst <= mcu_rst+1;
        // escrituras MCU->shram por FLANCO (rising de mcu_xwr&mcu_sh) + log de las primeras 24 reales
        mcuw_prev <= (u_main.mcu_xwr & u_main.mcu_sh);
        if ((u_main.mcu_xwr & u_main.mcu_sh) & ~mcuw_prev) begin
            mcu_shwr <= mcu_shwr+1;
            if (mcu_shwr<24) $display("RTLMCUW#%0d [%04x]=%02x mcuPC=%h", mcu_shwr, u_main.mcu_xaddr, u_main.mcu_xdout, dallas_addr);
        end
        // ESCRITURAS del 68k a la shram (SIN filtro): contar todo + loguear primeras 60 + cazar la LLAVE.
        sw_prev <= (u_main.sw_hi | u_main.sw_lo);
        if ((u_main.sw_hi | u_main.sw_lo) & ~sw_prev) begin
            k68w <= k68w+1;
            if (n68log<60) begin
                n68log <= n68log+1;
                $display("RTL68kSHW#%0d shidx=%h hi=%b lo=%b data=%04x 68kPC=%h", k68w, u_main.shidx, u_main.sw_hi, u_main.sw_lo, u_main.oEdb, {rom68k_addr,1'b0});
            end
            // LLAVE: fefc04 = shidx 0x3e02. ¿la escribimos? (en MAME =0xffff)
            if (u_main.shidx==14'h3e02) begin
                key_seen <= key_seen+1;
                $display(">>> RTL KEY fefc04 WRITE #%0d hi=%b lo=%b data=%04x 68kPC=%h", key_seen, u_main.sw_hi, u_main.sw_lo, u_main.oEdb, {rom68k_addr,1'b0});
            end
        end
        // TRAYECTORIA: primeras 80 direcciones DISTINTAS de fetch de ROM (=PC del 68k al ejecutar)
        if (main_cs && main_ok && rom68k_addr!=pc_last && npc<80) begin
            pc_last <= rom68k_addr; npc <= npc+1;
            $display("RTLPC#%0d addr=%h data=%04x", npc, {rom68k_addr,1'b0}, main_data);
        end
        // RAW: ciclo de escritura en el bus (ASn bajo + DS bajo + write), SIN depender de wr_ack
        wrbus_prev <= (~u_main.ASn & ~u_main.rw_rd & (u_main.uds|u_main.lds));
        if ((~u_main.ASn & ~u_main.rw_rd & (u_main.uds|u_main.lds)) & ~wrbus_prev) nwrbus <= nwrbus+1;
        // CUALQUIER escritura del 68k (wr_ack & write), sin importar la región: ¿escribe a algo? ¿a dónde?
        wrcyc_prev <= (u_main.wr_ack & ~u_main.rw_rd);
        if ((u_main.wr_ack & ~u_main.rw_rd) & ~wrcyc_prev) begin
            nwr <= nwr+1;
            if (nwrlog<40) begin
                nwrlog <= nwrlog+1;
                $display("RTL68kWR#%0d addr=%h uds=%b lds=%b data=%04x | rom=%b vram=%b pal=%b vreg=%b wram=%b shram=%b snd=%b",
                    nwr, u_main.addr, u_main.uds, u_main.lds, u_main.oEdb,
                    u_main.cs_rom, u_main.cs_vram, u_main.cs_pal, u_main.cs_vregs, u_main.cs_wram, u_main.cs_shram, u_main.cs_sound);
            end
        end
        // TRAYECTORIA del 68k: marcar el primer fetch de ROM en los landmarks de MAME (palabra eab[19:1])
        if (main_cs && main_ok) begin
            if (rom68k_addr==19'h7f89 && !seen_ff12) begin seen_ff12<=1; $display(">>> 68k @ 0xff12 (clear-loop) hb=%0d", hb); end
            if (rom68k_addr==19'h17cf && !seen_2f9e) begin seen_2f9e<=1; $display(">>> 68k @ 0x2f9e (KEY code) hb=%0d", hb); end
            if (rom68k_addr==19'h1998 && !seen_3330) begin seen_3330<=1; $display(">>> 68k @ 0x3330 (post-key)  hb=%0d", hb); end
        end
        hb<=hb+1'b1;
        if (hb==20'd0) $display("HB 68kpc=%h pcmax=%h | MCU pc=%h pcmax=%h fetch=%0d mcuW=%0d | WRbus=%0d SHW=%0d KEY=%0d LS259=%0d @ff12=%0d @2f9e=%0d @3330=%0d",
                                {rom68k_addr,1'b0}, {pcmax,1'b0}, dallas_addr, mcu_pcmax, mcu_fetch, mcu_shwr, nwrbus, k68w, key_seen, nlatch, seen_ff12, seen_2f9e, seen_3330);
        // DIAG STALL (2026-06-29): estado del bus del 68k en cada HB -> ¿qué cs/dirección lo cuelga?
        if (hb==20'd0) $display("  BUS addr=%h ASn=%b rw_rd=%b uds=%b lds=%b | rom=%b vram=%b pal=%b vreg=%b wram=%b shram=%b snd=%b | wr_ack=%b main_cs=%b main_ok=%b",
                                u_main.addr, u_main.ASn, u_main.rw_rd, u_main.uds, u_main.lds,
                                u_main.cs_rom, u_main.cs_vram, u_main.cs_pal, u_main.cs_vregs, u_main.cs_wram, u_main.cs_shram, u_main.cs_sound,
                                u_main.wr_ack, main_cs, main_ok);
    end
`endif

endmodule

`default_nettype wire
