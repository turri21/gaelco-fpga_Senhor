// wrally_mcu.v — Wrapper del core MCU del DS5002FP para WRally.
//
// SWAP 2026-06-18: sustituye el core r8051 (Li Xinbing, hobby, sospechoso de ejecutar
// MAL alguna instruccion -> deadlock de proteccion del DS5002 en el frame 60744) por el
// mc8051 de Oregano (jtframe, COMPLETO: ALU/DA A/mul/div). Ver memoria wrally-mc8051-swap-plan.
//
// Diferencias de modelo respecto al r8051:
//  - El r8051 EXTERNALIZA toda la memoria (data/sfr/xdata) con handshake `vld`. El mc8051 maneja
//    IRAM 128B y SFRs INTERNAMENTE; solo el espacio xdata (MOVX) sale al exterior. Es cen-paced
//    (sin vld), mas simple.
//  - Aqui: ROM (wrdallas 32KB) externa via rom_addr/rom_byte (BRAM en jtwrally_game). IRAM 128B
//    interna (jtframe_ram_rst, patron probado del jtframe_8751mcu). MOVX -> al plumbing wram del
//    wrally_main (puerto 1 del dual_ram16 compartido con el 68k).
//
// Latencias: se registran las salidas ROM/xdata 1 clk (igual que jtframe_8751mcu). Con cen=clk/8
// (mcu_cen, NO fullspeed) la latencia de la BRAM externa (1 clk) y del wram (1 clk) queda holgada
// dentro del periodo de cen -> el core muestrea dato valido en su flanco activo. NO usar cen pleno
// (cen=1 cada clk) con ROM externa: el core leeria rancio (era el viejo problema vld@1 del r8051).

