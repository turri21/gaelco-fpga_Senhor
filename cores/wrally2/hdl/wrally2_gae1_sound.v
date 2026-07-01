// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 / chip GAE1) — Motor de SONIDO del GAE1.
//
//  Port de devices/sound/gaelco.cpp (gaelco_gae1_device). 7 canales estéreo, reproductor de
//  samples PCM 8-bit con los datos en las MISMAS ROMs de gfx. Salida 16-bit L/R a 7812.5 Hz
//  (clock GAE1 1MHz / 128). Mezcla = suma de canales con clip a ±32767/32768.
//
//  Registros (m_sndregs[0x38] = 7 canales * 8 words). Por canal, 2 "chunks" de 4 words:
//    base = ch*8 + chunk*4 :
//      +1 : [15:12]=vol_l  [11:8]=vol_r  [7:4]=type  [1:0]=bank(0..3)
//           type 0x08 = PCM 8b mono ; 0x0c = PCM 8b estéreo
//      +2 : end position (end_pos = (reg<<8)-1)
//      +3 : bytes restantes (se decrementa; al llegar a 0, fin / swap de chunk)
//  Reproduce HACIA ATRÁS: byte = rom[bank + end_pos + restantes]; restantes--.
//    bank = uno de los 4 offsets de plano (alighunt: 0, 0x400000, 0x800000, 0xC00000) -> en el
//    blob DW32 = ELEMENTO (end_pos+restantes), BYTE = índice de banco (plano 0..3), igual que el vídeo.
//  Volumen: voltab[vol][data] = (vol*(data-128)*256)/15 (BRAM volume_table.mem, bit-exacto a MAME).
//
//  Write handler (gaelcosnd_w): al escribir el word +3 (offset&7==3) o +7 (==7): si end_pos!=0 y
//  len!=0 -> canal activo, loop=1, chunkNum=0/1; si no -> inactivo (o loop=0 en el +7).
// ============================================================================
`default_nettype none

module wrally2_gae1_sound #(
    parameter integer CLKDIV = 6144   // clk48 / 7812.5Hz = 6144 (cen de sample)
)(
    input  wire        clk,           // clk48
    input  wire        rst,

    // ---- escritura de registros desde el 68k (region sonido 0x202890-0x2028ff) ----
    input  wire        cs_sound,      // chip select de los regs de sonido
    input  wire [6:0]  cpu_aw,        // addr[7:1] del 68k (word dentro de 0x28xx)
    input  wire        cpu_we,
    input  wire        cpu_uds, cpu_lds,
    input  wire [15:0] cpu_wdata,
    output wire [15:0] cpu_rdata,     // lectura de regs (gaelcosnd_r)

    // ---- lectura de samples de la SDRAM (slot 'snd' del banco gfx, DW32) ----
    output reg  [21:0] rom_addr,      // elemento DW32 (end_pos+restantes)
    output reg         rom_cs,
    input  wire [31:0] rom_data,
    input  wire        rom_ok,

    // ---- salida de audio ----
    output reg signed [15:0] snd_l, snd_r,
    output reg         sample          // pulso por muestra (7812.5 Hz)
);
    // ===================== registro de sonido (56 words) =====================
    reg [15:0] sndregs [0:55];
    reg        active [0:6];
    reg        loop   [0:6];
    reg        chunkNum [0:6];

    // reg index del 68k: 0x2890 -> addr[7:1]=0x48 = reg 0 ; reg = aw-0x48 (0..55)
    wire [6:0] cpu_reg = cpu_aw - 7'h48;
    wire       cpu_inrange = cs_sound & (cpu_reg < 7'd56);
    assign cpu_rdata = sndregs[cpu_reg[5:0]];

    // ===================== cen de sample (7812.5 Hz) =====================
    reg [12:0] divcnt;
    reg        cen;
    always @(posedge clk) begin
        if (rst) begin divcnt <= 0; cen <= 0; end
        else if (divcnt == CLKDIV-1) begin divcnt <= 0; cen <= 1; end
        else begin divcnt <= divcnt + 1'b1; cen <= 0; end
    end

    // ===================== volume table (BRAM 4096x16, bit-exacto a MAME) =====================
    reg signed [15:0] voltab [0:4095];
    initial $readmemh("volume_table.mem", voltab);
    reg [11:0] vol_a;
    reg signed [15:0] vol_q;
    always @(posedge clk) vol_q <= voltab[vol_a];

    // ===================== motor (FSM por muestra, 7 canales) =====================
    localparam [3:0] IDLE=0, CHK=1, A1SET=2, A1WAIT=3, VL=4, VLW=5, RDEC=6,
                     A2WAIT=7, VR=8, VRW=9, ACC=10, NXT=11, OUTP=12, VLB=13;
    reg [3:0]  st;
    reg [2:0]  ch;
    reg [5:0]  base;
    reg [3:0]  vl, vr, typ;
    reg [1:0]  bank;
    reg [15:0] endp;        // end_pos (16b: (reg<<8)-1 cabe en 16? (0xffff<<8)-1 = 0xfffeff -> 24b). Usar 24b.
    reg [23:0] endpos;      // end_pos completo
    reg [15:0] rem;         // restantes
    reg [7:0]  data1;
    reg signed [15:0] chl, chr;
    reg signed [31:0] accl, accr;

    // selección de byte del DW32 por banco (= planos del vídeo)
    function [7:0] selbyte(input [31:0] d, input [1:0] bk);
        case (bk)
            2'd0: selbyte = d[15:8];   // plano0
            2'd1: selbyte = d[7:0];    // plano1
            2'd2: selbyte = d[31:24];  // plano2
            2'd3: selbyte = d[23:16];  // plano3
        endcase
    endfunction

    // dirección de sample (elemento) = end_pos + restantes (22b)
    wire [23:0] saddr = endpos + {8'b0, rem};

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            st <= IDLE; rom_cs <= 0; sample <= 0; ch <= 0;
            snd_l <= 0; snd_r <= 0;
            for (i=0;i<7;i=i+1) begin active[i]<=0; loop[i]<=0; chunkNum[i]<=0; end
        end else begin
            sample <= 0;
            // ---- escritura del 68k (prioridad sobre el decremento del motor) ----
            if (cpu_inrange & cpu_we) begin
                if (cpu_uds) sndregs[cpu_reg[5:0]][15:8] <= cpu_wdata[15:8];
                if (cpu_lds) sndregs[cpu_reg[5:0]][7:0]  <= cpu_wdata[7:0];
                // handler: arranque/parada al escribir word +3 (offset&7==3) o +7 (==7)
                if (cpu_reg[2:0]==3'd3 || cpu_reg[2:0]==3'd7) begin
                    // MAME: si (sndregs[offset-1]=end_pos != 0) && (data=len != 0) -> activar
                    if (sndregs[cpu_reg[5:0] - 6'd1] != 16'd0 && cpu_wdata != 16'd0) begin
                        active[cpu_reg[5:3]] <= 1'b1;
                        loop[cpu_reg[5:3]]   <= 1'b1;
                        if (!active[cpu_reg[5:3]]) chunkNum[cpu_reg[5:3]] <= cpu_reg[2];  // chunk 0 o 1
                    end else begin
                        if (cpu_reg[2:0]==3'd3) active[cpu_reg[5:3]] <= 1'b0;
                        else                    loop[cpu_reg[5:3]]   <= 1'b0;
                    end
                end
            end

            case (st)
                IDLE: if (cen) begin accl<=0; accr<=0; ch<=0; st<=CHK; end
                CHK: begin
                    if (active[ch]) begin
                        base   <= {ch, (loop[ch]?chunkNum[ch]:1'b0), 2'b00};  // ch*8 + chunk*4
                        st <= A1SET;
                    end else st <= NXT;
                end
                A1SET: begin
                    vl  <= sndregs[base+6'd1][15:12];
                    vr  <= sndregs[base+6'd1][11:8];
                    typ <= sndregs[base+6'd1][7:4];
                    bank<= sndregs[base+6'd1][1:0];
                    endpos <= {sndregs[base+6'd2], 8'd0} - 24'd1;   // (reg<<8)-1
                    rem <= sndregs[base+6'd3];
                    st <= A1WAIT;
                end
                A1WAIT: begin
                    rom_addr <= saddr[21:0]; rom_cs <= 1'b1;
                    if (rom_ok) begin
                        data1 <= selbyte(rom_data, bank);
                        rom_cs <= 1'b0;
                        st <= VL;
                    end
                end
                VL:  begin vol_a <= {vl, data1}; st <= VLB; end       // present voltab[vol_l][data1]
                VLB: st <= VLW;                                       // burbuja (latencia BRAM 1 ciclo)
                VLW: begin
                    chl <= (typ==4'h8 || typ==4'hc) ? vol_q : 16'sd0;
                    rem <= rem - 16'd1;                               // restantes--
                    st  <= RDEC;
                end
                RDEC: begin
                    if (typ==4'h8) begin                              // mono: R = voltab[vol_r][data1]
                        vol_a <= {vr, data1}; st <= VR;
                    end else if (typ==4'hc) begin                     // estéreo: 2º byte si rem>0
                        if (rem != 16'd0) begin st <= A2WAIT; end
                        else begin chr <= 16'sd0; st <= ACC; end
                    end else begin                                    // tipo desconocido: sin salida
                        chl <= 16'sd0; chr <= 16'sd0; st <= ACC;
                    end
                end
                A2WAIT: begin
                    rom_addr <= saddr[21:0]; rom_cs <= 1'b1;          // elemento end_pos+rem (ya decrementado)
                    if (rom_ok) begin
                        vol_a <= {vr, selbyte(rom_data, bank)};
                        rom_cs <= 1'b0;
                        rem <= rem - 16'd1;                           // 2º decremento
                        st <= VR;
                    end
                end
                VR:  st <= VRW;                                       // espera dato de voltab
                VRW: begin chr <= vol_q; st <= ACC; end
                ACC: begin
                    accl <= accl + {{16{chl[15]}}, chl};
                    accr <= accr + {{16{chr[15]}}, chr};
                    // escribir 'rem' decrementado y gestionar fin/loop
                    sndregs[base+6'd3] <= rem;
                    if (rem == 16'd0) begin
                        if (loop[ch]==1'b0) active[ch] <= 1'b0;
                        else begin
                            chunkNum[ch] <= ~chunkNum[ch];
                            // si el siguiente chunk tiene len 0 -> fin
                            if (sndregs[{ch, ~chunkNum[ch], 2'b11}] == 16'd0) active[ch] <= 1'b0;
                        end
                    end
                    st <= NXT;
                end
                NXT: begin
                    if (ch == 3'd6) st <= OUTP;
                    else begin ch <= ch + 3'd1; st <= CHK; end
                end
                OUTP: begin
                    // clip a 16 bits con signo (16'sh8000 = -32768; -16'sd32768 desborda el literal)
                    snd_l <= (accl > 32'sd32767) ? 16'sh7fff : (accl < -32'sd32768) ? 16'sh8000 : accl[15:0];
                    snd_r <= (accr > 32'sd32767) ? 16'sh7fff : (accr < -32'sd32768) ? 16'sh8000 : accr[15:0];
                    sample <= 1'b1;
                    st <= IDLE;
                end
                default: st <= IDLE;
            endcase
        end
    end

    // synthesis translate_off
    initial begin st=IDLE; rom_cs=0; sample=0; ch=0; snd_l=0; snd_r=0;
        for (i=0;i<7;i=i+1) begin active[i]=0; loop[i]=0; chunkNum[i]=0; end
        for (i=0;i<56;i=i+1) sndregs[i]=0; end
    // synthesis translate_on
endmodule

`default_nettype wire
