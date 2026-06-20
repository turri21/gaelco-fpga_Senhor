// ============================================================================
//  World Rally (Gaelco, 1993) — jtwrally_game.v: modulo de juego para jtframe.
//
//  Este es el UNICO modulo que escribimos para la infra jtframe. jtcore (memgen,
//  desde cfg/mem.yaml) AUTO-GENERA jtwrally_game_sdram.v (GAMETOP), que instancia
//  este modulo + los slots SDRAM (jtframe_rom_Nslots) + jtframe_dwnld + la BRAM de
//  wrdallas + los pll/cen/OSD/video-out de jtframe_board. Asi heredamos el reloj
//  SDRAM STOCK y la SDC testados de jotego (el objetivo de toda la migracion: el
//  negro era divergencia del framework SDRAM hand-rolled, no de nuestra logica).
//
//  Lo que va DENTRO (verificado pixel-exacto vs MAME, intacto): wrally_main
//  (68000 fx68k + DS5002/r8051), wrally_vmem (VRAM/paleta/sprite-RAM en BRAM),
//  wrally_video_top (tilemaps+sprites+mezcla), wrally_inputs.
//
//  Buses SDRAM por NOMBRE (declarados como puertos en el mem_ports.inc generado):
//    prog_*  (68000 prog, DW16)  gfx0_*/gfx1_*/gfxs_* (gfx, DW32)  oki_* (DW8)
//    wrdallas_addr/wrdallas_data (DS5002 rom interna, BRAM via PROM)
//
//  NOTA (1a pasada jtcore): reconciliar nombres/anchos exactos de los puertos de
//  bus contra el mem_ports.inc generado; ajustar aqui si difieren.
// ============================================================================
`default_nettype none

module jtwrally_game(
    `include "jtframe_game_ports.inc"
);
    // RELOJES (FIX 2026-06-16): con JTFRAME_SDRAM96, `clk`=clk96=96MHz (lo conduce el tb /
    // PLL) y los SLOTS SDRAM corren a `clk`. La LOGICA DEL JUEGO debe correr a `clk48`=48MHz
    // (patron jtframe game@48 + SDRAM@96): asi los divisores /4,/7,/48 dan los rates correctos
    // (68k/MCU 12MHz, pixel 6.857MHz, OKI 1MHz) y la sintesis cierra a 48, no 96. ANTES todo
    // colgaba de `clk`(96) -> TODO al doble (CPU 24MHz, frame 116Hz, ce_pix 13.7MHz) y solo 7
    // ciclos SDRAM/pixel (ruido). Con clk48: 14 ciclos clk96/pixel. clk48 es clk/2 fase-alineado
    // -> muestreo de los slots (clk) desde clk48 es seguro (mesocrono).
    wire clkg = clk48;   // reloj de la logica del juego

    // pxl_cen/pxl2_cen GENERADOS A MANO. FIX 0x0 (2026-06-16): pasamos de /7 (6.857MHz, IMPAR)
    // a **/6 = 8 MHz (PAR)**. Con /7 el pxl2_cen/pxl1_cen quedaba mal espaciado (fases 0 y 3 de 7,
    // no la mitad exacta) -> el scan-doubler del scaler de MiSTer media mal -> resolucion 0x0.
    // Con /6, pxl_cen=fase0 y pxl1_cen(=pxl2_cen&~pxl_cen)=fase3 = la MITAD EXACTA -> spacing limpio
    // = lo que el scaler necesita. clk48/6 = clk96/12 = IDENTICO al pxl_cen de JTFRAME_PXLCLK=8,
    // pero sin forzar todo a clk96 (fx68k sigue relajado a clk48). pxl2_cen = clk48/3 = 16MHz (2x).
    reg [2:0] pxdiv = 3'd0;
    always @(posedge clkg) pxdiv <= (pxdiv==3'd5) ? 3'd0 : pxdiv + 3'd1;
    assign pxl_cen  = (pxdiv==3'd0);
    assign pxl2_cen = (pxdiv==3'd0) || (pxdiv==3'd3);
    wire ce_pix = (pxdiv==3'd0);

    // 68000/MCU a 12 MHz (clk48/4), OKI a ~1 MHz (clk48/48). Generados INLINE (sin reset
    // asincrono; init=0 como pxdiv) porque wrally_clocks con `posedge rst` no arranca
    // bajo Verilator si rst no tiene flanco 0->1. Robusto en sim y HW.
    reg [1:0] cdiv = 2'd0;
    reg [5:0] odiv = 6'd0;
    reg cpu_cen_phi1 = 1'b0, cpu_cen_phi2 = 1'b0, mcu_cen = 1'b0, oki_cen = 1'b0;
    always @(posedge clkg) begin
        cdiv         <= (cdiv==2'd3) ? 2'd0 : cdiv + 2'd1;
        cpu_cen_phi1 <= (cdiv==2'd0);
        cpu_cen_phi2 <= (cdiv==2'd2);
        mcu_cen      <= (cdiv==2'd0);
        odiv         <= (odiv==6'd47) ? 6'd0 : odiv + 6'd1;
        oki_cen      <= (odiv==6'd0);
    end

    // ===================== wrdallas (ROM interna DS5002, via BRAM/PROM jtframe) ====
    // jtframe carga wrdallas en JTFRAME_PROM_START y nos da wrdallas_data (lectura
    // registrada). El r8051 EXIGE que la lectura de su ROM este GATEADA por rom_en
    // (handshake DS5002) -> re-latcheamos wrdallas_data en mcurom_data solo con en.
    wire [14:0] mcurom_addr;
    wire        mcurom_en;
    assign wrdallas_addr = mcurom_addr;
    // FIX 2026-06-17 (CDC): la BRAM u_prom_wrdallas del GAMETOP se RECLOCA a clk48 (parche en _regen.sh:
    // .clk(clk)->.clk(clk48)), MISMO dominio que el r8051. Antes corria a clk96 y relatcheabamos a clk48
    // -> ese cruce clk96->clk48 era DETERMINISTA-malo en HW (el flanco clk48 muestreaba el dato clk96 con
    // el skew del PLL -> byte desplazado -> el r8051 divergia: firma=2704, mcuact=4 PESE a contenido OK y
    // vld@1/@3 -> el vld no arreglaba porque era QUE lee, no CUANDO). Con el prom a clk48 NO hay cruce:
    // wrdallas_data ya es mem[addr] a 1 clk48 -> lo leemos DIRECTO (sin relatch) -> rom_vld@1 casa.
    wire [ 7:0] mcurom_data = wrdallas_data;

`ifdef SIMULATION
    integer n_mcurd=0; reg [31:0] nz_wrdallas=0;
    always @(posedge clk) if (!rst) begin
        if (wrdallas_data!=8'd0) nz_wrdallas <= nz_wrdallas+1;
        if (mcurom_en && n_mcurd<16) begin
            n_mcurd = n_mcurd+1;
            $display("MCUROM #%0d addr=%h en=%b wrdallas=%h mcurom_data=%h nz=%0d",
                     n_mcurd, mcurom_addr, mcurom_en, wrdallas_data, mcurom_data, nz_wrdallas);
        end
    end
`endif

    // ===================== CPU (wrally_main: 68000 + DS5002) =====================
    wire        flip_screen, vblank_irq;
    wire [13:0] vmem_addr; wire vmem_uds, vmem_lds, vmem_we, vmem_cs_vram, vmem_cs_pal, vmem_cs_spr;
    wire [15:0] vmem_vram_wdata, vmem_io_wdata, vmem_vram_rdata, vmem_pal_rdata, vmem_spr_rdata;
    wire [15:0] vreg0, vreg1, vreg2, vreg3;
    wire [15:0] dbg_firma_w; wire [7:0] dbg_mcu_act_w;
    // telemetria paginada (r8051/handshake) desde wrally_main
    wire [15:0] dbg_mcu_pc_w, dbg_mcu_pcmax_w, dbg_mcu_fetch_w, dbg_mcu_oor_w, dbg_mcu_coll_w;
    wire [ 7:0] dbg_rd0_w, dbg_rd1_w, dbg_rd2_w, dbg_rd3_w, dbg_mcu_wrby_w, dbg_1a80_mcu_w, dbg_1a80_cpu_w;
    wire [13:0] dbg_mcu_wradr_w;
    wire [15:0] dbg_mcu_rdmax_w, dbg_mcu_rdadr_w, dbg_mcu_nrd_w;   // lecturas MCU (barrido xdata)
    wire [ 7:0] dbg_mcu_rdby_w, dbg_68k_wrby_w;
    wire [13:0] dbg_68k_wradr_w;
    wire        dbg_68k_w01_w;   // pegajoso: el 68k escribio 0x01 (wake) en 0x1A80
    wire [23:0] dbg_68k_fpc_w, dbg_68k_dacc_w;                    // 68k profundo: fetch-PC / data-addr
    wire [15:0] dbg_68k_flow_w, dbg_68k_iack_w, dbg_68k_h400_w, dbg_68k_exc_w;  // contadores handler/IACK
    wire [ 7:0] dbg_exc_num_w;  wire [23:0] dbg_fault_pc_w, dbg_fault_pcl_w, dbg_68k_fault1_w;   // caja negra excepcion + PC culpable directo
    wire [23:0] dbg_rst_sp_w, dbg_rst_pc_w, dbg_first_fetch_w;   // reset vector que la SDRAM entrega al 68k + 1er fetch
    wire [19:1] rom68k_addr;            // direccion de prog del 68000 (word [19:1])
    wire [19:0] oki_rom_addr;
    wire [13:0] snd14;                  // salida OKI (14-bit) del core
    wire        snd_sample_w;           // strobe de sample-rate real del OKI (jt6295.sample) -> jtframe

    // Entradas WRally (4 palabras del 68000) desde wrally_inputs (abajo).
    wire [15:0] in_dsw, in_p1p2, in_wheel, in_system;

    // SCENE-REPLAY (WR_SCENE): la CPU se mantiene en RESET (no sobreescribe la vmem precargada por
    // wrally_vmem con un dump de escena de MAME) y los vregs (scroll) se fuerzan del dump. El video
    // renderiza esa escena SIN boot (~3 min vs ~40). Sin WR_SCENE: todo normal. Ver tools/wr_scene_prep.py.
`ifdef WR_SCENE
    wire cpu_rst = 1'b1;
    reg [15:0] scene_vreg [0:3];
    initial $readmemh("scene_vregs.hex", scene_vreg);
    wire [15:0] vv0=scene_vreg[0], vv1=scene_vreg[1], vv2=scene_vreg[2], vv3=scene_vreg[3];
`else
    wire cpu_rst = rst;
    wire [15:0] vv0=vreg0, vv1=vreg1, vv2=vreg2, vv3=vreg3;
`endif

    // MCU REAL (r8051 + wrdallas): MCU_STUB=0. El handshake DS5002 (firma A5 3E) es necesario para
    // pasar el "Coprocessor OK" del POST y que el 68000 dibuje.
    // MCU_FULLSPEED CONDICIONAL: =1 (cpu_en=1, full-speed) SOLO en sim -> completa el handshake en
    // pocos frames. En HW =0 -> r8051 a mcu_cen (clk48/4=12MHz, velocidad real del DS5002): el path
    // critico del r8051 (~26ns) NO cumple clk48 single-cycle (20.8ns) a fullspeed -> a 12MHz cierra
    // timing limpio (verificado tb_ds5002_cen -> a53e). SIMULATION solo lo define el sim, no Quartus.
`ifdef SIMULATION
  `ifdef WRALLY_MCU_SLOW
    localparam MCU_FS = 1'b0;   // DIAGNOSTICO: reproducir la config HW vieja (12MHz) en sim
  `else
    localparam MCU_FS = 1'b1;   // sim: full-speed
  `endif
`else
    localparam MCU_FS = 1'b1;   // HW (2026-06-17): FS=1 (cpu_en=1) = logica PROBADA (a53e en sim). El
                                // handshake del r8051 NO sobrevive el cen dividido (FS=0) -> usar cen
                                // pleno; el timing a clk48 cierra si quitamos el multicycle del r8051 del SDC.
`endif
    wrally_main #(.MCU_FULLSPEED(MCU_FS), .MCU_STUB(1'b0)) u_cpu (
        .clk(clkg), .rst(cpu_rst),
        .cpu_cen_phi1(cpu_cen_phi1), .cpu_cen_phi2(cpu_cen_phi2),
        .mcu_cen(mcu_cen), .oki_cen(oki_cen),
        .vblank_irq(vblank_irq),
        .prog_addr(rom68k_addr), .prog_cs(cpu_main_cs), .prog_data(main_data), .prog_data_ok(main_ok),
        .mcurom_addr(mcurom_addr), .mcurom_en(mcurom_en), .mcurom_data(mcurom_data),
        .oki_rom_addr(oki_rom_addr), .oki_rom_data(oki_data), .oki_rom_ok(oki_ok),
        .in_dsw(in_dsw), .in_p1p2(in_p1p2), .in_wheel(in_wheel), .in_system(in_system),
        .flip_screen(flip_screen),
        .vmem_addr(vmem_addr), .vmem_uds(vmem_uds), .vmem_lds(vmem_lds), .vmem_we(vmem_we),
        .vmem_cs_vram(vmem_cs_vram), .vmem_cs_pal(vmem_cs_pal), .vmem_cs_spr(vmem_cs_spr),
        .vmem_vram_wdata(vmem_vram_wdata), .vmem_io_wdata(vmem_io_wdata),
        .vmem_vram_rdata(vmem_vram_rdata), .vmem_pal_rdata(vmem_pal_rdata), .vmem_spr_rdata(vmem_spr_rdata),
        .vreg0(vreg0), .vreg1(vreg1), .vreg2(vreg2), .vreg3(vreg3),
        .sound(snd14), .snd_sample(snd_sample_w),
        .dbg_firma(dbg_firma_w), .dbg_mcu_act(dbg_mcu_act_w),
        .dbg_mcu_pc(dbg_mcu_pc_w), .dbg_mcu_pcmax(dbg_mcu_pcmax_w), .dbg_mcu_fetch(dbg_mcu_fetch_w),
        .dbg_rd0(dbg_rd0_w), .dbg_rd1(dbg_rd1_w), .dbg_rd2(dbg_rd2_w), .dbg_rd3(dbg_rd3_w),
        .dbg_mcu_oor(dbg_mcu_oor_w), .dbg_mcu_wradr(dbg_mcu_wradr_w), .dbg_mcu_wrby(dbg_mcu_wrby_w),
        .dbg_mcu_coll(dbg_mcu_coll_w), .dbg_1a80_mcu(dbg_1a80_mcu_w), .dbg_1a80_cpu(dbg_1a80_cpu_w),
        .dbg_mcu_rdmax(dbg_mcu_rdmax_w), .dbg_mcu_rdadr(dbg_mcu_rdadr_w), .dbg_mcu_rdby(dbg_mcu_rdby_w),
        .dbg_mcu_nrd(dbg_mcu_nrd_w), .dbg_68k_wradr(dbg_68k_wradr_w), .dbg_68k_wrby(dbg_68k_wrby_w),
        .dbg_68k_w01(dbg_68k_w01_w),
        .dbg_68k_fpc(dbg_68k_fpc_w), .dbg_68k_dacc(dbg_68k_dacc_w), .dbg_68k_flow(dbg_68k_flow_w),
        .dbg_68k_iack(dbg_68k_iack_w), .dbg_68k_h400(dbg_68k_h400_w), .dbg_68k_exc(dbg_68k_exc_w),
        .dbg_exc_num(dbg_exc_num_w), .dbg_fault_pc(dbg_fault_pc_w), .dbg_fault_pcl(dbg_fault_pcl_w),
        .dbg_68k_fault1(dbg_68k_fault1_w),
        .dbg_rst_sp(dbg_rst_sp_w), .dbg_rst_pc(dbg_rst_pc_w), .dbg_first_fetch(dbg_first_fetch_w)
    );
    wire cpu_main_cs;   // prog_cs del 68000 (multiplexado con la FSM de checksum abajo)

    // ===================== DIAGNOSTICO SDRAM (DEBUG, sin UART) =====================
    // SDRAM_CKS=1: una FSM lee el programa (word 0..0x7FFFF) por el bus 'main' y acumula un
    // checksum; el resultado se MUESTRA COMO COLOR DE PANTALLA (override de RGB abajo):
    //   azul+verde-barriendo = leyendo (vivo) ; verde = checksum OK (0x72E29C19) -> SDRAM
    //   ARREGLADA ; rojo = checksum != -> SDRAM aun corrupta ; azul congelado = main_ok
    //   atascado (SDRAM no responde). Responde la pregunta central de la migracion SIN UART.
    //   En este modo el bus 'main' lo conduce la FSM (el 68000 queda ignorado).
    // Controlado por macro: define WRALLY_CKS (en macros.def) para el build-diagnostico de
    // color; sin definir (p.ej. en sim jtsim) -> 0 = modo CPU normal (probar arranque del 68k).
`ifdef WRALLY_CKS
    localparam        SDRAM_CKS  = 1'b1;
`else
    localparam        SDRAM_CKS  = 1'b0;
`endif
    localparam [31:0] CKS_GOLDEN = 32'h72E29C19;
    reg  [18:0] cks_addr = 19'd0;
    reg         cks_cs   = 1'b0;
    reg  [31:0] cks_sum  = 32'd0;
    reg         cks_done = 1'b0;
    reg         cks_st   = 1'b0;
    // V.047: captura cruda de las 8 PRIMERAS palabras del banco 0 (word 0..7). Valores conocidos
    // (reset vector): w0=0x00FE w1=0xFF80 (SP=0x00FEFF80), w2=0x0000 w3=0x2400 (PC=0x00002400).
    // El patron desambigua: todo-cero=no escrito/read-muerto / =reset-vector=lee-bien /
    // desplazado=off-by-one (shift) / byte-swap=orden de bytes.
    reg  [15:0] cks_w0=0, cks_w1=0, cks_w2=0, cks_w3=0, cks_w4=0, cks_w5=0, cks_w6=0, cks_w7=0;
    always @(posedge clk) begin
        if (rst) begin cks_addr<=0; cks_cs<=0; cks_sum<=0; cks_done<=0; cks_st<=0; end
        else if (SDRAM_CKS && !cks_done) case (cks_st)
            1'b0: begin cks_cs <= 1'b1; cks_st <= 1'b1; end
            1'b1: if (main_ok) begin
                      cks_sum <= {cks_sum[30:0], cks_sum[31]} + main_data;   // rot-izq 1 + add
                      cks_cs  <= 1'b0;
                      case (cks_addr[2:0])   // latch crudo de las 8 primeras (cks_addr<8)
                        3'd0: if(cks_addr==0) cks_w0<=main_data;
                        3'd1: if(cks_addr==1) cks_w1<=main_data;
                        3'd2: if(cks_addr==2) cks_w2<=main_data;
                        3'd3: if(cks_addr==3) cks_w3<=main_data;
                        3'd4: if(cks_addr==4) cks_w4<=main_data;
                        3'd5: if(cks_addr==5) cks_w5<=main_data;
                        3'd6: if(cks_addr==6) cks_w6<=main_data;
                        3'd7: if(cks_addr==7) cks_w7<=main_data;
                      endcase
                      if (cks_addr == 19'h7FFFF) cks_done <= 1'b1;
                      else begin cks_addr <= cks_addr + 1'b1; cks_st <= 1'b0; end
                  end
        endcase
    end
    wire cks_match = cks_done && (cks_sum == CKS_GOLDEN);
    wire cks_fail  = cks_done && (cks_sum != CKS_GOLDEN);

    // ===================== DIAGNOSTICO DW8 (PLAN-DW8, 2026-06-18) =================
    // El banco 0 (DW16) pierde el BYTE ALTO en HW (low byte OK, high=0). Para distinguir
    // "DW16 roto" de "carril alto fisico/download roto", cargamos una COPIA del prog en el
    // BANCO 2 (oki, DW8, OTRO banco) via la .mra y lo leemos byte a byte por el bus oki.
    // Reconstruimos word i = {byte(2i+1), byte(2i)} (SWAB=0, IGUAL que el banco0 'main')
    // -> c2_sum es comparable al MISMO golden 0x72E29C19. Veredicto:
    //   c2 (DW8) recupera el byte alto y cks (DW16) no -> DW16 roto, DW8 = FIX.
    //   c2 (DW8) TAMBIEN lo pierde                     -> no es el ancho, es el carril alto.
    // bank2 esta en OTRO banco que bank0 -> separa "ancho" de "region/banco".
    reg  [19:0] c2_baddr = 20'd0;   // direccion de BYTE en el banco2 (0..0xFFFFF = 1MB)
    reg         c2_cs    = 1'b0;
    reg  [31:0] c2_sum   = 32'd0;
    reg         c2_done  = 1'b0;
    reg  [ 1:0] c2_st    = 2'd0;
    reg  [ 7:0] c2_lo    = 8'd0;    // byte bajo latcheado (espera al byte alto)
    reg  [127:0] c2_bytes = 128'd0; // b0..b15 crudos: c2_bytes[8*k +: 8] = byte k (inspeccion directa)
    always @(posedge clk) begin
        if (rst) begin c2_baddr<=0; c2_cs<=0; c2_sum<=0; c2_done<=0; c2_st<=0; c2_lo<=0; end
        else if (SDRAM_CKS && !c2_done) case (c2_st)
            2'd0: begin c2_cs<=1'b1; c2_st<=2'd1; end       // pide byte BAJO (addr par)
            2'd1: if (oki_ok) begin
                      c2_lo <= oki_data;                     // latch byte bajo
                      if (c2_baddr < 20'd16) c2_bytes[8*c2_baddr[3:0] +: 8] <= oki_data;
                      c2_cs <= 1'b0; c2_baddr <= c2_baddr + 1'b1; c2_st <= 2'd2;
                  end
            2'd2: begin c2_cs<=1'b1; c2_st<=2'd3; end       // pide byte ALTO (addr impar)
            2'd3: if (oki_ok) begin
                      if (c2_baddr < 20'd16) c2_bytes[8*c2_baddr[3:0] +: 8] <= oki_data;
                      c2_sum <= {c2_sum[30:0], c2_sum[31]} + {oki_data, c2_lo}; // word={high,low}
                      c2_cs <= 1'b0;
                      if (c2_baddr == 20'hFFFFF) c2_done <= 1'b1;
                      else begin c2_baddr <= c2_baddr + 1'b1; c2_st <= 2'd0; end
                  end
        endcase
    end
    wire c2_match = c2_done && (c2_sum == CKS_GOLDEN);

    // main bus: en modo CKS lo conduce la FSM; si no, el 68000 (word-addr [19:1]).
    assign main_addr = SDRAM_CKS ? cks_addr   : rom68k_addr;
    assign main_cs   = SDRAM_CKS ? cks_cs     : cpu_main_cs;

    // ===================== memorias de video compartidas (BRAM, dentro) ==========
    wire [13:0] vram_a0, vram_a1; wire [31:0] vram_q0, vram_q1;
    wire [9:0]  pal_a;  wire [12:0] palb_a;   // palb_a 13 bits: bancos de sombra de sprite
    wire [15:0] pal_q, palb_q;
    wire [10:0] spr_a;            wire [15:0] spr_q;

    wrally_vmem u_vmem (
        .clk(clkg), .ce_pix(ce_pix),
        .cpu_addr(vmem_addr), .cpu_uds(vmem_uds), .cpu_lds(vmem_lds), .cpu_we(vmem_we),
        .cs_vram(vmem_cs_vram), .cs_pal(vmem_cs_pal), .cs_spr(vmem_cs_spr),
        .vram_wdata(vmem_vram_wdata), .io_wdata(vmem_io_wdata),
        .cpu_vram_rdata(vmem_vram_rdata), .cpu_pal_rdata(vmem_pal_rdata), .cpu_spr_rdata(vmem_spr_rdata),
        .vram_a0(vram_a0), .vram_a1(vram_a1), .vram_q0(vram_q0), .vram_q1(vram_q1),
        .pal_a(pal_a), .palb_a(palb_a), .pal_q(pal_q), .palb_q(palb_q),
        .spr_a(spr_a), .spr_q(spr_q)
    );

    // ===================== buses gfx SDRAM (DW=32 -> 4 planos) ====================
    // El memgen anexa {addr,1'b0} al slot DW32: el game provee el INDICE de elemento.
    wire [18:0] rom_a0, rom_a1, srom_a;
    // EXPERIMENTO V.049: en modo CKS apagamos las peticiones SDRAM de gfx/oki (que con cs=1 constante
    // martillean la SDRAM e interleavean rafagas DW32 con la lectura DW16 del banco 0). Aisla si ese
    // trafico/interleave corrompe el byte alto del banco 0. Fuera de CKS, comportamiento normal.
    assign gfx0_addr = rom_a0;  assign gfx0_cs = SDRAM_CKS ? 1'b0 : 1'b1;
    assign gfx1_addr = rom_a1;  assign gfx1_cs = SDRAM_CKS ? 1'b0 : 1'b1;
    assign gfxs_addr = srom_a;  assign gfxs_cs = SDRAM_CKS ? 1'b0 : 1'b1;

    // OKI (DW=8): FIX V.057 (sonido = samples EQUIVOCADOS, "orden") -> QUITADO el swab ~addr[0].
    // El antiguo `{oki_rom_addr[19:1], ~oki_rom_addr[0]}` (XOR bit0, "byte logico i vive en stream[i^1]",
    // pretendidamente VERIFICADO tb_gfx_sdram) leia la ROM del OKI PAIR-SWAPPED en HW -> la TABLA de
    // direcciones del MSM6295 (al inicio de la ROM, entradas de 8B [start:3 BE][end:3 BE][pad:2]) salia
    // basura -> cada comando -> sample equivocado (+ distorsion del ADPCM pair-swapped). La SDRAM del OKI
    // es NATURAL (DW8 plano, como el prog DW16 cuyo sdram_bank0==rom; verificado rom[0x300000:]==w14+w15
    // natural, NO byteswap16). -> direccion DIRECTA, sin swab. (Si en HW sonara mal al reves, volver al swab.)
    // EN MODO CKS: el bus oki lo conduce la FSM c2_* (lee el banco2 = COPIA del prog, byte a byte).
    assign oki_addr = SDRAM_CKS ? c2_baddr : oki_rom_addr;
    assign oki_cs   = SDRAM_CKS ? c2_cs    : 1'b1;

    // 32b -> 4 planos. FIX byte-lanes (2026-06-15): el path de descarga DW32 de jtframe almacena
    // cada palabra de 16 bits BYTE-SWAPPEADA respecto al stream .mra [i07,i09,i11,i13] (verificado:
    // sdram_bank1.bin == byteswap16(rom.bin gfx) al 100%; bank0 prog DW16 es directo). El mapeo
    // anterior {i11,i13,i07,i09} daba pen6 en vez de pen9 para el tile de fondo solido 0x2a5c
    // (-> fondo BLANCO). Se deshace intercambiando los pares: {d_i13,d_i11,d_i09,d_i07}=gfx_data.
    wire [7:0] d0_i07,d0_i09,d0_i11,d0_i13, d1_i07,d1_i09,d1_i11,d1_i13, sd_i07,sd_i09,sd_i11,sd_i13;
    assign {d0_i13,d0_i11,d0_i09,d0_i07} = gfx0_data;
    assign {d1_i13,d1_i11,d1_i09,d1_i07} = gfx1_data;
    assign {sd_i13,sd_i11,sd_i09,sd_i07} = gfxs_data;

    // ===================== video (tilemap; sprite en BYPASS para v1) =============
    wire [7:0] r8, g8, b8;
    wire       hs_w, vs_w, hb_w, vb_w, de_w;
    wrally_video_top u_video (
        .clk(clkg), .clk96(clk96), .rst(rst), .ce_pix(ce_pix),
        .vreg_l0y(vv0), .vreg_l0x(vv1), .vreg_l1y(vv2), .vreg_l1x(vv3),
        .vram_a0(vram_a0), .vram_q0(vram_q0), .rom_a0(rom_a0),
        .d0_i07(d0_i07), .d0_i09(d0_i09), .d0_i11(d0_i11), .d0_i13(d0_i13),
        .vram_a1(vram_a1), .vram_q1(vram_q1), .rom_a1(rom_a1),
        .d1_i07(d1_i07), .d1_i09(d1_i09), .d1_i11(d1_i11), .d1_i13(d1_i13),
        .pal_a(pal_a), .pal_q(pal_q), .palb_a(palb_a), .palb_q(palb_q),
        .spr_a(spr_a), .spr_q(spr_q), .srom_a(srom_a),
        .sd_i07(sd_i07), .sd_i09(sd_i09), .sd_i11(sd_i11), .sd_i13(sd_i13),
        .gfx0_ok(gfx0_ok), .gfx1_ok(gfx1_ok),          // handshake tilemap gfx (prefetch -> fix lineas verticales)
        .spr_gfx_ok(gfxs_ok), .spr_en(1'b1),          // v2: SPRITES ACTIVOS (formato validado vs MAME)
        .vga_r(r8), .vga_g(g8), .vga_b(b8),
        .hsync(hs_w), .vsync(vs_w), .hblank(hb_w), .vblank(vb_w), .de(de_w),
        .ce_pix_o(), .vblank_irq(vblank_irq)
    );

    // Salida de video a jtframe: COLORW=4 (xBRG_444). LHBL/LVBL = blanking activo-bajo.
    // En modo SDRAM_CKS, RGB se OVERRIDEA con el color-diagnostico del checksum (ver FSM):
    //   leyendo = azul + verde barriendo (cks_addr) ; OK = verde ; FAIL = rojo ; main_ok
    //   atascado = azul congelado (sin barrido). El sync/timing siguen saliendo del video.
    wire [3:0] cks_r = cks_fail  ? 4'hF : 4'h0;
    wire [3:0] cks_g = cks_match ? 4'hF : (cks_done ? 4'h0 : cks_addr[18:15]);
    wire [3:0] cks_b = cks_done  ? 4'h0 : 4'hF;
    assign red   = SDRAM_CKS ? cks_r : r8[7:4];
    assign green = SDRAM_CKS ? cks_g : g8[7:4];
    assign blue  = SDRAM_CKS ? cks_b : b8[7:4];
    assign HS    = hs_w;
    assign VS    = vs_w;
    assign LHBL  = ~hb_w;
    assign LVBL  = ~vb_w;

    // ===================== audio =====================
    // OKI 14-bit con signo -> snd 16-bit. V.058 puso x4 ({snd14,2'b00}): satura los PICOS
    // (snd14=+-8191 -> +-32764 = fondo de escala) pero el nivel MEDIO del OKI es bajo -> "suena bajo".
    // V.059: GAIN x8 (+6dB vs x4) CON SATURACION (un shift a secas haria wraparound = chasquidos).
    // V.065 (2026-06-19): x16 (2x vs x8). V.067: BAJADO a x12 — x16 SATURABA (reportado en CRT por el
    // jack analogico; demasiado clip de picos). x12 (1.5x vs x8) sube el nivel medio pero recorta menos.
    // snd14 signed [13:0] -> x12 = +-98292 (18 bits) -> clamp a signed 16b [-32768,+32767].
    // (Si aun satura, bajar a x10/x8; si queda bajo, subir a x14.)
    wire signed [17:0] snd_g8 = $signed(snd14) * 18'sd12;
    assign snd = ( snd_g8 >  18'sd32767 ) ?  16'sd32767 :
                 ( snd_g8 < -18'sd32768 ) ? -16'sd32768 :
                                             snd_g8[15:0];
    // sample: strobe de SAMPLE-RATE REAL del OKI (jt6295.sample, propagado por wrally_main como
    // snd_sample). Antes era oki_cen (1MHz) -> el resampler de jtframe recibia el reloj del chip en vez
    // del ritmo de muestra real -> aliasing/distorsion ("mal"). Ahora el ritmo correcto.
    assign sample = snd_sample_w;

    // ===================== entradas =====================
    // jtframe joystick (activo-bajo): bit0=right,1=left,2=down,3=up,4=B1,5=B2(gear).
    // wrally_inputs espera activo-ALTO -> invertimos. (Polaridad coin/service/test a
    // verificar en HW; todas las opciones compilan.)

    // GEAR = palanca de 2 posiciones (MAME PORT_TOGGLE): cada PULSACION de B2 cambia de marcha,
    // no es momentaneo. Edge-detect del boton -> flip del estado. Reset = marcha baja (st=0).
    // wrally_inputs invierte el bit (~p1_gear) -> bit[4]=~st: default 1 (= toggle OFF de MAME,
    // IP_ACTIVE_HIGH+PORT_REVERSE). En HW: tap B = cambia marcha.
    reg p1_gear_st=1'b0, p2_gear_st=1'b0, p1_gbtn_d=1'b0, p2_gbtn_d=1'b0;
    wire p1_gbtn = ~joystick1[5];   // activo-alto (pulsado)
    wire p2_gbtn = ~joystick2[5];
    always @(posedge clkg) begin
        if (rst) begin p1_gear_st<=1'b0; p2_gear_st<=1'b0; p1_gbtn_d<=1'b0; p2_gbtn_d<=1'b0; end
        else begin
            p1_gbtn_d <= p1_gbtn; p2_gbtn_d <= p2_gbtn;
            if (p1_gbtn & ~p1_gbtn_d) p1_gear_st <= ~p1_gear_st;   // toggle en flanco de subida
            if (p2_gbtn & ~p2_gbtn_d) p2_gear_st <= ~p2_gear_st;
        end
    end

    // === TEST CONTROLES (solo-sim) — inyecta una MONEDA (coin1) en los frames 150-169 para confirmar
    //     que el 68k la LEE en P1_P2[6] y la procesa (crédito). En HW la moneda viene de ~coin[0]. Los
    //     controles los lee el 68k DIRECTO (0x700002), NO via el MCU -> independientes del freeze. ===
    wire coin1_base = ~coin[0];
`ifdef WR_INJECT_COIN
    // OPT-IN (solo test de controles): mete una moneda en frames 150-169. NO por defecto -> el sim normal
    // corre la DEMO DE ATRACCIÓN (sin crédito), que es donde está el freeze a investigar.
    wire coin1_inj = coin1_base | (tl_frame >= 24'd150 && tl_frame <= 24'd169);
`else
    wire coin1_inj = coin1_base;
`endif

    wrally_inputs u_inputs (
        .dsw   ( dipsw[15:0] ),
        .p1_up( ~joystick1[3] ), .p1_down( ~joystick1[2] ),
        .p1_left( ~joystick1[1] ), .p1_right( ~joystick1[0] ),
        .p1_btn1( ~joystick1[4] ), .p1_gear( p1_gear_st ),   // gear = estado TOGGLE (no momentaneo)
        .p2_up( ~joystick2[3] ), .p2_down( ~joystick2[2] ),
        .p2_left( ~joystick2[1] ), .p2_right( ~joystick2[0] ),
        .p2_btn1( ~joystick2[4] ), .p2_gear( p2_gear_st ),
        // jtframe entrega coin/start/service/dip_test en ACTIVO-BAJO (1=reposo), igual que el
        // joystick (cf. jts16: los mete directos en su puerto de cabina activo-bajo). wrally_inputs
        // los espera ACTIVO-ALTO (1=pulsado) -> INVERTIR (como los joysticks de arriba). Sin invertir,
        // en reposo el 68000 leia test=service=1 -> MODO TEST -> bucle de patrones, sin handshake.
        .coin1( coin1_inj ), .coin2( ~coin[1] ),
        .start1( ~cab_1p[0] ), .start2( ~cab_1p[1] ),
        .service( ~service ), .test( ~dip_test ),
        .port_dsw( in_dsw ), .port_p1p2( in_p1p2 ),
        .port_wheel( in_wheel ), .port_system( in_system )
    );

    // ===================== TRAZA DE SIM (diagnostico, SIMULATION) =====================
    // Imprime si el 68000 progresa (PCmax), si escribe VRAM/paleta/sprite/vregs y si
    // recibe IRQ de vblank. Responde: ¿la CPU ejecuta y dibuja, o se atasca?
`ifdef SIMULATION
    integer wr_vram=0, wr_pal=0, wr_spr=0, n_progrd=0, n_maincs=0, n_mainok=0, n_cen=0, n_clk=0, n_dist=0, n_okrise=0;
    reg [19:1] pcmax=0; reg vset=0; reg [19:1] last_pa=19'h7ffff; reg main_ok_prev=0;
    // GFXRDY: ¿el slot gfx esta listo cuando el tilemap consume en ce_pix? Si gfx0/1_ok=0 en
    // ce_pix -> el tilemap latchea dato RANCIO (no respeta el handshake) -> mota de ruido.
    integer n_cepix=0, n_gfx0nr=0, n_gfx1nr=0;
    always @(posedge clkg) if (ce_pix) begin
        n_cepix <= n_cepix+1;
        if (!gfx0_ok) n_gfx0nr <= n_gfx0nr+1;
        if (!gfx1_ok) n_gfx1nr <= n_gfx1nr+1;
    end
    // Traza del punto REAL de entrega del slot: (addr,data) en el flanco de subida de main_ok.
    always @(posedge clk) begin
        main_ok_prev <= main_ok;
        if (main_cs & main_ok & ~main_ok_prev & (n_okrise < 16)) begin
            $display("OKRISE #%0d addr=%h data=%h", n_okrise, {rom68k_addr,1'b0}, main_data);
            n_okrise <= n_okrise + 1;
        end
    end
    reg [19:0] hb=0;
    always @(posedge clk) begin
        n_clk <= n_clk + 1;                       // contador LIBRE: confirma que clk avanza
        if (main_cs)            n_maincs<=n_maincs+1;
        if (main_ok)            n_mainok<=n_mainok+1;
        if (cpu_cen_phi1)       n_cen  <=n_cen +1;
        if (main_cs && main_ok) begin
            n_progrd<=n_progrd+1; if (rom68k_addr>pcmax) pcmax<=rom68k_addr;
            // imprimir solo lecturas DISTINTAS (dedup wait-states) - primeras 24
            if (rom68k_addr != last_pa && n_dist < 24) begin
                $display("RD #%0d addr=%h data=%h", n_dist, {rom68k_addr,1'b0}, main_data);
                n_dist <= n_dist + 1;
            end
            last_pa <= rom68k_addr;
        end
        if (vmem_we && vmem_cs_vram) wr_vram<=wr_vram+1;
        if (vmem_we && vmem_cs_pal ) wr_pal <=wr_pal +1;
        if (vmem_we && vmem_cs_spr ) wr_spr <=wr_spr +1;
        if (|{vreg0,vreg1,vreg2,vreg3}) vset<=1'b1;
        hb<=hb+1'b1;
        if (hb==20'd0) $display("HB nclk=%0d pc=%h progrd=%0d PCmax=%h vram=%0d pal=%0d spr=%0d vset=%b mcuact=%h firma=%h | cepix=%0d gfx0nr=%0d gfx1nr=%0d",
                                n_clk, {rom68k_addr,1'b0}, n_progrd, {pcmax,1'b0}, wr_vram, wr_pal, wr_spr, vset, dbg_mcu_act_w, dbg_firma_w, n_cepix, n_gfx0nr, n_gfx1nr);
    end
`endif

    // ===================== TELEMETRIA UART (HW, sintetizable) =====================
    // Paquete de 32 bytes 8N1 9600 baud por uart_tx (game UART -> USER_IO -> /dev/ttyS1
    // con UART activo en el OSD de MiSTer). Liveness sin pantalla: clk/video (frame cnt),
    // 68000 (PC vivo/max), MCU (firma/act), dibujo (vram/pal), SALUD SDRAM en HW REAL
    // (gfx no-listo = margen; prog reads/stalls). Parser: mister/parse_uart_dbg.py.
`ifdef JTFRAME_GAME_UART
    localparam [23:0] SAT24 = 24'hFFFFFF;
    localparam [15:0] SAT16 = 16'hFFFF;
    reg [23:0] tl_frame=0, tl_vram=0, tl_gfxnr=0, tl_progrd=0;
    reg [19:1] tl_pamax=0;
    reg [15:0] tl_pal=0, tl_mainstall=0;
    reg        tl_vset=0, tl_vbl=0, tl_mokp=0;
    // DETECTOR DE CONGELACION (V.057, idea del usuario): la imagen "congelada" = la VRAM deja de escribirse.
    // Cada frame (vblank) comparo tl_vram con el snapshot del frame anterior; si NO cambio -> racha estatica.
    // frz_streak_start = frame donde EMPEZO la racha estatica actual (= frame del fallo cuando se congela);
    // frz_static = nº de frames consecutivos sin escritura de VRAM (enorme y creciente = CONGELADO).
    reg [23:0] frz_vsnap=0, frz_streak_start=0;
    reg [15:0] frz_static=0;
    always @(posedge clkg) begin
        if (rst) begin
            tl_frame<=0; tl_vram<=0; tl_gfxnr<=0; tl_progrd<=0; tl_pamax<=0;
            tl_pal<=0; tl_mainstall<=0; tl_vset<=0; tl_vbl<=0; tl_mokp<=0;
            frz_vsnap<=0; frz_streak_start<=0; frz_static<=0;
        end else begin
            if (vblank_irq) begin
                if (tl_vram == frz_vsnap) begin                              // frame SIN escrituras de VRAM
                    if (frz_static != 16'hFFFF) frz_static <= frz_static + 1'b1;
                end else begin                                              // hubo dibujo -> racha rota
                    frz_static <= 16'd0; frz_streak_start <= tl_frame;       // la proxima racha arranca aqui
                end
                frz_vsnap <= tl_vram;
            end
            if (vblank_irq)                      tl_frame <= tl_frame + 1'b1;
            if (vblank_irq)                      tl_vbl   <= 1'b1;
            if (rom68k_addr > tl_pamax)          tl_pamax <= rom68k_addr;
            if (vmem_we && vmem_cs_vram && tl_vram!=SAT24)      tl_vram  <= tl_vram + 1'b1;
            if (vmem_we && vmem_cs_pal  && tl_pal !=SAT16)      tl_pal   <= tl_pal  + 1'b1;
            if (ce_pix && (!gfx0_ok || !gfx1_ok) && tl_gfxnr!=SAT24) tl_gfxnr <= tl_gfxnr + 1'b1;
            tl_mokp <= (main_cs & main_ok);
            if (main_cs & main_ok & ~tl_mokp & (tl_progrd!=SAT24)) tl_progrd <= tl_progrd + 1'b1;
            if (main_cs & ~main_ok & (tl_mainstall!=SAT16))        tl_mainstall <= tl_mainstall + 1'b1;
            if (|{vreg0,vreg1,vreg2,vreg3})      tl_vset  <= 1'b1;
        end
    end
    wire [23:0] tl_palive = {4'd0, rom68k_addr, 1'b0};   // byte addr donde ejecuta AHORA
    wire [23:0] tl_pamaxb = {4'd0, tl_pamax,    1'b0};   // byte addr mas lejano alcanzado
    wire [7:0]  tl_status = {3'b0, tl_vset, tl_vbl, main_ok, gfx0_ok, gfx1_ok};

    // ===================== TELEMETRIA PAGINADA (32 bytes, 5 paginas rotativas) =====================
    // Paquete: [0]=55 [1]=AA (sync) [2]=PAGINA [3..30]=payload(28B, LE) [31]=0A. La pagina rota en cada
    // paquete (pkt_start). El parser decodifica segun [2]. Sigue el CHECKLIST de bring-up de abajo arriba:
    //   pag0=Cimientos(reloj/SDRAM)  pag1=68000  pag2=RAM/VRAM  pag3=r8051/Dallas  pag4=handshake wram.
    // Layout de cada payload (offset de BYTE dentro del payload, todo little-endian) -> ver parse_uart_dbg.py.
    localparam NPAGE = 3'd7;        // V.066: +pag6 = DIAGNOSTICO DE INPUTS
    wire tl_pkt_start;
    reg [2:0] tl_page = 0;
    always @(posedge clkg) if (rst) tl_page<=0; else if (tl_pkt_start) tl_page <= (tl_page==NPAGE-1)?3'd0:tl_page+1'b1;

    // === DIAGNOSTICO INPUTS (V.066): flags STICKY "visto pulsado" desde reset (jtframe activo-bajo, 0=pulsado).
    //   Localiza el corte del path de controles en HW: pulsa cada boton 1 vez y se queda latcheado.
    //   - seen_*  = el input de JTFRAME llego al juego alguna vez (jtframe->modulo OK si !=0 al pulsar).
    //   - p1p2_anylow = AND acumulado de in_p1p2: un bit=0 => ese boton SI propago hasta el puerto del 68k.
    //   Discrimina: seen=0 -> inputs no llegan de jtframe; seen!=0 & p1p2low bit=1 -> bug wrally_inputs;
    //   seen!=0 & p1p2low bit=0 -> llega y propaga (=> mirar firmware).
    reg [3:0]  seen_coin=0, seen_cab=0;
    reg [5:0]  seen_joy1=0;
    reg        seen_serv=0, seen_test=0;
    reg [15:0] p1p2_anylow=16'hFFFF;
    always @(posedge clkg) if (rst) begin
        seen_coin<=0; seen_cab<=0; seen_joy1<=0; seen_serv<=0; seen_test<=0; p1p2_anylow<=16'hFFFF;
    end else begin
        seen_coin   <= seen_coin | ~coin;            // coin/cab/joy activo-bajo -> ~x = 1 cuando pulsado
        seen_cab    <= seen_cab  | ~cab_1p;
        seen_joy1   <= seen_joy1 | ~joystick1[5:0];
        seen_serv   <= seen_serv | ~service;
        seen_test   <= seen_test | ~dip_test;
        p1p2_anylow <= p1p2_anylow & in_p1p2;        // in_p1p2 activo-bajo -> bit=0 si alguna vez se pulso
    end

    // payloads por pagina (224b = 28 bytes; byte0 del payload = byte3 del paquete; campos en LSB, pad en MSB)
    wire [223:0] tl_pl0 = { 88'd0, frz_static, frz_streak_start, tl_gfxnr, tl_mainstall, tl_status, tl_progrd, tl_frame };
        // [0:2]frame [3:5]progrd [6]status [7:8]mainstall [9:11]gfxnr [12:14]frz_streak_start(frame del fallo) [15:16]frz_static
    wire [223:0] tl_pl1 = { 40'd0, dbg_68k_exc_w, dbg_68k_h400_w, dbg_68k_iack_w, dbg_68k_flow_w,
                            dbg_68k_dacc_w, dbg_68k_fpc_w, tl_progrd, tl_pamaxb, tl_palive };
        // [0:2]PClive [3:5]PCmax [6:8]progrd [9:11]fetch-PC [12:14]data-addr [15:16]flow(vec) [17:18]iack [19:20]h400 [21:22]exc
    wire [223:0] tl_pl2 = { 112'd0, {7'd0,tl_vset}, vreg3, vreg2, vreg1, vreg0, tl_pal, tl_vram };
        // [0:2]vram [3:4]pal [5:6]vreg0 [7:8]vreg1 [9:10]vreg2 [11:12]vreg3 [13]vset
    wire [223:0] tl_pl3 = { 128'd0, dbg_rd3_w, dbg_rd2_w, dbg_rd1_w, dbg_rd0_w,
                            dbg_mcu_oor_w, dbg_mcu_fetch_w, dbg_mcu_pcmax_w, dbg_mcu_pc_w };
        // [0:1]PC [2:3]PCmax [4:5]fetch [6:7]oor(>=0x8000=derail) [8]rd0 [9]rd1 [10]rd2 [11]rd3  (rdN: ¿02 01 00 02?)
    wire [223:0] tl_pl4 = { 40'd0, {7'd0,dbg_68k_w01_w}, dipsw[15:0],   // [22]w01(=68k puso 0x01) [20:21]dipsw que ve el 68k
        dbg_68k_wrby_w, {2'd0,dbg_68k_wradr_w}, dbg_mcu_nrd_w, dbg_mcu_rdby_w, dbg_mcu_rdadr_w, dbg_mcu_rdmax_w,
        dbg_1a80_cpu_w, dbg_1a80_mcu_w, dbg_mcu_coll_w, dbg_mcu_wrby_w, {2'd0,dbg_mcu_wradr_w}, dbg_mcu_act_w, dbg_firma_w };
        // [0:1]firma [2]mcuact [3:4]wradr(word) [5]wrby [6:7]coll [8]1a80_mcu [9]1a80_cpu
        // [10:11]MCU rd_max(barrido) [12:13]MCU rd_addr [14]MCU rd_byte [15:16]MCU nº reads [17:18]68k wr_addr [19]68k wr_byte
    // P5 = CAJA NEGRA de excepcion del 68k: [0]exc# [1:3]PC del fallo (1a/raiz) [4:6]PC del fallo (ultima)
    wire [223:0] tl_pl5 = { 72'd0, dbg_first_fetch_w, dbg_rst_pc_w, dbg_rst_sp_w,
                            dbg_68k_fault1_w, dbg_fault_pcl_w, dbg_fault_pc_w, dbg_exc_num_w };
        // [0]exc# [1:3]PC fallo(handler) [4:6]PC fallo ultima [7:9]PC culpable directo
        // [10:12]reset SP (SDRAM) [13:15]reset PC (SDRAM, =dato entrada clave) [16:18]1er fetch
    // P6 = DIAGNOSTICO INPUTS (V.066): sticky "visto pulsado" + in_p1p2 acumulado
    wire [223:0] tl_pl6 = { 176'd0, p1p2_anylow[15:0], {2'd0,seen_joy1[5:0]},
                            {4'd0,seen_cab[3:0]}, {4'd0,seen_coin[3:0]}, {6'd0,seen_test,seen_serv} };
        // [0]={b1:test,b0:service}  [1]=coin[3:0]  [2]=cab/start[3:0]  [3]=joy1[5:0](RLDU+B1B2)
        // [4:5]=in_p1p2 acumulado (bit=0 si ese boton llego al puerto del 68k)
    reg [223:0] tl_payload;
    always @(*) case (tl_page)
        3'd0: tl_payload = tl_pl0;
        3'd1: tl_payload = tl_pl1;
        3'd2: tl_payload = tl_pl2;
        3'd3: tl_payload = tl_pl3;
        3'd4: tl_payload = tl_pl4;
        3'd5: tl_payload = tl_pl5;
        default: tl_payload = tl_pl6;
    endcase
`ifdef WRALLY_CKS
    // PLAN-DW8 (V.050): el paquete CKS lleva AHORA el banco0 (DW16) Y el banco2 (DW8). 64 bytes
    // (ver parse_uart_cks.py). Layout:
    //   [0]55 [1]AA [2]page=0
    //   [3:6]cks_sum(bank0 DW16) LE  [7:9]cks_addr LE  [10]cks_done  [11:26]cks_w0..w7 (16B)
    //   [27:30]c2_sum(bank2 DW8) LE  [31:33]c2_baddr LE  [34]c2_done  [35:50]c2_bytes b0..b15 (16B)
    //   [51:62]pad  [63]0A
    wire [8*64-1:0] tl_data = {
        8'h0A,                                                          // [63]
        96'd0,                                                          // [51:62] pad
        c2_bytes,                                                       // [35:50] b0..b15
        {7'd0,c2_done},                                                 // [34]
        {4'd0,c2_baddr},                                                // [31:33] c2_baddr LE
        c2_sum,                                                         // [27:30] bank2 DW8 sum
        cks_w7, cks_w6, cks_w5, cks_w4, cks_w3, cks_w2, cks_w1, cks_w0, // [11:26]
        {7'd0,cks_done},                                                // [10]
        {5'd0,cks_addr},                                                // [7:9]
        cks_sum,                                                        // [3:6] bank0 DW16 sum
        8'd0,                                                           // [2] page
        8'hAA, 8'h55 };                                                 // [1] [0]
`else
    wire [8*32-1:0] tl_data = { 8'h0A, tl_payload, {5'd0,tl_page}, 8'hAA, 8'h55 };
`endif

`ifdef WRALLY_CKS
    localparam integer UART_NB = 64;   // CKS V.050: paquete doble (bank0 DW16 + bank2 DW8)
`else
    localparam integer UART_NB = 32;
`endif
    wrally_dbg_uart #(.NB(UART_NB), .DIV(5000)) u_dbg_uart (  // 48 MHz (clkg) / 9600 = 5000
        .clk(clkg), .rst(rst), .data(tl_data), .pkt_start(tl_pkt_start), .txd(uart_tx)
    );
`ifdef SIMULATION
    // VOLCADO del paquete en sim (para validar la cadena empaquetado->parser SIN build). Formato = el
    // que espera parse_uart_dbg.py (bytes hex). grep "^PKT" sim.log | sed 's/PKT //' | python parse_uart_dbg.py
    integer tlk;
    always @(posedge clkg) if (!rst && tl_pkt_start) begin
        $write("PKT");
        for (tlk=0; tlk<UART_NB; tlk=tlk+1) $write(" %02x", tl_data[8*tlk +: 8]);
        $write("\n");
    end
`endif
`endif

    // ===================== sin usar de momento =====================
    assign debug_view = 8'd0;
    assign dip_flip   = 1'b0;       // OSD flip no usado (flip lo maneja wrally_main)
    // gfx_en, status, debug_bus, snd_en/snd_vol, joyana*, dial*: no usados en v1.

endmodule

`default_nettype wire