`default_nettype none

module wrally_mcu #(
    parameter DIVCEN = 1              // 1 = dividir cen /12 (Oregano es ~12x mas rapido que un 8051 real;
                                      //     a 12 MHz sin dividir el MCU corre ~12 MIPS y llega a tocar la
                                      //     RAM compartida ANTES de que el 68k acabe su POST -> RAM Error.
                                      //     /12 = velocidad real del DS5002 (~1 MIPS). Ver jtframe_8751mcu.)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        cen,          // enable base del MCU (mcu_cen = clk48/4 = 12 MHz, crystal del DS5002)

    // --- ROM de programa (wrdallas 32KB; BRAM externa en jtwrally_game) ---
    output wire [15:0] rom_addr,     // PC del MCU (16b para ver derail >0x7FFF en telemetria)
    output wire        rom_en,       // gate de la BRAM externa (continuo)
    input  wire [ 7:0] rom_byte,     // dato de la ROM (1 clk despues de rom_addr)

    // --- xdata (MOVX) -> RAM COMPARTIDA con el 68k (wram, &0x3FFF dentro de wrally_main) ---
    output wire        xdata_rd,     // acceso xdata de LECTURA  (memx & ~wr)
    output wire        xdata_wr,     // acceso xdata de ESCRITURA (memx &  wr)
    output wire [15:0] xdata_addr,   // direccion xdata (el slice [13:1] del wram hace el &0x3FFF)
    output wire [ 7:0] xdata_dout,   // byte a escribir
    input  wire [ 7:0] xdata_din,    // byte leido (= mcu_rd_byte del wrally_main)

    // --- telemetria (compat con la del r8051; el stall-detector se queda mudo) ---
    output wire        dbg_work_en   // =1 siempre -> mcu_stall_cnt nunca dispara (dbg_coll=0)
);

    // ===== divisor de cen /12 (Oregano ~12x mas rapido que un 8051 real -> velocidad real del DS5002) =====
    // cuenta 0..11 sobre cen y pulsa cen_eff una vez cada 12 pulsos de cen. DIVCEN=0 -> cen_eff=cen.
    reg  [3:0] divcnt = 4'd0;
    reg        cen_div = 1'b0;
    always @(posedge clk) begin
        if (cen) divcnt <= (divcnt==4'd11) ? 4'd0 : divcnt + 4'd1;
        cen_div <= (divcnt==4'd1) && cen;     // 1 pulso cada 12 de cen
    end
    wire cen_eff = (DIVCEN!=0) ? cen_div : cen;

    // ---- senales del mc8051_core ----
    wire [15:0] core_rom_adr;        // PC que pide el core
    wire [ 7:0] core_ram_q;          // IRAM -> core
    wire [ 7:0] core_ram_d;          // core -> IRAM
    wire [ 7:0] core_ram_adr;        // IRAM addr (256B; 8052 tras parche Oregano)
    wire        core_ram_wr;
    wire        core_ram_en;         // (sin usar, como en jtframe_8751mcu)
    wire [ 7:0] core_datax_o;        // MOVX dato out
    wire [15:0] core_adrx;           // MOVX addr
    wire        core_memx;           // MOVX acceso
    wire        core_wrx;            // MOVX write(1)/read(0)

    // ===== ROM: registrar la direccion 1 clk (patron jtframe_8751mcu: rom_addr<=pre_rom) =====
    // La BRAM externa entrega rom_byte 1 clk despues.
    reg [15:0] rom_addr_r = 16'd0;
    always @(posedge clk) rom_addr_r <= core_rom_adr;
    assign rom_addr = rom_addr_r;
    assign rom_en   = 1'b1;          // lectura continua de la wrdallas

    // ===== LECTURA ROM GATEADA POR cen_eff (CRITICO; replica jtframe_dual_ram_cen) =====
    // jtframe_8751mcu (Tejada): "You need to clock gate for reading or the MCU won't work".
    // El rom_adr_o del Oregano es COMBINACIONAL y oscila por estados intermedios DENTRO de un periodo de
    // cen. Si el dato de ROM (BRAM externa, registrada cada clk, NO cen-gated) sigue esas direcciones
    // intermedias, el core decodifica BASURA -> PC corrupto -> bucle de reset (0000->0100->04c3->04f7->0000,
    // verificado en sim 2026-06-19, 0 MOVX, 0 escrituras a R0-R7). El fix: RETENER rom_byte solo en cen_eff
    // -> el dato es estable todo el periodo y muestreado cuando rom_addr_r ya asento la PC arquitectonica.
    reg [7:0] rom_data_q = 8'd0;
    always @(posedge clk) if (cen_eff) rom_data_q <= rom_byte;

    // ===== IRAM interna (jtframe_ram_rst AW=8, CEN_RD=1: lectura/escritura gateadas por cen) =====
    // CONFIRMADO en datasheet/User Guide DS5002FP (2026-06-19): es un 8051 de 128 BYTES de scratchpad
    // (00h-7Fh), NO un 8052 de 256B. El boot pone SP=0x70 -> pila 0x70..0x7F (16 bytes), cabe en 128.
    // AW=8 (256B) es un superset inofensivo (el firmware solo toca 0x00-0x7F). CEN_RD=1: lectura gateada
    // por cen (igual que jtframe_8751mcu u_ramu, que usa AW=7=128B).
    jtframe_ram_rst #(.AW(8),.CEN_RD(1)) u_iram (
        .rst ( rst          ),
        .clk ( clk          ),
        .cen ( cen_eff      ),
        .addr( core_ram_adr ),
        .data( core_ram_d   ),
        .we  ( core_ram_wr  ),
        .q   ( core_ram_q   )
    );

    // ===== xdata (MOVX): registrar salidas 1 clk (patron jtframe_8751mcu) =====
    reg [15:0] x_addr_r = 16'd0;
    reg [ 7:0] x_dout_r = 8'd0;
    reg        x_wr_r   = 1'b0;
    reg        x_acc_r  = 1'b0;
    always @(posedge clk) begin
        x_addr_r <= core_adrx;
        x_dout_r <= core_datax_o;
        x_wr_r   <= core_wrx;
        x_acc_r  <= core_memx;
    end
    assign xdata_addr = x_addr_r;
    assign xdata_dout = x_dout_r;
    assign xdata_rd   = x_acc_r & ~x_wr_r;   // acceso de lectura
    assign xdata_wr   = x_acc_r &  x_wr_r;   // acceso de escritura

    // ===== LECTURA xdata (MOVX) GATEADA POR cen_eff (mismo principio que la ROM; jtframe SYNC_XDATA) =====
    // El adrx_o del Oregano tambien es COMBINACIONAL y oscila dentro del periodo de cen -> la wram (puerto
    // compartido con el 68k) que entrego a datax_i debe RETENERSE en cen_eff, o el core muestrea dato de
    // direccion transitoria (en sim 2026-06-19 SIN gatear: las 4017 lecturas MOVX devolvian 0x88 constante
    // = wram[0], la PC no veia el flag del 68k -> handshake atascado). Con cen-gate el dato es estable y
    // muestreado cuando x_addr_r ya asento la direccion xdata arquitectonica.
    reg [7:0] xdata_din_q = 8'd0;
    always @(posedge clk) if (cen_eff) xdata_din_q <= xdata_din;

    assign dbg_work_en = 1'b1;               // el stall-detector del r8051 no aplica al mc8051

`ifdef SIMULATION
    // ===== TRAZA boot mc8051 (2026-06-19): localizar el cuelgue del bucle 0x045F y el valor de R0 =====
    // (1) MCUTRC: traza de PC (core_rom_adr) cuando hay SALTO (no secuencial) -> control-flow compacto.
    //     En el bucle 0x045F-0x046B el SJMP 045F genera un salto cada iteracion -> se ve spinning.
    reg [15:0] pc_l = 16'hFFFF;
    integer    trc_ln = 0;
    always @(posedge clk) if (cen_eff && !rst) begin
        // salto = destino no es pc_l+1/+2/+3 (instrucciones de 1..3 bytes)
        if ( core_rom_adr != pc_l && core_rom_adr != pc_l+16'd1 &&
             core_rom_adr != pc_l+16'd2 && core_rom_adr != pc_l+16'd3 && trc_ln < 200000 ) begin
            $display("MCUTRC pc=%04x", core_rom_adr);
            trc_ln <= trc_ln + 1;
        end
        pc_l <= core_rom_adr;
    end
    // (2) MCUREG: escrituras a los registros de trabajo R0..R7 (IRAM 0x00..0x1F, banco actual).
    //     R0=00 R1=01 R3=03 R4=04 (banco 0). Veo el VALOR que toma R0 -> si >=0x28 (40) cuelga el bucle.
    integer reg_ln = 0;
    always @(posedge clk) if (cen_eff && !rst && core_ram_wr && core_ram_adr < 8'h20 && reg_ln < 100000) begin
        $display("MCUREG iram[%02x]=%02x", core_ram_adr, core_ram_d);
        reg_ln <= reg_ln + 1;
    end
    // (3) MCURDX: lo que el core REALMENTE lee del MOVX (dato cen-gated xdata_din_q), en cen_eff con acceso
    //     de lectura activo. A diferencia del MCUXR de wrally_main (muestrea al subir el enable, dato rancio
    //     de la BRAM), esto refleja el byte que consume el core. Veo si ya ve el flag del 68k (F501/C103).
    integer rdx_ln = 0;
    always @(posedge clk) if (cen_eff && !rst && (x_acc_r & ~x_wr_r) && rdx_ln < 8000) begin
        $display("MCURDX addr=%04x q=%02x", x_addr_r, xdata_din_q);
        rdx_ln <= rdx_ln + 1;
    end
`endif

    // ===== el core (Oregano). VHDL en Quartus / mc8051.v en Verilator (cfg/cpu/mc8051.yaml) =====
    // int0/int1 = 1 (inactivos, pin activo-bajo; el firmware NO usa interrupciones, verificado).
    // p0..p3 = 0xFF (igual que el r8051 devolvia para los SFR de puerto). t0/t1/rxd = 0.
    mc8051_core u_core (
        .clk        ( clk           ),
        .cen        ( cen_eff       ),
        .reset      ( rst           ),
        // ROM (dato RETENIDO en cen_eff -> estable durante el periodo; ver rom_data_q arriba)
        .rom_data_i ( rom_data_q    ),
        .rom_adr_o  ( core_rom_adr  ),
        // IRAM interna
        .ram_data_i ( core_ram_q    ),
        .ram_data_o ( core_ram_d    ),
        .ram_adr_o  ( core_ram_adr  ),
        .ram_wr_o   ( core_ram_wr   ),
        .ram_en_o   ( core_ram_en   ),
        // xdata (MOVX)
        .datax_i    ( xdata_din_q   ),   // RETENIDO en cen_eff (ver arriba)
        .datax_o    ( core_datax_o  ),
        .adrx_o     ( core_adrx     ),
        .memx_o     ( core_memx     ),
        .wrx_o      ( core_wrx      ),
        // interrupciones / timers / serie (sin usar)
        .int0_i     ( 1'b1          ),
        .int1_i     ( 1'b1          ),
        .all_t0_i   ( 1'b0          ),
        .all_t1_i   ( 1'b0          ),
        .all_rxd_i  ( 1'b0          ),
        .all_rxd_o  (               ),
        .all_rxdwr_o(               ),
        .all_txd_o  (               ),
        // puertos I/O (el DS5002 de wrally no usa puertos para I/O de juego -> 0xFF como el r8051)
        .p0_i       ( 8'hFF         ), .p0_o (),
        .p1_i       ( 8'hFF         ), .p1_o (),
        .p2_i       ( 8'hFF         ), .p2_o (),
        .p3_i       ( 8'hFF         ), .p3_o ()
    );

endmodule

`default_nettype wire
