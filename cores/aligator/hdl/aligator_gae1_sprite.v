// ============================================================================
//  Alligator Hunt (Gaelco, Tipo-2 / chip GAE1) — Motor de SPRITES por LINEA.
//
//  Modelo MAME (gaelco2_v.cpp draw_sprites, single-monitor): lista de 512 entradas de 4 words
//  (8 bytes) en VRAM byte `(vregs[1]&0x10)*0x100`. Se itera FORWARD 0..511 -> "last write wins"
//  (indice ALTO = encima). Por entrada:
//    w0(data) : [8:0]=bank (bits 18-10 del nº de tile), [15:9]=color base (7b)
//    w1(data2): [8:0]=y, [9]=enable, [10]=yflip, [11]=xflip, [15:12]=ysize-1
//    w2(data3): [9:0]=x, [15:12]=xsize-1
//    w3(data4): puntero (BYTE) a los datos de celda
//  Cada celda (cy,cx de ysize*xsize): data5 = vram[(w3/2 + cy_data*xsize + cx) & 0x7fff];
//    number=((bank&0x1ff)<<10)+(data5&0xfff) ; color=color_base+((data5>>12)&0xf).
//    color_effect (sombra) = (color==0x7f): NO pinta; RMW del fondo new=(bg&0xfff)|(pen<<12).
//  gfx: tile 16x16 5bpp (plano4=0 -> pen 0..15). rom_a (elemento DW32) = number*32 + half*16 + row
//    (= mismo esquema que aligator_gae1_tilemap, blob ya validado pixel-perfect). pen 0 = transparente.
//  Geometria: ex=xflip?xsize-1-cx:cx ; ey=yflip?ysize-1-cy:cy ; bx=((x+ex*16)&0x3ff)+spr_x_adjust ;
//    by=((y+ey*16)&0x1ff). spr_x_adjust (alighunt) = (319-319) - 190 - vregs[0][4] = -190-vregs[0][4].
//
//  Line buffer (17b): {valid, var[3:0], idx[11:0]}. idx = color*32+pen (>=1 si pintado). var = variante
//    de sombra (0=normal). RMW de sombra: si bajo el pixel hay sprite normal conserva su idx; si no,
//    idx=0 (el compositor aplica la variante al TILEMAP). Doble buffer ping-pong (render N+1 mientras N).
// ============================================================================
`default_nettype none

module aligator_gae1_sprite (
    input  wire        clk,
    input  wire        ce,
    input  wire        start,        // pulso: renderiza la linea `line`
    input  wire [8:0]  line,         // screenY a renderizar (0..239)
    input  wire [15:0] vreg0, vreg1, // 0x218004/6: spr_x_adjust (vreg0[4]) + base lista (vreg1[4])
    output reg         busy,

    // VRAM word (lista + indireccion). Lectura REGISTRADA +1: spr_a COMBINACIONAL, presentada
    // 1 estado ANTES del estado que lee spr_q (como el motor Tipo-1).
    output reg  [14:0] spr_a,
    input  wire [15:0] spr_q,

    // gfx ROM (slot SDRAM gfxs, DW32 -> 4 planos ya separados)
    output reg  [21:0] rom_a,
    input  wire [7:0]  d_p0, d_p1, d_p2, d_p3,
    input  wire        gfx_ok,

    // line buffer: lectura async para el compositor (por X visible 0..319)
    input  wire [8:0]  lb_x,
    output wire [16:0] lb_q,         // {valid, var[3:0], idx[11:0]}

    input  wire        wbank,
    input  wire        rbank
);
    // EARLY-OUT: RDW1F lee w1 PRIMERO (en/sy/ysize) -> filtra disabled/no-cubiertos sin leer w0/w2/w3.
    localparam [3:0] IDLE=0, CLR=1, RDW1F=2, RDW0=3, RDW2=4, RDW3=5, SETUP=6,
                     D5ADR=7, D5RD=8, FSETL=9, FWL=10, FSETR=11, FWR=12, PWR=13, NEXT=14, DON=15;

    reg [3:0]  state;
    reg [9:0]  spr_e;          // entrada de sprite (0..511) -> word = base + spr_e*4
    reg [9:0]  clr_i;
    reg [8:0]  line_r;
    reg        wbank_r;

    // --- campos latcheados de la entrada ---
    reg [8:0]  bank_hi;        // w0[8:0]
    reg [6:0]  color_base;     // w0[15:9]
    reg [8:0]  sy0;            // w1[8:0]
    reg        en_r;           // w1[9] enable
    reg        yflip, xflip;
    reg [4:0]  ysize, xsize;   // 1..16
    reg [9:0]  sx0;            // w2[9:0]
    reg [14:0] ptr_w;          // w3/2 (word)
    reg [3:0]  ydata;          // fila de celda en datos (con yflip)
    reg [3:0]  gpy;            // fila gfx dentro del tile (con yflip)

    // --- celda en curso ---
    reg [4:0]  cx;             // columna de celda (0..xsize-1)
    reg [11:0] cell_idx;       // color*32 (base; + pen al escribir)
    reg        cell_shadow;
    reg [16:0] number;         // nº de tile (17b)
    reg [3:0]  px;             // pixel dentro de la celda (0..15)
    reg [9:0]  bx;             // screenX base de la celda ((sx0+ex*16)&0x3ff)
    reg signed [11:0] cell_x0; // bx + spradj precomputado (acorta el path px->lb a clk96)
    reg [8:0]  row_off;        // ydata*xsize precomputado (saca el multiply del path d5_addr a clk96)

    // buffers de gfx de la fila (mitad izq [0..7] y der [8..15]) -> 4 planos c/u
    reg [7:0]  gl0,gl1,gl2,gl3, gr0,gr1,gr2,gr3;

    // ---- line buffer doble (2 x 320 x 17) ----
    reg [16:0] lb0 [0:319];
    reg [16:0] lb1 [0:319];
    assign lb_q = rbank ? lb1[lb_x] : lb0[lb_x];

    // ---- base de la lista de sprites + spr_x_adjust ----
    wire [14:0] base_word = vreg1[4] ? 15'h800 : 15'h0;          // (vregs[1]&0x10)*0x100/2
    wire signed [11:0] spradj = -12'sd190 - {11'b0, vreg0[4]};   // alighunt single-monitor

    // ---- columna de celda con flip + base x de la celda ----
    wire [4:0] ex      = xflip ? (xsize - 5'd1 - cx) : cx;
    wire [9:0] bx_cell = (sx0 + {1'b0, ex, 4'b0}) & 10'h3ff;     // (sx0 + ex*16) & 0x3ff

    // ---- pixel actual (combinacional) ----
    wire [3:0] gpx   = xflip ? (4'd15 - px) : px;               // columna gfx (con xflip)
    wire [2:0] bsel  = 3'd7 - gpx[2:0];                          // bit dentro del byte
    wire [7:0] p0b   = gpx[3] ? gr0 : gl0;                       // mitad der/izq
    wire [7:0] p1b   = gpx[3] ? gr1 : gl1;
    wire [7:0] p2b   = gpx[3] ? gr2 : gl2;
    wire [7:0] p3b   = gpx[3] ? gr3 : gl3;
    wire [3:0] pen   = {p3b[bsel], p2b[bsel], p1b[bsel], p0b[bsel]}; // plano4=0 -> pen 0..15
    wire signed [11:0] xpos_s = cell_x0 + $signed({8'b0, px});   // cell_x0 = bx+spradj precomputado
    wire       xin   = (xpos_s >= 0) && (xpos_s < 12'sd320);
    wire [8:0] lb_wa = xpos_s[8:0];

    // ---- RMW de sombra: leer la entrada actual del banco de escritura ----
    wire [16:0] lb_cur = wbank_r ? lb1[lb_wa] : lb0[lb_wa];
    wire [16:0] lb_new = cell_shadow
        ? {1'b1, pen, (lb_cur[16] ? lb_cur[11:0] : 12'd0)}      // sombra: conserva idx bajo si habia sprite
        : {1'b1, 4'd0, (cell_idx | {8'b0, pen})};               // normal: color*32 + pen
    wire       do_write = (state==PWR) && (pen != 4'd0) && xin;

    // ---- direccion gfx de la fila (elemento DW32) = number*32 + half*16 + gpy ----
    wire [21:0] rom_a_l = {number, 1'b0, gpy};   // mitad izq (col 0..7)
    wire [21:0] rom_a_r = {number, 1'b1, gpy};   // mitad der (col 8..15)

    // ---- coverage del sprite (latcheado, para ydata/gpy en SETUP) ----
    wire [8:0]  rely    = (line_r - sy0) & 9'h1ff;
    wire        covered = (rely < {ysize, 4'b0});  // rely < ysize*16
    // ---- EARLY-OUT: en/covered COMBINACIONAL desde w1 (spr_q en RDW1F) antes de leer w0/w2/w3 ----
    wire [8:0]  sy0_w     = spr_q[8:0];
    wire [4:0]  ysize_w   = {1'b0, spr_q[15:12]} + 5'd1;
    wire [8:0]  rely_w    = (line_r - sy0_w) & 9'h1ff;
    wire        proceed_w = spr_q[9] & (rely_w < {ysize_w, 4'b0});   // enable && cubierto en esta línea

    // ---- spr_a COMBINACIONAL: dir presentada 1 estado ANTES del estado que lee spr_q ----
    wire [14:0] d5_addr = (ptr_w + {6'b0, row_off} + {10'b0, cx}) & 15'h7fff;  // row_off=ydata*xsize precomp.
    always @(*) begin
        case (state)
            CLR:   spr_a = base_word + 15'd1;                     // w1 entrada 0 (leida en RDW1F)
            RDW1F: spr_a = base_word + {3'b0, spr_e, 2'b00};      // w0 (en RDW0) [solo si proceed]
            RDW0:  spr_a = base_word + {3'b0, spr_e, 2'b10};      // w2 (en RDW2)
            RDW2:  spr_a = base_word + {3'b0, spr_e, 2'b11};      // w3 (en RDW3)
            D5ADR: spr_a = d5_addr;                               // data5 (D5RD)
            NEXT:  spr_a = base_word + {3'b0, (spr_e + 10'd1), 2'b01}; // w1 sig. entrada (en RDW1F)
            default: spr_a = base_word + {3'b0, spr_e, 2'b00};
        endcase
    end

    // ---- escritura del line buffer (PIPELINE 1 ciclo: corta el path px->lb a clk96) ----
    // Stage 1: latcha el pixel computado (wr/addr/dato). Stage 2 (ciclo sig.): escribe el lb.
    // SEGURO: dentro de un sprite cada px escribe una X DISTINTA (xpos monotónico) -> la escritura
    // retrasada no aliasa con el RMW (lb_cur lee otra dirección) ni consigo misma. CLR sin pipeline.
    reg        wr_q;
    reg [8:0]  lb_wa_q;
    reg [16:0] lb_new_q;
    always @(posedge clk) if (ce) begin
        wr_q     <= do_write;       // do_write=0 fuera de PWR -> no escribe espurio
        lb_wa_q  <= lb_wa;
        lb_new_q <= lb_new;
        if (state==CLR) begin
            if (wbank_r) lb1[clr_i[8:0]] <= 17'd0; else lb0[clr_i[8:0]] <= 17'd0;
        end else if (wr_q) begin
            if (wbank_r) lb1[lb_wa_q] <= lb_new_q; else lb0[lb_wa_q] <= lb_new_q;
        end
    end

    // ---- FSM ----
    always @(posedge clk) if (ce) begin
        if (start) begin
            line_r <= line; clr_i <= 10'd0; busy <= 1'b1; wbank_r <= wbank; state <= CLR;
        end else case (state)
            IDLE: ;
            CLR: begin
                clr_i <= clr_i + 1'b1;
                if (clr_i == 10'd319) begin spr_e <= 10'd0; state <= RDW1F; end
            end
            // EARLY-OUT: w1 PRIMERO -> filtra en/covered antes de leer w0/w2/w3
            RDW1F: begin // spr_q = w1
                sy0   <= spr_q[8:0]; en_r <= spr_q[9];
                yflip <= spr_q[10]; xflip <= spr_q[11];
                ysize <= {1'b0, spr_q[15:12]} + 5'd1;
                state <= proceed_w ? RDW0 : NEXT;   // descarta disabled/no-cubiertos en ~2 clk
            end
            RDW0: begin // spr_q = w0
                bank_hi <= spr_q[8:0]; color_base <= spr_q[15:9];
                state <= RDW2;
            end
            RDW2: begin // spr_q = w2
                sx0   <= spr_q[9:0];
                xsize <= {1'b0, spr_q[15:12]} + 5'd1;
                state <= RDW3;
            end
            RDW3: begin // spr_q = w3 (puntero byte)
                ptr_w <= spr_q[15:1];            // /2 -> word
                state <= SETUP;
            end
            SETUP: begin
                ydata   <= yflip ? (ysize[3:0] - 4'd1 - rely[7:4]) : rely[7:4];
                // row_off = ydata*xsize PRECOMPUTADO (registrado) -> saca el multiply del path d5_addr (clk96)
                row_off <= (yflip ? (ysize[3:0] - 4'd1 - rely[7:4]) : rely[7:4]) * xsize;
                gpy     <= yflip ? (4'd15 - rely[3:0])             : rely[3:0];
                cx      <= 5'd0;
                state   <= D5ADR;   // ya filtrado en RDW1F (en && covered)
            end
            // ---- bucle de celdas (columna cx); spr_a=d5_addr combinacional ----
            D5ADR: state <= D5RD;
            D5RD: begin // spr_q = data5
                number      <= {bank_hi, 10'b0} + {7'b0, spr_q[11:0]};       // (bank<<10)+(data5&0xfff), trunc 17b
                cell_idx    <= {(color_base + {3'b0, spr_q[15:12]}), 5'b0};  // (color)*32
                cell_shadow <= ((color_base + {3'b0, spr_q[15:12]}) == 7'h7f);
                state <= FSETL;
            end
            FSETL: begin rom_a <= rom_a_l; state <= FWL; end
            FWL:   if (gfx_ok) begin gl0<=d_p0; gl1<=d_p1; gl2<=d_p2; gl3<=d_p3; rom_a<=rom_a_r; state<=FSETR; end
            FSETR: state <= FWR;
            FWR:   if (gfx_ok) begin gr0<=d_p0; gr1<=d_p1; gr2<=d_p2; gr3<=d_p3; px<=4'd0; bx<=bx_cell;
                       cell_x0 <= $signed({2'b0, bx_cell}) + spradj;   // precompute bx+spradj (path px->lb)
                       state<=PWR; end
            PWR: begin
                if (px == 4'd15) begin
                    if (cx + 5'd1 < xsize) begin cx <= cx + 5'd1; state <= D5ADR; end
                    else state <= NEXT;
                end else px <= px + 4'd1;
            end
            NEXT: if (spr_e < 10'd511) begin
                      spr_e <= spr_e + 10'd1;
                      state <= RDW1F;
                  end else state <= DON;
            DON:  begin busy <= 1'b0; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end

    // synthesis translate_off
    integer k;
    initial begin state=IDLE; busy=0; spr_e=0; px=0; clr_i=0; wbank_r=0; cx=0; number=0; wr_q=0;
        for (k=0;k<320;k=k+1) begin lb0[k]=0; lb1[k]=0; end end
    // synthesis translate_on
endmodule

`default_nettype wire
