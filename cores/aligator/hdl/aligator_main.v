// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 gaelco2.cpp / chip GAE1) — "PLACA" sintetizable:
//  68000 (fx68k) + mapa de memoria gaelco2 + protocolo de bus + IRQ6 (vblank) +
//  VRAM 64KB PLANA + paleta 8KB + vregs + work RAM 32KB + RAM compartida DS5002 32KB + I/O.
//
//  DIFERENCIAS vs Tipo-1 (squash/thoop/biomtoy):
//    - SIN cifrado de VRAM (gaelco2 vram_w escribe el dato crudo).
//    - VRAM = UNA sola región de 64KB (sprites+tilemaps+linescroll+scroll+sound), no vram/scrram.
//    - Paleta de 8KB (4096 colores; las variantes shadow/highlight se hacen en el vídeo).
//    - SIN OKI: el sonido lo hace el GAE1 (regs @0x202890; fase de sonido, aquí STUB).
//    - RAM compartida con el DS5002 (0xfe8000-0xfeffff): aquí BRAM plana R/W del 68k;
//      el MCU (runtime, camino WRally) se conecta en la fase DS5002.
//
//  Estructura/protocolo de bus reutilizados de aligator_main Tipo-1 (verificados: arranque
//  del 68k, DTACK co-generando los cen, IRQ6 autovector = irq6_line_hold de MAME).
// ============================================================================
`default_nettype none

module aligator_main (
    input  wire        clk,            // reloj de la logica del juego (48 MHz)
    input  wire        rst,
    input  wire        game_run,       // 1 = corre; 0 = PAUSA (congela el 68k via cen del dtack)
    input  wire        vblank_irq,     // pulso de vblank -> IRQ6

    // --- ROM de programa del 68000 (1 MB) -> SDRAM ---
    output wire [19:1] prog_addr,      // direccion de WORD
    output wire        prog_cs,
    input  wire [15:0] prog_data,
    input  wire        prog_data_ok,

    // --- puertos de entrada (ya ensamblados por aligator_inputs) ---
    input  wire [15:0] in0, in1, in_coin,

    // --- puerto CPU hacia aligator_vmem (VRAM 64KB + paleta 8KB) ---
    output wire        flip_screen,
    output wire [15:0] vmem_addr,        // direccion de BYTE (addr[15:0])
    output wire        vmem_uds, vmem_lds,
    output wire        vmem_we,
    output wire        vmem_cs_vram,     // 200000-20FFFF  VRAM 64KB
    output wire        vmem_cs_pal,      // 210000-211FFF  paleta 8KB
    output wire [15:0] vmem_wdata,       // dato crudo del bus (gaelco2 no cifra)
    input  wire [15:0] vmem_vram_rdata,
    input  wire [15:0] vmem_pal_rdata,

    // --- registros de vídeo (al motor GAE1) ---
    output wire [15:0] vreg0, vreg1, vreg2,

    // --- sonido GAE1: bus de escritura del 68k + lectura de regs ---
    output wire        sndreg_cs,        // cs_sound (0x202890-0x2028ff)
    output wire        sndreg_we,        // strobe de escritura a los regs de sonido
    input  wire [15:0] snd_rdata,        // lectura de regs (gaelcosnd_r)

    // --- DS5002: firmware (ROM 32KB) servido por BRAM/PROM del game (camino WRally) ---
    input  wire        mcu_cen,          // = clk48/4 = 12 MHz (cristal del DS5002)
    output wire [14:0] mcurom_addr,      // PC del MCU (15b -> firmware 32KB)
    output wire        mcurom_en,
    input  wire [ 7:0] mcurom_data,      // dato del firmware (1 clk después)

    // --- descarga (RUNTIME, desde la .mra) del SCRATCH on-chip del DS5002 (32KB) ---
    //  Mismo download que el PROM del firmware (dallas_*): el wrapper cablea estas señales a
    //  dallas_waddr/dallas_dd/dallas_we. Permite un .rbf distribuible (sin hornear el firmware).
    input  wire        scr_dl_clk,       // dominio del download (= clk del wrapper)
    input  wire [14:0] scr_dl_addr,      // direccion de byte dentro del scratch 32KB
    input  wire [ 7:0] scr_dl_data,      // byte del firmware
    input  wire        scr_dl_we         // strobe de escritura del download
);
    // ===================== fx68k (68000) =====================
    wire [23:1] eab;
    wire        ASn, LDSn, UDSn, eRWn;
    wire [15:0] oEdb;
    reg  [15:0] iEdb;
    wire        DTACKn;
    reg         VPAn;
    wire        FC0, FC1, FC2;
    reg         IPL_n;
    wire [2:0]  fc = {FC2, FC1, FC0};
    wire        cpu_cen, cpu_cenb;

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(cpu_cen), .enPhi2(cpu_cenb),
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(), .VMAn(), .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(DTACKn), .VPAn(VPAn), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        // IRQ6 = nivel 6 = {IPL2n,IPL1n,IPL0n}=001 -> IPL0n=1, IPL2n=IPL1n=~irq_pending.
        .IPL0n(1'b1), .IPL1n(IPL_n), .IPL2n(IPL_n),
        .iEdb(iEdb), .oEdb(oEdb), .eab(eab)
    );

    wire [23:0] addr  = {eab, 1'b0};   // direccion de BYTE (A0 lo dan UDS/LDS)
    wire        uds   = ~UDSn;
    wire        lds   = ~LDSn;
    wire        rw_rd = eRWn;           // 1 = lectura

    // ===================== decodificador de direcciones (gaelco2) =====================
    wire cs_rom, cs_vram, cs_sound, cs_pal, cs_vregs, cs_in0, cs_in1, cs_coin,
         cs_coinw, cs_wram, cs_shram;
    aligator_addr_decode u_dec (
        .addr(addr), .as(~ASn),
        .cs_rom(cs_rom), .cs_vram(cs_vram), .cs_sound(cs_sound), .cs_pal(cs_pal),
        .cs_vregs(cs_vregs), .cs_in0(cs_in0), .cs_in1(cs_in1), .cs_coin(cs_coin),
        .cs_coinw(cs_coinw), .cs_wram(cs_wram), .cs_shram(cs_shram)
    );

    assign prog_addr = eab[19:1];
    assign prog_cs   = cs_rom & rw_rd;
    wire [15:0] rom_word = prog_data;

    // ===================== DTACK (jtframe_68kdtack) =====================
    // Solo la ROM (SDRAM) introduce espera (bus_busy). VRAM/paleta/wram/shram = BRAM 1-ciclo.
    // cens del 68000 CO-GENERADOS con el DTACK. num=1/den=4 -> 12 MHz desde clk=48 MHz.
    wire bus_busy  = cs_rom & rw_rd & ~prog_data_ok;
    wire bus_cs_dt = cs_rom & rw_rd;
    wire dtack_raw;
    aligator_68kdtack #(.W(8)) u_dtack (
        .rst(rst), .clk(clk), .cen_en(game_run),
        .cpu_cen(cpu_cen), .cpu_cenb(cpu_cenb),
        .bus_cs(bus_cs_dt), .bus_busy(bus_busy), .bus_legit(1'b0), .bus_ack(1'b0),
        .ASn(ASn), .DSn({UDSn,LDSn}),
        .num(7'd1), .den(8'd4),
        .wait2(1'b0), .wait3(1'b0),
        .DTACKn(dtack_raw)
    );
    // En IACK (fc==7) el 68000 usa VPAn (autovector), NO DTACK.
    assign DTACKn = (fc == 3'd7) ? 1'b1 : dtack_raw;

    // ===================== vregs (0x218004-0x218009; 3 words) =====================
    // word index = addr[3:1] -> 0x4->2, 0x6->3, 0x8->4. Guardamos [0..7], usamos [2..4].
    reg [15:0] vregs[0:7];
    assign vreg0 = vregs[2]; assign vreg1 = vregs[3]; assign vreg2 = vregs[4];
    // gaelco2 maneja el flip dentro del vídeo; placeholder hasta la fase de vídeo.
    assign flip_screen = 1'b0;

    // ===================== puerto CPU hacia aligator_vmem =====================
    assign vmem_addr    = addr[15:0];
    assign vmem_uds     = uds;
    assign vmem_lds     = lds;
    assign vmem_cs_vram = cs_vram;
    assign vmem_cs_pal  = cs_pal;
    assign vmem_we      = wr_ack & ~rw_rd & (cs_vram | cs_pal);
    assign vmem_wdata   = oEdb;            // gaelco2: dato CRUDO del bus (sin cifrado)
    // sonido GAE1: el módulo de sonido (en el game) usa vmem_addr/uds/lds/wdata + sndreg_we/sndreg_cs
    assign sndreg_cs    = cs_sound;
    assign sndreg_we    = wr_ack & ~rw_rd & cs_sound;

    // ===================== lectura del bus (iEdb) =====================
    always @(*) begin
        iEdb = 16'hFFFF;
        case (1'b1)
            cs_rom:   iEdb = rom_word;
            cs_vram:  iEdb = vmem_vram_rdata;
            cs_pal:   iEdb = vmem_pal_rdata;
            cs_vregs: iEdb = vregs[addr[3:1]];
            cs_in0:   iEdb = in0;
            cs_in1:   iEdb = in1;
            cs_coin:  iEdb = in_coin;
            cs_wram:  iEdb = wram_q;
            cs_shram: iEdb = shram_q;
            cs_sound: iEdb = snd_rdata;    // GAE1 sound regs (gaelcosnd_r)
            default:  iEdb = 16'hFFFF;
        endcase
    end

    // ===================== protocolo de bus + IRQ + escrituras de registros =====================
    reg  asn_d;
    wire wr_ack     = (~ASn) & (~asn_d);           // NIVEL: dato valido (clks tardios del ciclo)

    reg irq_pending;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            asn_d       <= 1'b1;
            VPAn        <= 1'b1;
            irq_pending <= 1'b0;
            IPL_n       <= 1'b1;
        end else begin
            asn_d <= ASn;

            if (vblank_irq) irq_pending <= 1'b1;     // vblank -> arma IRQ6
            IPL_n <= ~irq_pending;

            // VPAn: autovector en IACK
            if (~ASn) VPAn <= (fc == 3'd7) ? 1'b0 : 1'b1;
            else      VPAn <= 1'b1;

            // Escrituras de registros (en el NIVEL wr_ack: idempotente)
            if (wr_ack) begin
                if (fc == 3'd7) begin
                    irq_pending <= 1'b0;             // se reconocio la IRQ (autovector)
                end else if (~rw_rd) begin
                    if (cs_vregs) begin
                        if (uds) vregs[addr[3:1]][15:8] <= oEdb[15:8];
                        if (lds) vregs[addr[3:1]][7:0]  <= oEdb[7:0];
                    end
                    // cs_coinw (0x500000): coin lockout/counters -> ignorado (no afecta a vídeo/CPU).
                    // cs_sound (0x202890): regs de sonido GAE1 -> STUB (fase de sonido).
                end
            end
        end
    end

    // ===================== work RAM 32KB (FE0000-FE7FFF) -> BRAM =====================
    reg [7:0] wram_hi[0:16383], wram_lo[0:16383];
    wire [13:0] wramidx = addr[14:1];
    wire        ww_hi = wr_ack & ~rw_rd & cs_wram & uds;
    wire        ww_lo = wr_ack & ~rw_rd & cs_wram & lds;
    reg  [15:0] wram_q;
    always @(posedge clk) begin
        if (ww_hi) wram_hi[wramidx] <= oEdb[15:8];
        if (ww_lo) wram_lo[wramidx] <= oEdb[7:0];
        wram_q <= {wram_hi[wramidx], wram_lo[wramidx]};
    end

    // ===================== DS5002FP (protección, runtime — camino WRally) =====================
    //  MOVX (xdata) del MCU: 0x8000-0xffff -> RAM COMPARTIDA con el 68k (shram, byte big-endian);
    //  0x0000-0x7fff -> SRAM scratch on-chip (32KB). El firmware (32KB) lo sirve el game vía PROM.
    wire        mcu_xrd, mcu_xwr; wire [15:0] mcu_xaddr; wire [7:0] mcu_xdout; wire [7:0] mcu_xdin;
    wire [15:0] mcu_rom_addr; wire mcu_rom_en;
    aligator_mcu u_mcu (
        .clk(clk), .rst(rst), .cen(mcu_cen),
        .rom_addr(mcu_rom_addr), .rom_en(mcu_rom_en), .rom_byte(mcurom_data),
        .xdata_rd(mcu_xrd), .xdata_wr(mcu_xwr), .xdata_addr(mcu_xaddr),
        .xdata_dout(mcu_xdout), .xdata_din(mcu_xdin)
    );
    assign mcurom_addr = mcu_rom_addr[14:0];   // firmware 32KB
    assign mcurom_en   = mcu_rom_en;

    // decodificación del MOVX
    wire        mcu_sh    = mcu_xaddr[15];           // 0x8000-0xffff -> shram
    wire [13:0] mcu_shidx = mcu_xaddr[14:1];         // word dentro de la shram
    wire        mcu_scr   = ~mcu_xaddr[15];          // 0x0000-0x7fff -> scratch

    // ===================== RAM compartida con DS5002 32KB (FE8000-FEFFFF) -> BRAM TRUE DUAL-PORT =====================
    //  Puerto 0 = 68k (word, uds/lds). Puerto 1 = MCU (byte big-endian: par=alto, impar=bajo).
    //  jtframe_dual_ram (2 instancias hi/lo) -> infiere M10K limpio (el patrón if/else 1W/2R hecho a
    //  mano NO infería -> 256K registros -> overflow del fitter). El árbitro real de la PCB
    //  (74LS245/373) serializa los dos maestros; aquí ambos puertos escriben de forma independiente.
    wire [13:0] shidx = addr[14:1];
    wire        sw_hi = wr_ack & ~rw_rd & cs_shram & uds;
    wire        sw_lo = wr_ack & ~rw_rd & cs_shram & lds;
    wire        mcu_sh_wr_hi = mcu_xwr & mcu_sh & ~mcu_xaddr[0];   // byte alto (par, big-endian)
    wire        mcu_sh_wr_lo = mcu_xwr & mcu_sh &  mcu_xaddr[0];   // byte bajo (impar)
    wire [7:0]  shram_hi_q, shram_lo_q;                            // lectura 68k (hi/lo)
    wire [7:0]  shram_mcu_hi_q, shram_mcu_lo_q;                    // lectura MCU (hi/lo)
    wire [15:0] shram_q = {shram_hi_q, shram_lo_q};
    jtframe_dual_ram #(.AW(14),.DW(8)) u_shram_hi (
        .clk0(clk), .data0(oEdb[15:8]), .addr0(shidx),     .we0(sw_hi),        .q0(shram_hi_q),
        .clk1(clk), .data1(mcu_xdout),  .addr1(mcu_shidx), .we1(mcu_sh_wr_hi), .q1(shram_mcu_hi_q)
    );
    jtframe_dual_ram #(.AW(14),.DW(8)) u_shram_lo (
        .clk0(clk), .data0(oEdb[7:0]),  .addr0(shidx),     .we0(sw_lo),        .q0(shram_lo_q),
        .clk1(clk), .data1(mcu_xdout),  .addr1(mcu_shidx), .we1(mcu_sh_wr_lo), .q1(shram_mcu_lo_q)
    );

    // ===================== SRAM scratch on-chip del DS5002 32KB (MOVX 0x0000-0x7fff) -> BRAM =====================
    //  CAUSA RAÍZ del freeze (2026-06-25, confirmado por oráculo MAME): el firmware lee TABLAS de datos vía
    //  MOVX en el espacio xdata 0x10000-0x17fff, que en el DS5002 es SU PROPIA SRAM (la misma del programa).
    //  El Oregano (16b) emite low-16 = offset de SRAM (0x0000-0x7fff). En MAME esas lecturas devuelven los
    //  bytes del firmware (verificado: xdata 0x11000 = firmware[0x1000]). Antes este scratch era ZERO-INIT ->
    //  el firmware leía ceros -> lógica de gameplay corrupta -> freeze. FIX: cargar el scratch con la
    //  imagen del firmware (mismo dallas.bin/dallas.hex que el PROM del programa). R/W (la SRAM es escribible).
    //  Ver memoria aligator-freeze-causa-raiz-movx-sram. (TODO producción: SRAM única compartida prog+datos.)
    //  CARGA: ya NO se hornea (sin SYNFILE -> no va firmware en el bitstream). En SIM se precarga por SIMFILE
    //  (dallas.bin). En HW se carga en RUNTIME desde la .mra por el PUERTO 1 (scr_dl_*), el mismo download que
    //  alimenta el PROM del firmware (u_prom_dallas) -> .rbf distribuible sin firmware embebido.
    wire [14:0] scridx = mcu_xaddr[14:0];
    wire [7:0]  scratch_q;
    jtframe_dual_ram #(.AW(15),.DW(8),.SIMFILE("dallas.bin")) u_scratch (
        .clk0(clk),        .data0(mcu_xdout),   .addr0(scridx),      .we0(mcu_xwr & mcu_scr), .q0(scratch_q),
        .clk1(scr_dl_clk), .data1(scr_dl_data), .addr1(scr_dl_addr), .we1(scr_dl_we),         .q1()
    );

    // dato leído por el MCU: scratch (<0x8000) o shram (byte alto/bajo según paridad)
    assign mcu_xdin = mcu_scr ? scratch_q :
                      (mcu_xaddr[0] ? shram_mcu_lo_q : shram_mcu_hi_q);

`ifdef ALI_XTRACE
    // DIAG (2026-06-25): histograma de accesos MOVX del MCU por región para localizar el freeze.
    // Compara con MAME (lee xdata 0x10000-0x17fff = SRAM firmware; low-16 = 0x0000-0x7fff = nuestro scratch).
    // ¿Nuestro Oregano emite 0x0000-0x7fff (scratch) o 0x8000-0xffff (host) para las tablas?
    integer xr_lo=0, xr_hi=0, xw_lo=0, xw_hi=0, xsmp=0;
    reg xrd_d=0, xwr_d=0;
    always @(posedge clk) begin
        xrd_d <= mcu_xrd; xwr_d <= mcu_xwr;
        if (mcu_xrd & ~xrd_d) begin                 // flanco de lectura MOVX
            if (mcu_xaddr[15]) xr_hi<=xr_hi+1; else xr_lo<=xr_lo+1;
            if (~mcu_xaddr[15] && xsmp<32) begin
                xsmp<=xsmp+1;
                $display("XTR rd lo [%04x] -> %02x", mcu_xaddr, mcu_xdin);
            end
        end
        if (mcu_xwr & ~xwr_d) begin
            if (mcu_xaddr[15]) xw_hi<=xw_hi+1; else xw_lo<=xw_lo+1;
        end
    end
    // volcado periódico del histograma
    reg [23:0] xtc=0;
    always @(posedge clk) begin
        xtc<=xtc+1;
        if (xtc==24'hFFFFFF) $display("XTR HIST  rd lo(0-7fff)=%0d hi(8000-ffff)=%0d  wr lo=%0d hi=%0d", xr_lo, xr_hi, xw_lo, xw_hi);
    end
`endif


`ifdef SIMULATION
    // DIAGNOSTICO: arranque del 68k + IRQ + vregs.
    reg [31:0] dc=0; integer n_iack=0, n_vbl=0; reg asn_dd=1;
    always @(posedge clk) begin
        dc <= dc + 1; asn_dd <= ASn;
        if (vblank_irq) n_vbl <= n_vbl + 1;
        if ((~ASn) & asn_dd & (fc==3'd7)) n_iack <= n_iack + 1;
        if (dc[20:0]==0) $display("MAINDBG vbl=%0d iack=%0d pc=%h dataacc=%h IPLn=%b vreg=%h,%h,%h",
                                  n_vbl, n_iack, {prog_addr,1'b0}, addr, IPL_n, vregs[2], vregs[3], vregs[4]);
    end
`endif
endmodule

`default_nettype wire
