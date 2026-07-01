// ============================================================================
//  Big Karnak (Gaelco) — "PLACA" sintetizable: 68000 (fx68k) + mapa de memoria +
//  protocolo de bus + IRQ6 (vblank) + work RAM 32KB + I/O + soundlatch.
//
//  Hardware Tipo-1 (gaelco.cpp) "Unprotected": NO lleva DS5002 NI cifrado de VRAM.
//  -> mucho mas simple que WRally/squash: VRAM plana, sin handshake.
//  El SONIDO va en una CPU dedicada (bigkarnk_sound, a nivel de game): el 68k solo
//  escribe el soundlatch (0x70000F) que dispara un FIRQ en el 6809.
//
//  Estructura/protocolo de bus tomados de wrally_main.v/squash_main.v (verificado).
// ============================================================================
`default_nettype none

module bigkarnk_main (
    input  wire        clk,            // reloj de la logica del juego (48 MHz)
    input  wire        rst,
    input  wire        vblank_irq,     // pulso de vblank -> IRQ6

    // --- ROM de programa del 68000 (512 KB) -> SDRAM ---
    output wire [19:1] prog_addr,      // direccion de WORD
    output wire        prog_cs,
    input  wire [15:0] prog_data,
    input  wire        prog_data_ok,

    // --- puertos de entrada (ya ensamblados por bigkarnk_inputs) ---
    input  wire [15:0] in_dsw1, in_dsw2, in_p1, in_p2, in_service,

    // --- puerto CPU hacia bigkarnk_vmem ---
    output wire        flip_screen,
    output wire [13:0] vmem_addr,        // direccion de BYTE (addr[13:0])
    output wire        vmem_uds, vmem_lds,
    output wire        vmem_we,
    output wire        vmem_cs_vram,     // videoram 100000-101FFF
    output wire        vmem_cs_scrram,   // screenram 102000-103FFF
    output wire        vmem_cs_pal,      // paleta 200000-2007FF
    output wire        vmem_cs_spr,      // sprite RAM 440000-440FFF
    output wire [15:0] vmem_dec_wdata,   // dato a videoram/screenram (PLANO, sin cifrar)
    output wire [15:0] vmem_io_wdata,    // dato a paleta/sprite
    input  wire [15:0] vmem_vram_rdata,
    input  wire [15:0] vmem_scrram_rdata,
    input  wire [15:0] vmem_pal_rdata,
    input  wire [15:0] vmem_spr_rdata,
    output wire [15:0] vreg0, vreg1, vreg2, vreg3,

    // --- soundlatch hacia bigkarnk_sound (6809) ---
    output reg  [7:0]  snd_latch,
    output reg         snd_irq          // pulso de 1 clk al escribir 0x70000F
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

    // ===================== decodificador de direcciones =====================
    wire cs_rom, cs_vram, cs_scrram, cs_vregs, cs_clrint, cs_pal, cs_spr,
         cs_dsw1, cs_dsw2, cs_p1, cs_p2, cs_service, cs_outlatch, cs_sndlatch, cs_wram;
    bigkarnk_addr_decode u_dec (
        .addr(addr), .as(~ASn),
        .cs_rom(cs_rom), .cs_vram(cs_vram), .cs_scrram(cs_scrram), .cs_vregs(cs_vregs),
        .cs_clrint(cs_clrint), .cs_pal(cs_pal), .cs_spr(cs_spr),
        .cs_dsw1(cs_dsw1), .cs_dsw2(cs_dsw2), .cs_p1(cs_p1), .cs_p2(cs_p2),
        .cs_service(cs_service), .cs_outlatch(cs_outlatch), .cs_sndlatch(cs_sndlatch), .cs_wram(cs_wram)
    );

    assign prog_addr = eab[19:1];
    assign prog_cs   = cs_rom & rw_rd;
    wire [15:0] rom_word = prog_data;

    // ===================== DTACK (jtframe_68kdtack) =====================
    // num=1/den=4 -> 12 MHz desde clk=48 MHz.
    wire bus_busy  = cs_rom & rw_rd & ~prog_data_ok;
    wire bus_cs_dt = cs_rom & rw_rd;
    wire dtack_raw;
    bigkarnk_68kdtack #(.W(8)) u_dtack (
        .rst(rst), .clk(clk),
        .cpu_cen(cpu_cen), .cpu_cenb(cpu_cenb),
        .bus_cs(bus_cs_dt), .bus_busy(bus_busy), .bus_legit(1'b0), .bus_ack(1'b0),
        .ASn(ASn), .DSn({UDSn,LDSn}),
        .num(7'd1), .den(8'd4),
        .wait2(1'b0), .wait3(1'b0),
        .DTACKn(dtack_raw)
    );
    // En IACK (fc==7) el 68000 usa VPAn (autovector), NO DTACK.
    assign DTACKn = (fc == 3'd7) ? 1'b1 : dtack_raw;

    // ===================== vregs (scroll) =====================
    reg [15:0] vregs[0:3];
    assign vreg0 = vregs[0]; assign vreg1 = vregs[1];
    assign vreg2 = vregs[2]; assign vreg3 = vregs[3];

    // ===================== puerto CPU hacia bigkarnk_vmem (VRAM PLANA) =====================
    assign vmem_addr      = addr[13:0];
    assign vmem_uds       = uds;
    assign vmem_lds       = lds;
    assign vmem_cs_vram   = cs_vram;
    assign vmem_cs_scrram = cs_scrram;
    assign vmem_cs_pal    = cs_pal;
    assign vmem_cs_spr    = cs_spr;
    assign vmem_we        = wr_ack & ~rw_rd & (cs_vram | cs_scrram | cs_pal | cs_spr);
    assign vmem_dec_wdata = oEdb;          // Big Karnak: VRAM/screenram SIN cifrar
    assign vmem_io_wdata  = oEdb;

    // Big Karnak no tiene bit de flip en el outlatch (solo coin lockout/counter).
    assign flip_screen = 1'b0;

    // ===================== lectura del bus (iEdb) =====================
    always @(*) begin
        iEdb = 16'hFFFF;
        case (1'b1)
            cs_rom:     iEdb = rom_word;
            cs_vram:    iEdb = vmem_vram_rdata;
            cs_scrram:  iEdb = vmem_scrram_rdata;
            cs_pal:     iEdb = vmem_pal_rdata;
            cs_spr:     iEdb = vmem_spr_rdata;
            cs_vregs:   iEdb = vregs[addr[2:1]];
            cs_wram:    iEdb = wram_q;
            cs_dsw1:    iEdb = in_dsw1;
            cs_dsw2:    iEdb = in_dsw2;
            cs_p1:      iEdb = in_p1;
            cs_p2:      iEdb = in_p2;
            cs_service: iEdb = in_service;
            default:    iEdb = 16'hFFFF;
        endcase
    end

    // ===================== protocolo de bus + IRQ + escrituras =====================
    reg  asn_d;
    wire as_rising  = ASn & (~asn_d);              // fin de ciclo
    wire wr_ack     = (~ASn) & (~asn_d);           // NIVEL: dato valido (clks tardios del ciclo)

    reg irq_pending;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            asn_d         <= 1'b1;
            VPAn          <= 1'b1;
            irq_pending   <= 1'b0;
            IPL_n         <= 1'b1;
            snd_latch     <= 8'd0;
            snd_irq       <= 1'b0;
        end else begin
            asn_d   <= ASn;
            snd_irq <= 1'b0;

            if (vblank_irq) irq_pending <= 1'b1;     // vblank -> arma IRQ6
            IPL_n <= ~irq_pending;

            // VPAn: autovector en IACK
            if (~ASn) VPAn <= (fc == 3'd7) ? 1'b0 : 1'b1;
            else      VPAn <= 1'b1;

            // Escrituras de registros / strobes I/O (en el NIVEL: idempotente)
            if (wr_ack) begin
                if (fc == 3'd7) begin
                    irq_pending <= 1'b0;             // se reconocio la IRQ (autovector)
                end else if (~rw_rd) begin
                    if (cs_vregs) begin
                        if (uds) vregs[addr[2:1]][15:8] <= oEdb[15:8];
                        if (lds) vregs[addr[2:1]][7:0]  <= oEdb[7:0];
                    end
                    if (cs_clrint)   irq_pending <= 1'b0;   // irqack_w (CLR INT6)
                    // soundlatch 0x70000F (byte bajo): latch + pulso de FIRQ al 6809
                    if (cs_sndlatch & lds) begin
                        snd_latch <= oEdb[7:0];
                        snd_irq   <= 1'b1;
                    end
                end
            end
        end
    end

    // ===================== work RAM 32KB (FF8000-FFFFFF) -> BRAM =====================
    // Big Karnak usa FF8000-FFFFFF (32KB). addr[15:1] -> 0x4000-0x7FFF; array de 32K words
    // (cubre FF0000-FFFFFF) leido/escrito incondicional -> infiere block-RAM.
    reg [7:0] wram_hi[0:32767], wram_lo[0:32767];
    wire [14:0] wramidx = addr[15:1];
    wire        ww_hi = wr_ack & ~rw_rd & cs_wram & uds;
    wire        ww_lo = wr_ack & ~rw_rd & cs_wram & lds;
    reg  [15:0] wram_q;
    always @(posedge clk) begin
        if (ww_hi) wram_hi[wramidx] <= oEdb[15:8];
        if (ww_lo) wram_lo[wramidx] <= oEdb[7:0];
        wram_q <= {wram_hi[wramidx], wram_lo[wramidx]};
    end

`ifdef SIMULATION
    // DIAGNOSTICO IRQ + PC: ¿la IRQ6 de vblank se ARMA y se TOMA (IACK)?
    reg [31:0] dc=0; integer n_iack=0, n_vbl=0, n_irqset=0; reg ip_d=0, asn_dd=1;
    reg [19:1] pcmax=0;
    always @(posedge clk) begin
        dc <= dc + 1; asn_dd <= ASn; ip_d <= irq_pending;
        if (prog_cs & prog_data_ok & (prog_addr>pcmax)) pcmax <= prog_addr;
        if (vblank_irq)            n_vbl    <= n_vbl + 1;
        if (irq_pending & ~ip_d)   n_irqset <= n_irqset + 1;
        if ((~ASn) & asn_dd & (fc==3'd7)) n_iack <= n_iack + 1;   // flanco de ciclo IACK
        if (snd_irq) $display("SNDLATCH w=%h pc=%h", snd_latch, {prog_addr,1'b0});
        if (dc[20:0]==0) $display("IRQDBG vbl=%0d irqset=%0d iack=%0d pc=%h PCmax=%h IPLn=%b",
                                  n_vbl, n_irqset, n_iack, {prog_addr,1'b0}, {pcmax,1'b0}, IPL_n);
    end
`endif

endmodule

`default_nettype wire
