// ============================================================================
//  World Rally (Gaelco) — "PLACA" sintetizable: 68000 (fx68k) + DS5002 (R8051) +
//  mapa de memoria + protocolo de bus + IRQ6 + RAM compartida + descifrado de VRAM.
//
//  Es la traduccion a RTL PURO de la logica que hoy vive en C++ en
//  `sim/wrally_machine.cpp` (verificada: arranca, POST, handshake DS5002 "Coprocessor
//  OK"). Sustituye al arnes para ir hacia FPGA/MiSTer (BLOQUE 5).
//
//  ESTADO: scaffold estructural. Memorias internas = block-RAM inferida. Las ROMs
//  grandes (prog 1MB, gfx 2MB, OKI 1MB) salen por puertos -> SDRAM en el wrapper.
//  El TIMING de video (H/V, pixel clock) es FASE 1 (pendiente del esquematico): aqui
//  se expone `vblank_irq` como entrada. El datapath de video (VRAM/pal/sprRAM) se
//  cablea fuera (wrally_video + wrally_sprite_engine, ya verificados pixel-exactos).
//
//  Verificacion recomendada: `verilator --lint-only` (estructura) y luego comparar
//  contra el arnes C++ (mismas escrituras VRAM/PAL/SPR) reusando la metodologia previa.
// ============================================================================
`default_nettype none

module wrally_main #(
    // MCU_FULLSPEED=1: el r8051 a cpu_en=1 (full speed) + handshake rom/ram -> el handshake DS5002
    //   COMPLETA (A5 3E). PERO el path critico del r8051 (~26ns) NO cumple 96MHz single-cycle
    //   (el multicycle del SDC asume cen>=4 ciclos, invalido a cpu_en=1) -> NO usar en HW aun.
    // MCU_FULLSPEED=0 (HW): el r8051 a mcu_cen (clk/8) -> timing-limpio (multicycle 2 valido). El
    //   handshake NO completa (limite conocido) pero el R8051 no corrompe (mcu_wr_xdata controlado).
    parameter MCU_FULLSPEED = 1'b1,
    // MCU_STUB=1 (BYPASS v1): NO se usa el r8051 para el handshake; una FSM minima detecta el
    //   wake del 68k (FEF501=01) y escribe la firma A5 3E en FEF500/501 -> el 68k pasa el check
    //   "Coprocessor OK" y dibuja el auto-test. Simplifica el esquema (sin r8051 en el camino del
    //   handshake). El DS5002 REAL (logica de juego) vuelve en v2 con MCU_STUB=0.
    parameter MCU_STUB = 1'b0
) (
    input  wire        clk,            // reloj maestro
    input  wire        rst,            // reset general (alto)
    input  wire        cpu_cen_phi1,   // enable fase 1 del 68000 (12 MHz)
    input  wire        cpu_cen_phi2,   // enable fase 2 del 68000
    input  wire        mcu_cen,        // enable del DS5002 (12 MHz)
    input  wire        oki_cen,        // enable del OKI (1 MHz)

    input  wire        vblank_irq,     // pulso de vblank -> IRQ6 (del timing de video, FASE 1)

    // --- ROM de programa del 68000 (1 MB, c22/c23 interleave) -> SDRAM ---
    output wire [19:1] prog_addr,      // direccion de WORD
    output wire        prog_cs,        // 1 = lectura de ROM de programa (peticion a SDRAM)
    input  wire [15:0] prog_data,
    input  wire        prog_data_ok,   // 1 = prog_data valido para prog_addr (handshake SDRAM)

    // --- ROM interna del DS5002 (wrdallas, 32 KB) -> BRAM/SDRAM ---
    output wire [14:0] mcurom_addr,
    output wire        mcurom_en,        // rom_en del R8051: la lectura de ROM externa DEBE gatearse
    input  wire [7:0]  mcurom_data,      //   por el (BRAM: if(mcurom_en) data<=rom[addr]) -> el core

    // --- ROM de samples del OKI (1 MB) -> SDRAM ---
    output wire [19:0] oki_rom_addr,
    input  wire [7:0]  oki_rom_data,
    input  wire        oki_rom_ok,

    // --- puertos de entrada (joystick/DSW/sistema) ---
    input  wire [15:0] in_dsw,
    input  wire [15:0] in_p1p2,
    input  wire [15:0] in_wheel,
    input  wire [15:0] in_system,

    // --- puerto CPU hacia wrally_vmem (VRAM/paleta/sprite-RAM compartidas con el video) ---
    output wire        flip_screen,
    output wire [13:0] vmem_addr,        // direccion de BYTE (addr[13:0])
    output wire        vmem_uds, vmem_lds,
    output wire        vmem_we,          // strobe de escritura (commit de bus)
    output wire        vmem_cs_vram, vmem_cs_pal, vmem_cs_spr,
    output wire [15:0] vmem_vram_wdata,  // dato a VRAM (ya DESCIFRADO)
    output wire [15:0] vmem_io_wdata,    // dato a paleta/sprite (del bus)
    input  wire [15:0] vmem_vram_rdata,  // lectura de VRAM (descifrada) para el bus
    input  wire [15:0] vmem_pal_rdata,
    input  wire [15:0] vmem_spr_rdata,
    output wire [15:0] vreg0, vreg1, vreg2, vreg3,

    // --- salida de audio (del OKI) ---
    output wire signed [13:0] sound,
    output wire        snd_sample,   // strobe de sample-rate REAL del OKI (jt6295.sample) -> resampler jtframe

    // --- DEBUG HW: visibilidad del handshake del MCU por el UART (no afecta a la logica) ---
    output wire [15:0] dbg_firma,    // ultimo word escrito a wram[0x1A80] (=A53E si el MCU completa)
    output wire [7:0]  dbg_mcu_act,  // contador saturante de escrituras xdata del MCU (=0 -> MCU no corre)
    // --- TELEMETRIA PAGINADA (read-only): pagina 3 (r8051/Dallas) y 4 (handshake wram) ---
    output wire [15:0] dbg_mcu_pc,     // PC del r8051 AHORA (mcu_rom_addr, 16b para ver derail >0x7FFF)
    output wire [15:0] dbg_mcu_pcmax,  // PC max alcanzado por el r8051
    output wire [15:0] dbg_mcu_fetch,  // nº de fetches de ROM del r8051 (sat)
    output wire [ 7:0] dbg_rd0, dbg_rd1, dbg_rd2, dbg_rd3, // bytes que el r8051 CONSUME en addr 0/1/2/3 (¿02 01 00 02?)
    output wire [15:0] dbg_mcu_oor,    // primer PC del r8051 FUERA de rango (>0x7FFF) -> derail
    output wire [13:0] dbg_mcu_wradr,  // ultima direccion-WORD xdata escrita por el MCU (mcu_wr_addr[14:1]; 0x1A80=handshake)
    output wire [ 7:0] dbg_mcu_wrby,   // ultimo byte xdata escrito por el MCU
    output wire [15:0] dbg_mcu_coll,   // nº de writes del MCU DESCARTADOS por colision con el 68k (sat)
    output wire [ 7:0] dbg_1a80_mcu,   // wram[0x1A80] lado MCU (byte bajo)
    output wire [ 7:0] dbg_1a80_cpu,   // wram[0x1A80] lado 68k (byte bajo)
    // --- LECTURAS del MCU (oraculo: el r8051 barre xdata al arrancar; ¿avanza el barrido en HW?) ---
    output wire [15:0] dbg_mcu_rdmax,  // direccion xdata MAX leida por el MCU (extension del barrido)
    output wire [15:0] dbg_mcu_rdadr,  // ultima direccion xdata leida por el MCU
    output wire [ 7:0] dbg_mcu_rdby,   // ultimo byte que el MCU leyo de xdata
    output wire [15:0] dbg_mcu_nrd,    // nº de lecturas xdata del MCU (sat) -> ¿pollea activo?
    output wire [13:0] dbg_68k_wradr,  // ultima direccion-WORD que el 68k escribio en la wram
    output wire [ 7:0] dbg_68k_wrby,   // ultimo byte que el 68k escribio en la wram
    output wire        dbg_68k_w01,    // PEGAJOSO: el 68k escribio ALGUNA VEZ 0x01 en 0x1A80.lo (=wake)
    // --- 68k PROFUNDO: separa fetch de data + cuenta entradas a handlers (localizar el bucle/excepcion) ---
    output wire [23:0] dbg_68k_fpc,    // ultima direccion de FETCH de instruccion (FC=prog) -> donde EJECUTA
    output wire [23:0] dbg_68k_dacc,   // ultima direccion de DATA (FC=data) -> donde LEE datos
    output wire [15:0] dbg_68k_flow,   // nº fetches en 0x40-0x70 (zona vectores) -> ¿ejecuta en los vectores?
    output wire [15:0] dbg_68k_iack,   // nº ciclos IACK (FC=7) -> ¿toma interrupciones/excepciones?
    output wire [15:0] dbg_68k_h400,   // nº fetches en 0x400-0x410 (handler rte catch-all) -> tormenta excepcion
    output wire [15:0] dbg_68k_exc,    // nº fetches en 0x530-0x590 (handlers bus/addr/illegal/...)
    // --- CAJA NEGRA de excepcion: los handlers guardan exc# en $FEC04C y el PC que fallo en $FEC048 ---
    output wire [ 7:0] dbg_exc_num,    // nº de la PRIMERA excepcion (2=bus 3=addr 4=illegal 5=div0 6=CHK 7=TRAPV 8=priv)
    output wire [23:0] dbg_fault_pc,   // PC que FALLO en la primera excepcion ($FEC048) -> la instruccion culpable
    output wire [23:0] dbg_fault_pcl,  // PC que fallo en la ULTIMA excepcion (donde esta atascado ahora)
    output wire [23:0] dbg_68k_fault1, // PC culpable DIRECTO del bus (ultimo codigo real antes de la 1a excepcion)
    // --- RESET VECTOR tal como lo RECIBE el 68k de la SDRAM (¿le entra el dato correcto?) ---
    output wire [23:0] dbg_rst_sp,     // SP leido en SDRAM 0x0-0x3 (deberia 0x(00)FEFF80)
    output wire [23:0] dbg_rst_pc,     // PC leido en SDRAM 0x4-0x7 (deberia 0x002400) <- el dato de ENTRADA clave
    output wire [23:0] dbg_first_fetch // primer fetch de instruccion del 68k (¿0x2400 = arranca bien, o bajo = corrupto?)
);

    // ===================== fx68k (68000) =====================
    wire [23:1] eab;
    wire        ASn, LDSn, UDSn, eRWn;
    wire [15:0] oEdb;
    reg  [15:0] iEdb;
    wire        DTACKn;          // generado por jtframe_68kdtack (abajo)
    reg         VPAn;
    wire        FC0, FC1, FC2;
    reg         IPL2n;
    wire [2:0]  fc = {FC2, FC1, FC0};

    fx68k u_cpu (
        .clk(clk), .HALTn(1'b1),
        .extReset(rst), .pwrUp(rst),
        .enPhi1(cpu_cen), .enPhi2(cpu_cenb),    // cens co-generados por wrally_68kdtack
        .eRWn(eRWn), .ASn(ASn), .LDSn(LDSn), .UDSn(UDSn),
        .E(), .VMAn(), .FC0(FC0), .FC1(FC1), .FC2(FC2),
        .BGn(), .oRESETn(), .oHALTEDn(),
        .DTACKn(DTACKn), .VPAn(VPAn), .BERRn(1'b1),
        .BRn(1'b1), .BGACKn(1'b1),
        // IRQ6 = nivel 6 = ~IPL 110b -> IPL2n=0, IPL1n=0, IPL0n=1. El reg `IPL2n`
        // vale ~irq_pending; atamos IPL1n al MISMO reg (antes estaba fijo a 1 = nivel 4, BUG).
        .IPL0n(1'b1), .IPL1n(IPL2n), .IPL2n(IPL2n),
        .iEdb(iEdb), .oEdb(oEdb), .eab(eab)
    );

    // direccion de BYTE (A0 lo dan UDS/LDS)
    wire [23:0] addr = {eab, 1'b0};
    wire        uds  = ~UDSn;
    wire        lds  = ~LDSn;
    wire        rw_rd = eRWn;        // 1 = lectura

    // ===================== decodificador de direcciones =====================
    wire cs_rom, cs_vram, cs_vregs, cs_clrint, cs_pal, cs_spr,
         cs_dsw, cs_p1p2, cs_wheel, cs_system, cs_outlatch, cs_okibank, cs_oki, cs_wram;
    wrally_addr_decode u_dec (
        .addr(addr), .as(~ASn),
        .cs_rom(cs_rom), .cs_vram(cs_vram), .cs_vregs(cs_vregs), .cs_clrint(cs_clrint),
        .cs_pal(cs_pal), .cs_spr(cs_spr), .cs_dsw(cs_dsw), .cs_p1p2(cs_p1p2),
        .cs_wheel(cs_wheel), .cs_system(cs_system), .cs_outlatch(cs_outlatch),
        .cs_okibank(cs_okibank), .cs_oki(cs_oki), .cs_wram(cs_wram)
    );

    // ===================== memorias internas (block-RAM) =====================
    // VRAM/paleta/sprite-RAM viven en wrally_vmem (compartidas con el video). vregs es local.
    reg [15:0] vregs[0:3];
    // RAM compartida 16 KB como WORDS de 16b (par=alto, impar=bajo). UN puerto de
    // escritura arbitrado (68k > MCU). REPLICADA en 2 copias (CPU/MCU) con lectura
    // REGISTRADA cada una (1W/1R) -> infiere BRAM (patron Galaxian C). La latencia de 1
    // ciclo la esconde el cen del 68000 (clk/8) y la registra del MCU, sin wait-states.
    // REFACTOR 2026-06-17: la wram pasa a UN jtframe_dual_ram16 (dual-PORT real, patron biocom = 68k+MCU
    // +RAM compartida). Antes eran 2 copias hand-rolled (wram_cpu/wram_mcu) escritas a mano + escritura
    // ARBITRADA -> no estandar; en HW el MCU leia datos malos de la wram (V.037: barrido xdata atascado en
    // 0x2399, lee distinto a sim). El dual-port real = 1 BRAM, 2 puertos -> coherente por construccion +
    // sin arbitraje (cada puerto escribe). La instancia esta mas abajo (tras definir mcu_src_*).
    reg  [7:0]  mcu_dram [0:255];
    wire [15:0] wram_cpu_q;           // lectura 68k  = puerto 0 (q0) del dual_ram, CON write-forward
    wire [15:0] wram_mcu_q16;         // lectura MCU  = puerto 1 (q1) del dual_ram, CON write-forward
    wire [15:0] wram_cpu_q_raw;       // q0 CRUDO (posible basura en colisión read-during-write)
    wire [15:0] wram_mcu_q16_raw;     // q1 CRUDO

    assign prog_addr = eab[19:1];           // ROM 1 MB (word)
    assign prog_cs   = cs_rom & rw_rd;      // peticion de lectura de ROM a la SDRAM
    wire [15:0] rom_word = prog_data;

    // ===================== DTACK (jtframe_68kdtack, patron canonico) =====================
    // Sustituye al DTACK hand-rolled. El `wait1` interno da 1 ciclo a `bus_busy` para conmutar
    // -> elimina la CARRERA del `ok` RANCIO del slot SDRAM (que mantenia ok=1 con el dato de la
    // direccion ANTERIOR 1 ciclo tras cambiar de addr). Sin esto la CPU latcheaba la palabra N-1
    // al leer la N (reset vector roto). El wait1 fijo (1 ciclo) cubre tambien la BRAM (vmem/wram).
    // bus_busy: solo la ROM (SDRAM) necesita espera extra hasta prog_data_ok.
    // cens del 68000 CO-GENERADOS con el DTACK (sincronizados): clave para muestrear el
    // dato FRESCO del slot. num=1/den=4 -> 12 MHz desde clk=48 MHz. cpu_cen->enPhi1,
    // cpu_cenb->enPhi2 (abajo). Los puertos cpu_cen_phi1/phi2 quedan sin usar para el 68k.
    wire cpu_cen, cpu_cenb;
    wire bus_busy  = cs_rom & rw_rd & ~prog_data_ok;
    wire bus_cs_dt = cs_rom & rw_rd;     // acceso "lento" (SDRAM) para recuperacion de ciclos
    wire dtack_raw;
    wrally_68kdtack #(.W(8)) u_dtack (
        .rst(rst), .clk(clk),
        .cpu_cen(cpu_cen), .cpu_cenb(cpu_cenb),
        .bus_cs(bus_cs_dt), .bus_busy(bus_busy), .bus_legit(1'b0), .bus_ack(1'b0),
        .ASn(ASn), .DSn({UDSn,LDSn}),
        .num(7'd1), .den(8'd4),
        .wait2(1'b0), .wait3(1'b0),
        .DTACKn(dtack_raw)
    );
    // En IACK (fc==7) el 68000 usa VPAn (autovector), NO DTACK -> forzamos DTACKn=1 ahi.
    assign DTACKn = (fc == 3'd7) ? 1'b1 : dtack_raw;

`ifdef SIMULATION
    // Traza CICLO-A-CICLO del primer acceso a ROM (handshake addr/cs/ok/data/DTACK/cen).
    integer dbgc=0; reg started=0, rst_was_high=0;
    always @(posedge clk) begin
        if (rst) rst_was_high <= 1'b1;   // marca que hubo pulso de reset
        // empezar a trazar SOLO tras liberarse el reset (rst_was_high && ~rst), en el 1er acceso a ROM
        if (!started && rst_was_high && ~rst && cs_rom && rw_rd) started <= 1'b1;
        if (started && dbgc < 60) begin
            $display("T%0d rst=%b ASn=%b fc=%0d cs=%b paddr=%h pok=%b pdata=%h busy=%b buscs=%b draw=%b DTACKn=%b cen=%b",
                     dbgc, rst, ASn, fc, cs_rom&rw_rd, {prog_addr,1'b0}, prog_data_ok, prog_data, bus_busy, bus_cs_dt, dtack_raw, DTACKn, cpu_cen);
            dbgc <= dbgc + 1;
        end
    end
`endif

    assign vreg0 = vregs[0]; assign vreg1 = vregs[1];
    assign vreg2 = vregs[2]; assign vreg3 = vregs[3];

    // puerto CPU hacia wrally_vmem (combinacional; vmem registra la escritura en vmem_we)
    assign vmem_addr       = addr[13:0];
    assign vmem_uds        = uds;
    assign vmem_lds        = lds;
    assign vmem_cs_vram    = cs_vram;
    assign vmem_cs_pal     = cs_pal;
    assign vmem_cs_spr     = cs_spr;
    assign vmem_we         = wr_ack & ~rw_rd & (cs_vram | cs_pal | cs_spr);
    assign vmem_vram_wdata = dec_word;      // VRAM se escribe DESCIFRADA
    assign vmem_io_wdata   = oEdb;           // paleta/sprite con el dato del bus

    // ===================== descifrado de VRAM (16/32-bit por BUS) =====================
    // Detecta el 2o word de un move.l: dos escrituras a VRAM en words consecutivos.
    wire [15:0] dec_word;
    reg  [15:0] vdec_last_enc, vdec_last_dec;
    reg  [12:0] vdec_prev_woff;     // word offset previo escrito a VRAM
    reg         vdec_prev_wr;
    // Commit de la cadena DIFERIDO a as_rising: latcheamos los candidatos durante el ciclo
    // (estables, porque vdec_prev_* ya NO se confirman a mitad de ciclo) y los aplicamos al
    // final. Asi is2nd (vivo) e dec_word quedan ESTABLES toda la escritura -> la VRAM (nivel)
    // guarda el dato encadenado correcto. (FIX 2026-06-15: el commit en el nivel invertia is2nd.)
    reg  [12:0] pend_woff;
    reg  [15:0] pend_enc, pend_dec;
    reg         pend_is2nd, pend_vramwr;
    wire [12:0] cur_woff = addr[13:1];
    wire        is2nd = vdec_prev_wr & (vdec_prev_woff == (cur_woff - 13'd1));
    // is2nd_lat: is2nd LATCHEADO al inicio del ciclo (as_falling). Asi el descifrado y el commit
    // usan un is2nd ESTABLE toda la escritura, aunque el commit de la cadena (vdec_prev_*) ocurra
    // a mitad del ciclo de nivel. Sin esto, vdec_prev_woff<=cur_woff invertia is2nd y la VRAM
    // guardaba el dato fresco (mal) en vez del encadenado. (FIX 2026-06-15.)
    reg         is2nd_lat = 1'b0;
    wrally_vram_decrypt u_decrypt (
        .enc_prev(is2nd ? vdec_last_enc : 16'd0),
        .dec_prev(is2nd ? vdec_last_dec : 16'd0),
        .enc(oEdb),
        .dec(dec_word)
    );
`ifdef SIMULATION
    // DECDBG: traza la cadena de descifrado en cada escritura VRAM (woff, enc, is2nd, dec).
    integer ndec=0;
    always @(posedge clk) if (!rst) begin
        if (wr_ack && cs_vram && ~rw_rd) begin ndec = ndec + 1;
            if (ndec<60) $display("DEC #%0d woff=%h enc=%h is2nd=%b prevwoff=%h prevwr=%b -> dec=%h",
                                  ndec, cur_woff, oEdb, is2nd, vdec_prev_woff, vdec_prev_wr, dec_word); end
    end
`endif

    // ===================== lectura del bus (iEdb) =====================
    always @(*) begin
        iEdb = 16'hFFFF;
        case (1'b1)
            cs_rom:   iEdb = rom_word;
            cs_vram:  iEdb = vmem_vram_rdata;                // VRAM se LEE descifrada (de vmem)
            cs_pal:   iEdb = vmem_pal_rdata;
            cs_spr:   iEdb = vmem_spr_rdata;
            cs_vregs: iEdb = vregs[addr[2:1]];
            cs_wram:  iEdb = wram_cpu_q;                     // word de 16b (lectura registrada)
            cs_dsw:   iEdb = in_dsw;
            cs_p1p2:  iEdb = in_p1p2;
            cs_wheel: iEdb = in_wheel;
            cs_system:iEdb = in_system;
            cs_oki:   iEdb = {8'hFF, oki_dout};
            default:  iEdb = 16'hFFFF;
        endcase
    end

    // === TEST CONTROLES (solo-sim): traza cuando el 68k LEE P1_P2 (0x700002: coin/start) y cuando ESCRIBE
    //     el OUTLATCH (0x70000b: contadores de moneda/lockout = "el 68k actuó sobre la I/O"). Confirma que la
    //     moneda inyectada (jtwrally_game) llega al 68k y la procesa. coin1=bit6, start1=bit14 (0=pulsado). ===
    // synthesis translate_off
    reg csp_d=0, cso_d=0;
    always @(posedge clk) begin
        csp_d <= cs_p1p2;
        if (cs_p1p2 & ~csp_d)
            $display("[CTRL rd P1_P2] in_p1p2=%04X  coin1(b6)=%b coin2(b7)=%b start1(b14)=%b  (0=pulsado)",
                     in_p1p2, in_p1p2[6], in_p1p2[7], in_p1p2[14]);
        cso_d <= cs_outlatch;
        if (cs_outlatch & ~cso_d)
            $display("[CTRL wr OUTLATCH] addr=%06X data=%04X  <- el 68k ACTUO sobre la I/O (coin counter/lockout)",
                     {addr,1'b0}, oEdb);
    end
    // synthesis translate_on

    // ===================== protocolo de bus + IRQ + escrituras =====================
    reg asn_d, asn_dd;
    wire as_falling = (~ASn) & asn_d;   // ASn paso de 1 a 0 (inicio de ciclo)
    wire as_rising  = ASn & (~asn_d);   // fin de ciclo
    // COMMIT de escritura: ciclo de AS-BAJO ya reconocido (tras el wait-state). Pulso UNICO
    // (1 ciclo) y, lo critico, con ASn=0 -> los cs_xxx (gated por as=~ASn) SON validos aqui.
    // (Antes se commiteaba en as_rising, con ASn=1 -> todos los cs valian 0 -> NINGUNA
    //  escritura del 68000 se ejecutaba: pila/VRAM/vregs/wram mudas -> crash de arranque.)
    wire wr_ack = (~ASn) & (~asn_d);   // NIVEL: las escrituras (VRAM/wram/etc) usan dato valido (clks tardios)

    reg irq_pending;
    // IRQ6: el reg `IPL2n` = ~irq_pending y se cablea a IPL2n e IPL1n (IPL0n=1) en la
    // instancia de fx68k -> {IPL2n,IPL1n,IPL0n} = irq_pending ? 3'b001 : 3'b111 (nivel 6/0).

    // strobes hacia iolatch/oki
    reg outlatch_stb, okibank_stb, oki_wr_stb;
    reg [7:0] bus_lo;        // byte bajo del dato del 68000 (para registros de 8 bits)

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            asn_d         <= 1'b1;
            asn_dd        <= 1'b1;
            is2nd_lat     <= 1'b0;
            VPAn          <= 1'b1;
            irq_pending   <= 1'b0;
            IPL2n         <= 1'b1;
            vdec_prev_wr  <= 1'b0;
            vdec_prev_woff<= 13'd0;
            vdec_last_enc <= 16'd0;
            vdec_last_dec <= 16'd0;
            pend_woff     <= 13'd0;
            pend_enc      <= 16'd0;
            pend_dec      <= 16'd0;
            pend_is2nd    <= 1'b0;
            pend_vramwr   <= 1'b0;
            outlatch_stb  <= 1'b0;
            okibank_stb   <= 1'b0;
            oki_wr_stb    <= 1'b0;
        end else begin
            asn_d        <= ASn;
            asn_dd       <= asn_d;
            if (as_falling) is2nd_lat <= is2nd;   // latch is2nd al inicio del ciclo (estable toda la escritura)
            outlatch_stb <= 1'b0;
            okibank_stb  <= 1'b0;
            oki_wr_stb   <= 1'b0;

            // vblank -> arma IRQ6
`ifdef DBG_NOIRQ
            if (1'b0) irq_pending <= 1'b1;   // DIAGNOSTICO sim: vblank IRQ deshabilitada
`else
            if (vblank_irq) irq_pending <= 1'b1;
`endif
            IPL2n <= ~irq_pending;     // (ver nota arriba: IPL1n=0 cableado en el wrapper)

            // VPAn (autovector en IACK). El DTACKn lo genera jtframe_68kdtack (arriba).
            if (~ASn) begin
                if (fc == 3'd7) VPAn <= 1'b0;   // IACK -> autovector
                else            VPAn <= 1'b1;
            end else begin
                VPAn <= 1'b1;
            end

            // Escrituras de registros (vregs/clrint/I-O): en el NIVEL (idempotente / strobes).
            if (wr_ack) begin
                if (fc == 3'd7) begin
                    irq_pending <= 1'b0;          // se reconocio la IRQ (autovector)
                end else if (~rw_rd) begin        // escritura
                    if (cs_vregs) begin
                        if (uds) vregs[addr[2:1]][15:8] <= oEdb[15:8];
                        if (lds) vregs[addr[2:1]][7:0]  <= oEdb[7:0];
                    end
                    if (cs_clrint) irq_pending <= 1'b0;   // CLR INT video
                    if (cs_outlatch) outlatch_stb <= 1'b1;
                    if (cs_okibank)  okibank_stb  <= 1'b1;
                    if (cs_oki)      oki_wr_stb   <= 1'b1;
                    bus_lo <= oEdb[7:0];
                end
            end
            // --- Cadena de descifrado de VRAM: latch durante el ciclo (vdec_prev_* estables ->
            //     is2nd y dec_word estables), commit UNA vez en as_rising (fin de ciclo). ---
            if (~ASn) begin
                pend_woff   <= cur_woff;
                pend_enc    <= oEdb;
                pend_dec    <= dec_word;
                pend_is2nd  <= is2nd;
                pend_vramwr <= (~rw_rd) & cs_vram;
            end
            if (as_rising) begin
                if (pend_vramwr) begin
                    // Cadena CONTINUA (= MAME gaelco_decrypt): encadena TODOS los words consecutivos
                    // de la misma rafaga (MOVEM/MOVE.L). NO romper tras el 2o word (eso rompia el
                    // relleno de fondo por MOVEM a partir del 3er word). La cadena se rompe sola con
                    // un fetch/lectura entre instrucciones (rama else -> vdec_prev_wr<=0). (FIX 2026-06-15.)
                    vdec_prev_wr   <= 1'b1;
                    vdec_prev_woff <= pend_woff;
                    vdec_last_enc  <= pend_enc;
                    vdec_last_dec  <= pend_dec;
                end else begin
                    vdec_prev_wr <= 1'b0;            // lectura o escritura no-VRAM: rompe cadena
                end
            end
        end
    end

    // ===================== LS259 + banco OKI =====================
    wire [3:0] okibank;
    wrally_iolatch u_iolatch (
        .clk(clk), .reset(rst),
        .cs_outlatch(outlatch_stb), .outlatch_a(addr[6:4]), .outlatch_d0(bus_lo[0]),
        .outlatch(),
        .cs_okibank(okibank_stb), .okibank_in(bus_lo[3:0]), .okibank(okibank),
        .flip_screen(flip_screen)
    );

    // ===================== OKI MSM6295 (jt6295 via glue) =====================
    wire [7:0] oki_dout;
    wrally_oki u_oki (
        .clk(clk), .rst(rst), .cen(oki_cen),
        .cs_oki(oki_wr_stb), .rwn(1'b0), .din(bus_lo), .dout(oki_dout),
        .okibank(okibank),
        .sample_addr(oki_rom_addr), .sample_data(oki_rom_data), .sample_ok(oki_rom_ok),
        .sound(sound), .sample_tick(snd_sample)
    );

`ifdef SIMULATION
    // Traza del CHECKSUM del 68000 (loop 0x2714: ADD.W (A0)+,D1). Captura la trayectoria de la
    // direccion de lectura de ROM (A0 = prog_addr cuando NO es fetch del loop 0x138x word) por
    // ventanas: max de A0 por ventana de 2^20 clks -> ver si barre 0..0x100000 o se atasca.
    // CAP: cuando el checksum (A0 alto) es interrumpido y el PC cae a la zona de vector/handler,
    // captura los siguientes ~90 ciclos de bus (addr+rw+cs) -> ver entrada al IRQ, handler, RTE y
    // a donde RETORNA (0x2704=reinicio del checksum / 0x2714=continuar).
    // Push de excepcion (PC de retorno) y pop del RTE en la cima de pila (feff7a-7e = word 0x1FBD-0x1FBF).
    // Si el PUSH (PC interrumpido, ~0x2714 del checksum) != POP (lo que el RTE recupera) -> lectura de
    // pila rota. dtn_d para edge de DTACK (dato de lectura valido).
    // EXC: cuenta excepciones del 68000 por tipo. Detecta la ENTRADA al handler = salto
    // discontinuo del PC (prog_addr) a una direccion de handler conocida (no secuencial).
    // Handlers (byte->word): buserr 0x536->0x29B, addrerr 0x544->0x2A2, trace 0x24->0x2396->0x11CB,
    // lineA 0x2300->0x1180, lineF 0x2306->0x1183, level6 0x2330->0x1198.
    // IRQDBG: instrumenta DIRECTAMENTE el camino del IRQ por nombre de señal.
    //  - vblank_irq: flanco de subida (pulsos por frame del timing de video)
    //  - irq_pending: flanco de subida (cuantas veces se ARMA la IRQ)
    //  - fc==7: ciclo IACK (la IRQ se TOMA de verdad) -> con prog_addr (PC del fetch siguiente)
    //  - CKRST: prog_addr alto (>0x70000 word=checksum casi al final) y cae a <0x800 (reinicio)
    reg [31:0] dbg_clkn=0; reg vbi_d=0, irqp_d=0, fc7_d=0; reg [18:0] pamax=0;
    integer n_vbi=0, n_irqarm=0, n_iack=0, n_ckrst=0;
    always @(posedge clk) if (!rst) begin
        dbg_clkn <= dbg_clkn + 1;
        vbi_d <= vblank_irq; irqp_d <= irq_pending; fc7_d <= (fc==3'd7);
        if (vblank_irq & ~vbi_d)   begin n_vbi=n_vbi+1;       if(n_vbi<=12)   $display("IRQDBG vblank_irq #%0d clk=%0d", n_vbi, dbg_clkn); end
        if (irq_pending & ~irqp_d) begin n_irqarm=n_irqarm+1; if(n_irqarm<=12)$display("IRQDBG irq_ARM   #%0d clk=%0d", n_irqarm, dbg_clkn); end
        if ((fc==3'd7) & ~fc7_d)   begin n_iack=n_iack+1;     if(n_iack<=20)  $display("IRQDBG IACK(fc7) #%0d clk=%0d pa=%h", n_iack, dbg_clkn, {prog_addr,1'b0}); end
        // reinicio checksum
        if (prog_addr > pamax) pamax <= prog_addr;
        if (pamax > 19'h70000 && prog_addr < 19'h800) begin n_ckrst=n_ckrst+1; if(n_ckrst<=12) $display("IRQDBG CKRST #%0d clk=%0d (pamax llego a %h)", n_ckrst, dbg_clkn, {pamax,1'b0}); pamax<=0; end
    end
`endif

    // ===================== DS5002FP (R8051) =====================
    wire        mcu_rom_en, mcu_rd_data, mcu_rd_sfr, mcu_rd_xdata;
    wire        mcu_dbg_work_en, mcu_dbg_rom_wait, mcu_dbg_rd_wait;   // DEBUG V.057: estado de stall del r8051
    reg  [15:0] mcu_stall_cnt = 16'd0;                                // ciclos consecutivos con el core parado
    wire [15:0] mcu_rom_addr, mcu_rd_addr, mcu_wr_addr;
    wire        mcu_wr_data, mcu_wr_sfr, mcu_wr_xdata;
    wire [7:0]  mcu_wr_byte;
    reg  [7:0]  mcu_rd_byte;

    assign mcurom_addr = mcu_rom_addr[14:0];
    // ROM externa SIEMPRE gateada por rom_en (parte del handshake). FIX 2026-06-13: el handshake
    // funciona TAMBIEN a clk/8 (verificado en tb_ds5002_cen: el MCU ejecuta wrdallas y escribe la
    // firma A5/3E). Antes a MCU_FULLSPEED=0 se usaba mcurom_en=1 + vld constante -> el core desbocaba.
    assign mcurom_en   = mcu_rom_en;
    // El core r8051 EXIGE el handshake de ROM: rom_vld debe seguir a rom_en (1 ciclo, = la lectura
    // registrada de la ROM externa). Con rom_vld=1 constante el core no espera -> lee stale -> se
    // DESBOCA ejecutando bytes desalineados (lo que rompia el handshake DS5002). Verificado con el
    // arnes tb_ds5002 y wrally_mcu_min: con este handshake + ROM gateada por rom_en el core ejecuta
    // wrdallas LIMPIO.
    // rom_vld sigue a rom_en con N ciclos = la LATENCIA de la lectura de la BRAM wrdallas (el r8051
    // RETIENE addr durante el wait, asi que vld es la latencia neta). vld CONDICIONAL (mismo patron que
    // MCU_FULLSPEED) porque la latencia REAL difiere sim vs HW:
    //   - SIM (vld@1): el prom Verilator + relatch se comporta ~1 clk48 -> vld@1 da el handshake a53e
    //     (VALIDADO 2026-06-17; vld@3 ROMPE el sim: el r8051 lee rancio -> firma=0000).
    //   - HW  (vld@3): la BRAM real M9K (clk96) + relatch (clk48) tarda ~2 clk48 -> vld@1 muestrea
    //     ANTES de que el dato este listo -> el r8051 lee rancio -> firma!=a53e (V.031: 2704 con vld@1
    //     PESE a contenido CORRECTO via SYNHEX, .mif=02 01 00). vld@3 espera a que el dato cuaje.
    // OJO: el contenido de la BRAM ya es CORRECTO en HW (SYNHEX); esto es SOLO timing de lectura.
    // vld CONDICIONAL (sim@1 / HW@3): a cen PLENO (FS=1, la estrategia HW) el r8051 EJECUTA (V.033:
    // mcuact=4, ya no se atasca como en FS=0), pero en HW el dato tarda: BRAM real M9K (clk96, 1 ciclo)
    // + relatch (clk48, 1 ciclo) ≈ 2 clk48 -> con vld@1 el r8051 muestrea ANTES del dato -> lee rancio
    // -> descarrila tras unas instrucciones (V.033: firma=2704). vld@3 le da margen (espera a que cuaje).
    // En SIM el prom de Verilator es ~rapido -> vld@1 da a53e y vld@3 lo ROMPE (firma=0000) -> condicional.
    // vld@1 UNCONDICIONAL (sim y HW). Con la BRAM wrdallas reclocada a clk48 (mismo dominio que el r8051,
    // ver jtwrally_game) YA NO hay cruce clk96->clk48 -> el dato es mem[addr] a 1 clk48 -> vld@1 casa en
    // AMBOS. (El vld condicional sim@1/HW@3 ya no hace falta: era para tapar la latencia/CDC del path clk96.)
    reg mcurom_vld;
    always @(posedge clk) mcurom_vld <= mcu_rom_en;

    // SFR del MCU: puertos = 0xFF, resto 0 (suficiente para el handshake)
    function [7:0] mcu_sfr_read(input [15:0] a);
        case (a[7:0])
            8'h80, 8'h90, 8'hA0, 8'hB0: mcu_sfr_read = 8'hFF;
            default:                    mcu_sfr_read = 8'h00;
        endcase
    endfunction

    // lectura del MCU (latencia fija 1 ciclo, como el core espera).
    // wram_mcu va a un REGISTRO DEDICADO (-> infiere altsyncram/BRAM, no 131K FF); las
    // otras fuentes (sfr/dram/rom) y el selector se registran 1 ciclo para alinear, y el
    // mux final es COMBINACIONAL tras los registros: misma latencia neta, sin extra cycle.
    // MISMO patron que wram_cpu_q (que SI infirio en A&S #8): cada array (hi/lo) va a su
    // propio registro de salida via CONCATENACION (no mux) -> infiere altsyncram. El mux
    // de byte (par/impar) se hace DESPUES, combinacional, con el selector alineado 1 ciclo.
    // NOTA clk/8: estos dos van CADA clk (NO gateados): dependen de mcu_rd_addr, que esta HELD durante
    // el stall del MCU a clk/8, asi que se asientan a la direccion correcta y captan los updates que el
    // 68000 escribe en la wram. (Gatearlos congelaba un addr0 sin asentar -> byte equivocado en la
    // seleccion par/impar -> el wake 0x3501 se leia como el byte ALTO=00 en vez del BAJO=01.)
    wire       mcu_rd_any = mcu_rd_data | mcu_rd_sfr | mcu_rd_xdata;
    reg        mcu_rd_addr0_q;        // bit0 de la addr de lectura registrado (para el mux par/impar)
    always @(posedge clk) mcu_rd_addr0_q <= mcu_rd_addr[0];

    // LECTURA del MCU (byte par/impar del word del dual_ram). Base estable V.038-V.060 (arranca a A53E).
    // NOTA: el freeze de 2:53 = colisión read-during-write 68k/MCU en la BRAM M9K (solo HW). Intentos de fix
    // en el camino de lectura (forwarding V.060, "safe-read" V.061) NO valen: el V.061 ROMPIÓ el handshake
    // (firma=0001, "Coprocessor Not Ready") porque retener el último valor limpio sirve dato RANCIO de OTRA
    // dirección cuando el MCU BARRE (boot/checksum) -> reproducible en SIM (frame ~58). El fix correcto es el
    // ÁRBITRO LITERAL (multiplexar el BUS por turnos de tiempo en 1 puerto, como los 74LS) -> ver memoria
    // wrally-fidelidad-placa-objetivo. Banco de pruebas: el handshake (firma A53E) DEBE seguir OK en sim.
    wire [7:0] wram_mcu_q = mcu_rd_addr0_q ? wram_mcu_q16[7:0]    // impar=bajo  (q1 del dual_ram)
                                           : wram_mcu_q16[15:8];  // par=alto
    reg [7:0] mcu_nonram_q;                     // sfr / dram / codigo (registrado al leer)
    reg       mcu_sel_xdata;                    // ¿la fuente fue xdata (wram)?
    always @(posedge clk) if (mcu_rd_any) begin // FIX clk/8: gateado por read_en (mantiene hasta consumir)
        mcu_sel_xdata <= mcu_rd_xdata & ~mcu_rd_sfr;
        if (mcu_rd_sfr)       mcu_nonram_q <= mcu_sfr_read(mcu_rd_addr);
        else if (mcu_rd_data) mcu_nonram_q <= mcu_dram[mcu_rd_addr[7:0]];
        else                  mcu_nonram_q <= mcurom_data;              // codigo
    end
    always @(*) mcu_rd_byte = mcu_sel_xdata ? wram_mcu_q : mcu_nonram_q;

    // ===================== escritura de wram: UN puerto arbitrado (68k > MCU) =====================
    // En HW el 68k y el MCU comparten la wram por turnos (muxes de bus); aqui un solo puerto con
    // byte-enable -> BRAM inferible. Colision (mismo ciclo) muy rara: prioridad al 68000.
    // Puerto unico arbitrado (68k > MCU; BRAM inferible). NOTA (2026-06-13): descarta el write del MCU en
    // colision con el 68000 (visto en sim: 1er write del MCU a xdata[0000] dropeado por wr68=1). NO es la
    // causa del negro actual (el MCU diverge en su init ANTES/independientemente), pero habra que hacerlo
    // dual-write (sin descarte) cuando el MCU llegue a escribir la firma. Ver bitacora 2026-06-13 (tarde).
    wire        wr68_wram = wr_ack & ~rw_rd & cs_wram & (fc != 3'd7);

    // === FSM "fake MCU" (MCU_STUB): bypass del handshake DS5002 para v1 ===
    // Detecta el wake del 68k (escribe FEF501=01 -> word 0x1A80 byte bajo) y, tras ~8 clks, pulsa
    // stub_we para escribir la firma A5->FEF500(hi) 3E->FEF501(lo). Re-arma por cada wake (el 68k
    // re-chequea). Mientras espera, el 68k POLLEA (lee) -> sin colision con la escritura del stub.
    wire       stub_wake = wr68_wram & (addr[13:1]==13'h1A80) & lds & (oEdb[7:0]==8'h01);
    reg [1:0]  stub_st  = 2'd0;
    reg [3:0]  stub_dly = 4'd0;
    reg        stub_we  = 1'b0;
    always @(posedge clk) begin
        stub_we <= 1'b0;
        if (rst) begin stub_st <= 2'd0; stub_dly <= 4'd0; end
        else if (MCU_STUB) case (stub_st)
            2'd0: if (stub_wake) begin stub_dly <= 4'd8; stub_st <= 2'd1; end
            2'd1: if (stub_dly == 4'd0) begin stub_we <= 1'b1; stub_st <= 2'd2; end
                  else stub_dly <= stub_dly - 1'b1;
            2'd2: stub_st <= 2'd0;       // re-arma para el siguiente wake
        endcase
    end

    // Fuente de escritura del "lado MCU": el stub (firma a 0x1A80) o el r8051 real (mcu_wr_*).
    wire        mcu_src_we  = MCU_STUB ? stub_we   : mcu_wr_xdata;
    wire [12:0] mcu_src_adr = MCU_STUB ? 13'h1A80  : mcu_wr_addr[13:1];
    wire [15:0] mcu_src_dat = MCU_STUB ? 16'hA53E  : {mcu_wr_byte, mcu_wr_byte};
    wire        mcu_src_whi = MCU_STUB ? 1'b1      : ~mcu_wr_addr[0];
    wire        mcu_src_wlo = MCU_STUB ? 1'b1      :  mcu_wr_addr[0];

    // ===================== wram COMPARTIDA: DOBLE-PUERTO (idioma jotego, patrón biocom) =====================
    // FIEL a la placa (ver WRally/arquitectura.md §"RAM compartida 68000↔DS5002FP — ARBITRAJE"): la PCB
    // multiplexa por FASE de reloj — NO hay master que preempte ni dato retenido. Cada CPU su puerto, lee su
    // dirección FRESCA. Port0 = 68000, Port1 = DS5002 (lee Y escribe por su puerto), igual que
    // jtbiocom_main.v:284 (68000 + MCU i8751). El cross-port read-during-write (mismo flanco, misma celda) se
    // evita DESFASANDO los cen 68k/MCU (una sola base de fase = como el 74F112 de la placa) -> ver fase del
    // MCU (mcu_ph) más abajo. DESCARTADO por NO fiel: árbitro master-preempt V.062 (dato rancio + inanición).
    jtframe_dual_ram16 #(.AW(13)) u_wram (
        .clk0 ( clk ),
        .data0( oEdb ),
        .addr0( addr[13:1] ),
        .we0  ( {uds, lds} & {2{wr68_wram}} ),                    // {hi=uds, lo=lds} gateado por escritura wram
        .q0   ( wram_cpu_q_raw ),
        .clk1 ( clk ),
        .data1( mcu_src_dat ),
        .addr1( mcu_src_we ? mcu_src_adr : mcu_rd_addr[13:1] ),   // si escribe -> su addr; si no -> lee mcu_rd_addr
        .we1  ( {mcu_src_whi, mcu_src_wlo} & {2{mcu_src_we}} ),
        .q1   ( wram_mcu_q16_raw )
    );

    // ===================== WRITE-FORWARD BIDIRECCIONAL (residual de FPGA del doble-puerto) =====================
    // El doble-puerto es fiel (multiplexado por fase, = biocom). El ÚNICO residual: si los dos puertos tocan
    // la MISMA celda el MISMO flanco y uno escribe, el otro lee BASURA en la M9K real (no en sim: Verilator
    // da read-before-write). En la placa NO pasa (fases). Aquí lo blindamos dando al puerto que LEE el dato
    // FRESCO que el otro ESCRIBE (= lo que una fase también daría: viejo-o-nuevo válido). BIDIRECCIONAL:
    //   - Dir.A: el MCU lee mientras el 68k escribe la misma celda -> el MCU recibe el dato del 68k.
    //   - Dir.B: el 68k lee el resultado del coproc (FEC2xx) mientras el MCU lo escribe -> el 68k recibe el
    //            dato del MCU (síntoma sin esto: el coche colocado mal vs la carretera -> freeze ~1:04 HW).
    // Timing: registramos el write (addr/dato/we) y la addr de lectura del OTRO puerto 1 ciclo, para alinear
    // con el `q` REGISTRADO del dual_ram, y forzamos el dato fresco en el ciclo en que `q` es basura. NO es
    // stall (no rompe el semáforo). [Fidelidad futura: OPCIÓN 1 = desfase estructural de fase, sin forward.]
    reg  [12:0] fwd_w68_adr, fwd_mcuw_adr, fwd_cpurd_adr, fwd_mcurd_adr;
    reg  [15:0] fwd_w68_dat, fwd_mcuw_dat;
    reg  [ 1:0] fwd_w68_we,  fwd_mcuw_we;
    reg         fwd_cpu_rd,  fwd_mcu_rd;
    wire [ 1:0] w68_we_now  = {uds, lds} & {2{wr68_wram}};
    wire [ 1:0] mcuw_we_now = {mcu_src_whi, mcu_src_wlo} & {2{mcu_src_we}};
    always @(posedge clk) begin
        fwd_w68_adr   <= addr[13:1];        fwd_w68_dat <= oEdb;        fwd_w68_we  <= w68_we_now;
        fwd_mcuw_adr  <= mcu_src_adr;       fwd_mcuw_dat<= mcu_src_dat; fwd_mcuw_we <= mcuw_we_now;
        fwd_cpurd_adr <= addr[13:1];        fwd_cpu_rd  <= ~(|w68_we_now);   // el 68k LEÍA la wram (no escribía)
        fwd_mcurd_adr <= mcu_rd_addr[13:1]; fwd_mcu_rd  <= ~mcu_src_we;      // el puerto MCU LEÍA (no escribía)
    end
    // Dir.A: MCU lee lo que el 68k escribió (misma celda) -> dato fresco del 68k
    wire mcu_fwd_hit = fwd_mcu_rd & (fwd_w68_adr == fwd_mcurd_adr);
    assign wram_mcu_q16 = {
        (mcu_fwd_hit & fwd_w68_we[1]) ? fwd_w68_dat[15:8] : wram_mcu_q16_raw[15:8],
        (mcu_fwd_hit & fwd_w68_we[0]) ? fwd_w68_dat[ 7:0] : wram_mcu_q16_raw[ 7:0] };
    // Dir.B: 68k lee lo que el MCU escribió (misma celda) -> dato fresco del MCU
    wire cpu_fwd_hit = fwd_cpu_rd & (fwd_mcuw_adr == fwd_cpurd_adr);
    assign wram_cpu_q = {
        (cpu_fwd_hit & fwd_mcuw_we[1]) ? fwd_mcuw_dat[15:8] : wram_cpu_q_raw[15:8],
        (cpu_fwd_hit & fwd_mcuw_we[0]) ? fwd_mcuw_dat[ 7:0] : wram_cpu_q_raw[ 7:0] };

    // DEBUG HW: snoop de la firma (word 0x1A80 = FEF500/501) y actividad del MCU para el UART.
    // Latcheamos el ultimo byte escrito a 0x1A80 (por quien sea) y contamos escrituras xdata del MCU.
    // Solo lectura -> no toca puertos de la BRAM (no rompe la inferencia). No afecta a la logica.
    reg [7:0] dbg_firma_hi = 8'd0, dbg_firma_lo = 8'd0, dbg_mcu_act_r = 8'd0;
    always @(posedge clk) begin
        // snoop del word 0x1A80 desde los DOS puertos del dual_ram (68k y MCU), sin leer el array
        if (wr68_wram && addr[13:1]==13'h1A80) begin            // escritura del 68k
            if (uds) dbg_firma_hi <= oEdb[15:8];
            if (lds) dbg_firma_lo <= oEdb[7:0];
        end
        if (mcu_src_we && mcu_src_adr==13'h1A80) begin           // escritura del MCU (o stub)
            if (mcu_src_whi) dbg_firma_hi <= mcu_src_dat[15:8];
            if (mcu_src_wlo) dbg_firma_lo <= mcu_src_dat[7:0];
        end
        if (mcu_wr_xdata && dbg_mcu_act_r != 8'hFF) dbg_mcu_act_r <= dbg_mcu_act_r + 1'b1;
    end
    assign dbg_firma   = {dbg_firma_hi, dbg_firma_lo};
    assign dbg_mcu_act = dbg_mcu_act_r;

    // === GATE de HANDSHAKE (solo-sim) — la firma A53E DEBE aparecer (regresión V.061 = se queda en 0001) ===
    // El usuario lo vio: una regresión del árbitro rompe el handshake y se ve EN SIM (~frame 58). Test rápido:
    // grep "HANDSHAKE OK" en el log del sim. Si NO aparece (o sale "FIRMA estancada") -> el cambio rompió el MCU.
    // synthesis translate_off
    reg dbg_hs_done = 1'b0;
    always @(posedge clk) begin
        if (!dbg_hs_done && dbg_firma == 16'hA53E) begin
            dbg_hs_done <= 1'b1;
            $display("[HANDSHAKE OK] t=%0t  firma wram[0x1A80]=A53E (Coprocessor OK) -- MCU completa el handshake", $time);
        end
    end
    // synthesis translate_on

    // ===================== TELEMETRIA PAGINADA del r8051/handshake (read-only) =====================
    // Taps de SOLO LECTURA (no afectan la logica) para el sistema de telemetria paginada del UART.
    // Pagina 3 (r8051/Dallas) + pagina 4 (handshake wram). Nos saca de adivinar en HW.
    reg [15:0] dbg_pcmax_r=0, dbg_oor_r=0, dbg_fetch_r=0, dbg_coll_r=0;
    reg [ 7:0] dbg_rd0_r=0, dbg_rd1_r=0, dbg_rd2_r=0, dbg_rd3_r=0, dbg_wrby_r=0;
    reg [13:0] dbg_wradr_r=0;
    reg [ 7:0] dbg_1a80_mcu_r=0, dbg_1a80_cpu_r=0;  // snoop de wram[0x1A80] (NO array-read -> preserva BRAM)
    reg        dbg_w01_r=0;   // PEGAJOSO: 1 si el 68k escribio ALGUNA VEZ 0x01 en 0x1A80.lo (=wake DS5002)
    reg [14:0] rdaddr_d1=0;   // mcu_rom_addr registrada (para casar el dato entregado 1 clk despues)
    always @(posedge clk) if (!rst) begin
        if (mcu_rom_en && mcu_rom_addr > dbg_pcmax_r)              dbg_pcmax_r <= mcu_rom_addr;       // PC max
        // REPROPÓSITO (diag congelación V.056): dbg_oor = ULTIMO word que el 68k escribe al flag 0xFEC100
        //   (wram word 0x80). SET (0x8E0C move.w #1) -> 0x0001 ; CLEAR (0xB298 move.b #0) -> 0x00xx/0x0000.
        if (wr68_wram && addr[13:1]==13'h80)                       dbg_oor_r   <= oEdb;
        if (mcu_rom_en && mcurom_vld && dbg_fetch_r!=16'hFFFF)     dbg_fetch_r <= dbg_fetch_r + 1'b1; // fetches
        // byte ENTREGADO en addr 0..3: mcurom_data = mem[addr] 1 clk DESPUES (prom registrado) -> casar
        // con la addr REGISTRADA (la que produjo el dato actual), no con la addr de este ciclo (skew de 1).
        rdaddr_d1 <= mcu_rom_addr[14:0];
        if (rdaddr_d1==15'd0) dbg_rd0_r <= mcurom_data;   // = mem[0] (deberia 02)
        if (rdaddr_d1==15'd1) dbg_rd1_r <= mcurom_data;   // = mem[1] (deberia 01)
        if (rdaddr_d1==15'd2) dbg_rd2_r <= mcurom_data;   // = mem[2] (deberia 00)
        if (rdaddr_d1==15'd3) dbg_rd3_r <= mcurom_data;   // = mem[3] (deberia 02)
        // REPROPÓSITO (V.057): dbg_coll = RAZÓN del STALL del MCU. mcu_stall_cnt = ciclos consecutivos con
        // el core PARADO (work_en=0). Si lleva MUCHO parado (>2000 = stuck real, no un wait normal de 1-2
        // ciclos) latchea: [0]rom_wait(espera fetch) [1]rd_wait(espera lectura RAM) [2]rd_xdata [3]rd_sfr
        // [4]rd_data [15:8]=ciclos parado (satura en FF). Si el MCU NO se cuelga, queda 0.
        if (mcu_dbg_work_en)                                mcu_stall_cnt <= 16'd0;
        else if (mcu_stall_cnt != 16'hFFFF)                mcu_stall_cnt <= mcu_stall_cnt + 1'b1;
        if (~mcu_dbg_work_en && mcu_stall_cnt > 16'd2000)
            dbg_coll_r <= { mcu_stall_cnt[15:8], 3'd0, mcu_rd_data, mcu_rd_sfr, mcu_rd_xdata,
                            mcu_dbg_rd_wait, mcu_dbg_rom_wait };
        if (mcu_wr_xdata) begin dbg_wradr_r <= mcu_wr_addr[14:1]; dbg_wrby_r <= mcu_wr_byte; end       // ultimo write xdata MCU
        // wram[0x1A80] por SNOOP de la escritura (NO leer el array -> rompia la inferencia BRAM, V.036 no cabia).
        if (mcu_src_we && mcu_src_adr==13'h1A80 && mcu_src_wlo) dbg_1a80_mcu_r <= mcu_src_dat[7:0]; // lado MCU
        if (wr68_wram  && addr[13:1]==13'h1A80 && lds)         dbg_1a80_cpu_r <= oEdb[7:0];        // lado 68k
        if (wr68_wram  && addr[13:1]==13'h1A80 && lds && oEdb[7:0]==8'h01) dbg_w01_r <= 1'b1;     // wake visto (pegajoso)
    end
    assign dbg_mcu_pc    = mcu_rom_addr;
    assign dbg_mcu_pcmax = dbg_pcmax_r;
    assign dbg_mcu_fetch = dbg_fetch_r;
    assign dbg_rd0 = dbg_rd0_r;  assign dbg_rd1 = dbg_rd1_r;  assign dbg_rd2 = dbg_rd2_r;  assign dbg_rd3 = dbg_rd3_r;
    assign dbg_mcu_oor   = dbg_oor_r;
    assign dbg_mcu_wradr = dbg_wradr_r;
    assign dbg_mcu_wrby  = dbg_wrby_r;
    assign dbg_mcu_coll  = dbg_coll_r;
    assign dbg_1a80_mcu  = dbg_1a80_mcu_r;
    assign dbg_1a80_cpu  = dbg_1a80_cpu_r;
    assign dbg_68k_w01   = dbg_w01_r;

    // ===== 68k PROFUNDO (read-only): fetch vs data + contadores de handler. Separa "ejecuta en X" de
    // "lee datos en X" (FC) y cuenta entradas a handlers para detectar tormentas de excepcion. Cuenta en
    // as_falling (inicio de ciclo) = 1 por ciclo de bus. NO afecta a la logica.
    wire [23:0] eab_byte_d = {eab,1'b0};
    reg [23:0] dbg_fpc_r=0, dbg_dacc_r=0;
    reg [15:0] dbg_flow_r=0, dbg_iack_r=0, dbg_h400_r=0, dbg_exc_r=0;
    reg [23:0] dbg_lastcode_r=0, dbg_fault1_r=0;   // PC culpable (directo del bus, sin depender del handler)
    reg        dbg_faulted1=0;
    always @(posedge clk) if (!rst) begin
        if (as_falling) begin
            if (fc==3'd2 || fc==3'd6) begin            // FETCH de instruccion (prog user/supv)
                dbg_fpc_r <= eab_byte_d;
                if (eab_byte_d>=24'h000600) dbg_lastcode_r <= eab_byte_d;   // ultimo PC de CODIGO REAL (encima de vectores+handlers)
                if (eab_byte_d>=24'h000040 && eab_byte_d<=24'h000070 && dbg_flow_r!=16'hFFFF) dbg_flow_r<=dbg_flow_r+1'b1;
                // REPROPÓSITO (diag congelación V.056): h400 = nº fetches @0x8E0C (SET del flag 0xFEC100);
                //   exc = nº fetches @0xB294 (invocaciones del CLEAR masivo que borra 0xFEC100..). Si congelado:
                //   exc sigue subiendo pero h400 CONGELADO -> el setup nunca re-pone el flag (cuelgue aguas arriba del SET).
                if (eab_byte_d==24'h008E0C && dbg_h400_r!=16'hFFFF) dbg_h400_r<=dbg_h400_r+1'b1;
                if (eab_byte_d==24'h00B294 && dbg_exc_r !=16'hFFFF) dbg_exc_r <=dbg_exc_r +1'b1;
                // PRIMERA entrada a un handler de excepcion (0x530-0x590): el PC real anterior = la instruccion CULPABLE
                if (eab_byte_d>=24'h000530 && eab_byte_d<=24'h000590 && !dbg_faulted1) begin
                    dbg_fault1_r <= dbg_lastcode_r; dbg_faulted1 <= 1'b1;
                end
            end
            if (fc==3'd1 || fc==3'd5) dbg_dacc_r <= eab_byte_d;   // DATA (user/supv)
            if (fc==3'd7 && dbg_iack_r!=16'hFFFF) dbg_iack_r <= dbg_iack_r+1'b1;  // IACK
        end
    end
    assign dbg_68k_fpc=dbg_fpc_r; assign dbg_68k_dacc=dbg_dacc_r; assign dbg_68k_flow=dbg_flow_r;
    assign dbg_68k_iack=dbg_iack_r; assign dbg_68k_h400=dbg_h400_r; assign dbg_68k_exc=dbg_exc_r;
    assign dbg_68k_fault1 = dbg_fault1_r;

    // ===== CAJA NEGRA de excepcion (read-only): los handlers del firmware guardan en RAM el nº de excepcion
    // en $FEC04C (=wram word 0x26) y el PC que fallo en $FEC048 (=words 0x24 hi, 0x25 lo). Snoopeamos esas
    // escrituras del 68k. PRIMERA excepcion (sticky) = la RAIZ; ULTIMA = donde esta atascado ahora.
    reg [ 7:0] dbg_excn_r=0;
    reg [23:0] dbg_fpc1_r=0, dbg_fpcL_r=0;
    reg dbg_excseen=0, dbg_armpc=0;
    wire excn_valid = (oEdb[15:0]>=16'd2 && oEdb[15:0]<=16'd15);  // exc# real (2-15); el RAM-test pone AA/55 (fuera)
    always @(posedge clk) if (!rst) begin
        // exc# VALIDO en $FEC04C (word 0x26) -> es una excepcion real (no el RAM-test). Arma la captura del PC.
        if (wr68_wram && addr[13:1]==13'h26 && excn_valid) begin
            if (!dbg_excseen) dbg_excn_r <= oEdb[7:0];
            dbg_armpc <= 1'b1;
        end
        // PC del fallo: $FEC048 (word 0x24 hi, 0x25 lo), SOLO tras un exc# valido (gateado por armpc)
        if (dbg_armpc && wr68_wram && addr[13:1]==13'h24) dbg_fpcL_r[23:16] <= oEdb[7:0];
        if (dbg_armpc && wr68_wram && addr[13:1]==13'h25) begin
            dbg_fpcL_r[15:0] <= oEdb[15:0];
            dbg_armpc <= 1'b0;
            if (!dbg_excseen) begin dbg_fpc1_r <= {dbg_fpcL_r[23:16], oEdb[15:0]}; dbg_excseen <= 1'b1; end
        end
    end
    assign dbg_exc_num=dbg_excn_r; assign dbg_fault_pc=dbg_fpc1_r; assign dbg_fault_pcl=dbg_fpcL_r;

    // ===== RESET VECTOR tal como la SDRAM se lo ENTREGA al 68k (read-only). El 68k lee al arrancar 4 words:
    // prog_addr 0=SP[31:16], 1=SP[15:0], 2=PC[31:16], 3=PC[15:0]. Snoopeamos prog_data cuando es valido.
    // Si PC=0x002400 (correcto) -> el dato de ENTRADA es bueno -> el fallo es de ejecucion; si basura -> el
    // dato SDRAM le llega CORRUPTO desde la palabra 0 (causa raiz del estado corrupto del 68k).
    reg [15:0] rv0=0, rv1=0, rv2=0, rv3=0;
    reg rvg0=0, rvg1=0, rvg2=0, rvg3=0;
    reg [23:0] dbg_ff_r=0; reg dbg_ffg=0;
    always @(posedge clk) if (!rst) begin
        if (prog_cs && prog_data_ok) begin
            if (prog_addr==19'd0 && !rvg0) begin rv0<=prog_data; rvg0<=1'b1; end
            if (prog_addr==19'd1 && !rvg1) begin rv1<=prog_data; rvg1<=1'b1; end
            if (prog_addr==19'd2 && !rvg2) begin rv2<=prog_data; rvg2<=1'b1; end
            if (prog_addr==19'd3 && !rvg3) begin rv3<=prog_data; rvg3<=1'b1; end
        end
        if (as_falling && (fc==3'd2 || fc==3'd6) && !dbg_ffg) begin dbg_ff_r<=eab_byte_d; dbg_ffg<=1'b1; end
    end
    assign dbg_rst_sp    = {rv0[7:0], rv1};   // SP[23:0]
    assign dbg_rst_pc    = {rv2[7:0], rv3};   // PC[23:0] (reset vector) <- el dato de entrada clave
    assign dbg_first_fetch = dbg_ff_r;

    // LECTURAS del MCU + escrituras del 68k a la wram (read-only). Para comparar HW vs el oraculo del sim:
    // ¿el barrido xdata del r8051 AVANZA (rdmax sube) o esta atascado? ¿que le escribe el 68k?
    reg [15:0] dbg_rdmax_r=0, dbg_rdadr_r=0, dbg_nrd_r=0;
    reg [ 7:0] dbg_rdby_r=0, dbg_68wrby_r=0;
    reg [13:0] dbg_68wradr_r=0;
    always @(posedge clk) if (!rst) begin
        if (mcu_rd_xdata) begin
            dbg_rdadr_r <= mcu_rd_addr;
            // rd_max = extension del BARRIDO (addr < 0x8000); excluye las lecturas constantes ALTAS
            // (0xF501/0xC103) que si no lo fijarian siempre alto -> asi distingue "barrido atascado".
            if (!mcu_rd_addr[15] && mcu_rd_addr > dbg_rdmax_r) dbg_rdmax_r <= mcu_rd_addr;
            if (dbg_nrd_r != 16'hFFFF)       dbg_nrd_r   <= dbg_nrd_r + 1'b1;
        end
        if (mcu_rd_any)  dbg_rdby_r   <= mcu_rd_byte;                       // ultimo byte leido (cualquier fuente)
        if (wr68_wram) begin dbg_68wradr_r <= addr[13:1]; dbg_68wrby_r <= oEdb[7:0]; end // ultimo write 68k->wram
    end
    assign dbg_mcu_rdmax = dbg_rdmax_r;
    assign dbg_mcu_rdadr = dbg_rdadr_r;
    assign dbg_mcu_rdby  = dbg_rdby_r;
    assign dbg_mcu_nrd   = dbg_nrd_r;
    assign dbg_68k_wradr = dbg_68wradr_r;
    assign dbg_68k_wrby  = dbg_68wrby_r;

    // escritura del MCU (data RAM interna)
    always @(posedge clk) begin
        if (mcu_wr_data)  mcu_dram[mcu_wr_addr[7:0]] <= mcu_wr_byte;
    end

`ifdef SIMULATION
    integer dbg_mwx=0, dbg_mrx=0, dbg_w68=0; reg [31:0] dbg_hbc=0;
    always @(posedge clk) if (!rst) begin
        dbg_hbc <= dbg_hbc + 1;
        // lecturas del MCU del wake (word 0x1A80) POST-wake (tras 3M clks) con valor
        if (dbg_hbc>32'd3000000 && mcu_rd_xdata && mcu_rd_addr[13:1]==13'h1A80 && dbg_mrx<30) begin dbg_mrx=dbg_mrx+1;
            $display("MCUrdWK #%0d xaddr=%h byte=%h | mcu_lo[1A80]=%h cpu_lo[1A80]=%h", dbg_mrx,
                     mcu_rd_addr, mcu_rd_byte, dbg_1a80_mcu_r, dbg_1a80_cpu_r); end
        // CUALQUIER escritura xdata del MCU
        if (mcu_wr_xdata && dbg_mwx<40) begin dbg_mwx=dbg_mwx+1;
            $display("MCUwr #%0d xaddr=%h word=%h byte=%h", dbg_mwx, mcu_wr_addr, mcu_wr_addr[13:1], mcu_wr_byte); end
        if (dbg_hbc[20:0]==21'd0)
            $display("MCUPC hbc=%0d rom_addr=%h mcuact=%0d firma=%h mcu_lo1A80=%h cpu_lo1A80=%h", dbg_hbc,
                     mcu_rom_addr, dbg_mcu_act_r, {dbg_firma_hi,dbg_firma_lo}, dbg_1a80_mcu_r, dbg_1a80_cpu_r); end
    // ORACULO: trazar las LECTURAS xdata del MCU (RAM compartida) en el sim QUE FUNCIONA -> que pollea
    // el r8051 en su bucle de arranque y QUE valor le deja salir. Comparar con HW (telemetria) = saber
    // si HW va por detras / lee otra cosa. (mcu_rd_byte = valor leido; pc=donde ejecuta el r8051.)
    integer dbg_rdn=0; reg [15:0] dbg_lastpc=0;
    always @(posedge clk) if (!rst && mcu_rd_xdata && dbg_rdn<300) begin
        dbg_rdn = dbg_rdn+1;
        $display("MCURD #%0d pc=%h xrd[%h]=%h | 1A80 mcu=%h cpu=%h | firma=%h", dbg_rdn,
                 mcu_rom_addr, mcu_rd_addr, mcu_rd_byte, dbg_1a80_mcu_r, dbg_1a80_cpu_r,
                 {dbg_firma_hi,dbg_firma_lo});
    end
    // ORACULO: escrituras del 68k a la wram (quien llena la rampa que el barrido del MCU lee). Muestra
    // addr-WORD, byte(s), tiempo, y el PC del MCU (para ver si el 68k escribe ANTES de que el MCU barra).
    integer dbg_w68n=0;
    always @(posedge clk) if (!rst && wr68_wram && dbg_w68n<200) begin
        dbg_w68n = dbg_w68n+1;
        $display("W68 #%0d t=%0d wram[%h] u=%b l=%b dat=%h | mcuPC=%h mcuRD[%h]", dbg_w68n, dbg_hbc,
                 addr[13:1], uds, lds, oEdb, mcu_rom_addr, mcu_rd_addr);
    end
    // HANDSHAKE 0x1A80: el desasm dice que el MCU escribe la firma SOLO si lee xdata[0xF501]==0x01.
    // Trazar (a) las escrituras del 68k a wram[0x1A80] (¿pone 0x01? ¿una vez o repetido? ¿cuanto dura?)
    // y (b) las lecturas del MCU de 0xF501 (¿llega a leer 0x01?). Cuenta total cap para no inundar.
    integer dbg_w1n=0, dbg_r1n=0;
    always @(posedge clk) if (!rst) begin
        if (wr68_wram && addr[13:1]==13'h1A80 && dbg_w1n<60) begin dbg_w1n=dbg_w1n+1;
            $display("HS68w  #%0d t=%0d wram[1A80] u=%b l=%b dat=%h (low=%h) | mcuPC=%h",
                     dbg_w1n, dbg_hbc, uds, lds, oEdb, oEdb[7:0], mcu_rom_addr); end
        if (mcu_rd_xdata && mcu_rd_addr==16'hF501 && dbg_r1n<60) begin dbg_r1n=dbg_r1n+1;
            $display("HSmcuR #%0d t=%0d MCU lee 0xF501 -> byte=%h | mcuPC=%h", dbg_r1n, dbg_hbc, mcu_rd_byte, mcu_rom_addr); end
    end
    // IRQ TRACE (oraculo): ¿el sim toma la IRQ de vblank? ¿a que vector va (0x400=rte malo / 0x2330=real)?
    integer dbg_vbl=0, dbg_iack=0, dbg_h400=0, dbg_h2330=0;
    always @(posedge clk) if (!rst) begin
        if (vblank_irq && dbg_vbl<20) begin dbg_vbl=dbg_vbl+1;
            $display("VBL    #%0d t=%0d (vblank_irq) irq_pending=%b IPL2n=%b", dbg_vbl, dbg_hbc, irq_pending, IPL2n); end
        if (~ASn && fc==3'd7 && dbg_iack<20) begin dbg_iack=dbg_iack+1;
            $display("IACK   #%0d t=%0d eab=%06X VPAn=%b DTACKn=%b", dbg_iack, dbg_hbc, {eab,1'b0}, VPAn, DTACKn); end
        if (~ASn && {eab,1'b0}>=24'h400 && {eab,1'b0}<=24'h410 && dbg_h400<20) begin dbg_h400=dbg_h400+1;
            $display("HND400 #%0d t=%0d eab=%06X (handler rte 0x400 = vector MALO)", dbg_h400, dbg_hbc, {eab,1'b0}); end
        if (~ASn && {eab,1'b0}>=24'h2330 && {eab,1'b0}<=24'h2340 && dbg_h2330<20) begin dbg_h2330=dbg_h2330+1;
            $display("HND2330#%0d t=%0d eab=%06X (handler vblank REAL 0x2330 = autovector OK)", dbg_h2330, dbg_hbc, {eab,1'b0}); end
    end
`endif

    // ram_rd_vld@1 (sigue a ram_rd_en con 1 ciclo) = config PROBADA a cen PLENO (FS=1). Igual que rom:
    // a cen dividido (FS=0) este handshake se rompe (el pulso cae entre flancos cpu_en); la estrategia HW
    // es FS=1 (cen pleno) con esta logica probada.
    // wram = DOBLE-PUERTO (idioma jotego/biocom, fiel a la placa: multiplexado por fase). El ÚNICO residual
    // de FPGA es el cross-port read-during-write a la MISMA celda el MISMO flanco -> la M9K devuelve BASURA
    // (en HW; en sim la NBA da read-before-write y no se ve). MANEJO del residual: PENDIENTE (ver
    // WRally/arquitectura.md §"RAM compartida"). Opciones válidas (la colisión necesita un valor VÁLIDO
    // viejo-o-nuevo, NO un stall):
    //   - OPCIÓN 1 (más fiel): desfase ESTRUCTURAL de fase (una base de reloj, dos fases exclusivas, como el
    //     74F112) -> colisión imposible. Complica: el cen del 68000 (DTACK, con wait-states) no es fase libre
    //     -> afinar el desfase en HW. Para iteración futura de fidelidad.
    //   - OPCIÓN 3 (faithful-in-result): write-forward -> en la colisión, dar al MCU el dato que el 68k
    //     escribe (= valor nuevo, lo que una fase también daría). NO es stall.
    //   - ❌ OPCIÓN 2 (stall por colisión): PROBADA Y DESCARTADA 2026-06-19 -> ROMPE el handshake (firma=0001):
    //     el semáforo EXIGE leer la palabra de la firma MIENTRAS el 68k la escribe (viejo-o-nuevo, ambos
    //     válidos); frenar esa lectura cuelga al MCU antes de escribir A53E. Un stall NO sirve para un semáforo.
    reg mcu_ram_rd_vld;
    always @(posedge clk) mcu_ram_rd_vld <= (mcu_rd_data | mcu_rd_sfr | mcu_rd_xdata);

    // FIX 2026-06-13 (negro = handshake DS5002, NO SDRAM): el handshake rom_vld/ram_rd_vld del core
    // r8051 funciona TANTO a cpu_en=1 como a clk/8 (mcu_cen). El core se stalea (work_en=0) hasta que
    // llega vld, leyendo el byte correcto en su ciclo activo. La sesion anterior usaba vld=1 CONSTANTE
    // a clk/8 -> el core no esperaba -> leia stale -> desbocaba (de ahi el mito "clk/8 no funciona").
    // VERIFICADO en tb_ds5002_cen: a clk/8 + handshake el MCU ejecuta wrdallas (PC 0..382B) y escribe
    // la firma A5 3E (xdata[3500/3501]). => MCU_FULLSPEED solo controla la VELOCIDAD (cpu_en); el
    // handshake (vld + ROM gateada) se usa SIEMPRE. HW: MCU_FULLSPEED=0 (clk/8, timing-limpio) + DS5002
    // REAL funcionando (no stub).
    wire        mcu_cpu_en_w  = MCU_FULLSPEED ? 1'b1 : mcu_cen;  // velocidad: full-speed (sim) o clk/8 (HW)
    wire        mcu_rom_vld_w = mcurom_vld;        // handshake SIEMPRE (rom_vld sigue a rom_en)
    wire        mcu_rrd_vld_w = mcu_ram_rd_vld;    // handshake SIEMPRE (ram_rd_vld sigue a ram_rd_en)
    // ===== SWAP a mc8051 (Oregano/jtframe) via wrapper wrally_mcu (rama swap-mc8051). =====
    // El r8051 (hobby, 2 bugs de ejecución) queda en migrate-jtframe como fallback. El mc8051 es COMPLETO.
    // El wrapper maneja IRAM/SFR INTERNAMENTE; solo ROM y xdata (MOVX) salen. cen=mcu_cen (12MHz), DIVCEN/12
    // -> ~1MIPS real del DS5002 (sin dividir tocaría la wram antes de que el 68k acabe el POST = RAM Error).
    wire [15:0] mc_xdata_addr;
    wrally_mcu #(.DIVCEN(1)) u_mcu (
        .clk(clk), .rst(rst), .cen(mcu_cen),
        .rom_addr(mcu_rom_addr), .rom_en(mcu_rom_en), .rom_byte(mcurom_data),
        .xdata_rd(mcu_rd_xdata), .xdata_wr(mcu_wr_xdata), .xdata_addr(mc_xdata_addr),
        .xdata_dout(mcu_wr_byte), .xdata_din(wram_mcu_q),
        .dbg_work_en(mcu_dbg_work_en)
    );
    assign mcu_rd_addr = mc_xdata_addr;   // el wrapper usa UNA dirección para lectura y escritura
    assign mcu_wr_addr = mc_xdata_addr;
    assign mcu_rd_data = 1'b0;  assign mcu_rd_sfr = 1'b0;   // data/sfr son INTERNOS del mc8051 (no salen)
    assign mcu_wr_data = 1'b0;  assign mcu_wr_sfr = 1'b0;
    assign mcu_dbg_rom_wait = 1'b0;  assign mcu_dbg_rd_wait = 1'b0;

`ifdef SIMULATION
    // TRAZA r8051 (debug gated-cen, 2026-06-17): que ve el r8051 en CADA flanco activo (cpu_en).
    // Busco la lectura RANCIA: si en un flanco con rom_en&rom_vld el byte != mem[addr] -> ahi derraila.
    integer mcudbg=0;
    always @(posedge clk) if(!rst && mcu_cpu_en_w && mcudbg<64) begin
        mcudbg = mcudbg+1;
        $display("R8051cen #%0d romen=%b addr=%h vld=%b byte=%h | rdvld=%b wrxd=%b wradr=%h wrbyte=%h",
            mcudbg, mcu_rom_en, mcu_rom_addr, mcu_rom_vld_w, mcurom_data,
            mcu_rrd_vld_w, mcu_wr_xdata, mcu_wr_addr, mcu_wr_byte);
    end

    // SELF-CHECK ROM del mc8051: cuando la addr de fetch está ASENTADA (held >=1 clk -> mcurom_data ya es
    // wrdallas[addr]) loguea (addr,byte) 1 vez por fetch. check_rom.py verifica vs wrdallas.bin: si
    // byte != wrdallas[addr & 0x7FFF] -> el mc8051 lee MAL la ROM (ejecuta instrucción equivocada).
    reg [15:0] mcrom_a1=16'd0, mcrom_a2=16'd0;
    integer    mcrom_ln=0;
    always @(posedge clk) begin
        mcrom_a1 <= mcu_rom_addr; mcrom_a2 <= mcrom_a1;
        if (!rst && mcrom_ln<300000 && mcu_rom_addr==mcrom_a1 && mcrom_a1!=mcrom_a2) begin
            $display("MCUROM addr=%04x byte=%02x", mcu_rom_addr, mcurom_data);
            mcrom_ln <= mcrom_ln + 1;
        end
    end
    // INTERFAZ xdata (MOVX) del mc8051: ¿lee/escribe la wram? qué dato. (mcu_rd/wr_xdata son los enables
    // registrados del wrapper; mc_xdata_addr la addr; wram_mcu_q el byte leído; mcu_wr_byte el escrito.)
    integer mcx_ln=0;
    reg mcrd_d=0, mcwr_d=0;
    always @(posedge clk) begin
        mcrd_d <= mcu_rd_xdata; mcwr_d <= mcu_wr_xdata;
        if (!rst && mcx_ln<4000) begin
            if (mcu_rd_xdata & ~mcrd_d) begin $display("MCUXR addr=%04x din=%02x", mc_xdata_addr, wram_mcu_q); mcx_ln<=mcx_ln+1; end
            if (mcu_wr_xdata & ~mcwr_d) begin $display("MCUXW addr=%04x dout=%02x", mc_xdata_addr, mcu_wr_byte); mcx_ln<=mcx_ln+1; end
        end
    end
`endif

endmodule

`default_nettype wire
