// ============================================================================
//  World Rally 2: Twin Racing (Gaelco, Tipo-2 / chip GAE1) — Motor de SPRITES por LINEA.
//
//  Base: aligator_gae1_sprite (clk96 + pipeline de escritura, validado en HW). Lista de 512 entradas
//  de 4 words (8 bytes) en VRAM byte `(vregs[1]&0x10)*0x100`. Se itera FORWARD 0..511 -> "last write
//  wins" (indice ALTO = encima). Por entrada:
//    w0(data) : [8:0]=bank, [15:9]=color base (7b), [15]=SELECTOR DE MONITOR (1=monitor derecho)
//    w1(data2): [8:0]=y, [9]=enable, [10]=yflip, [11]=xflip, [15:12]=ysize-1
//    w2(data3): [9:0]=x, [15:12]=xsize-1
//    w3(data4): puntero (BYTE) a los datos de celda
//  Cada celda: data5 = vram[(w3/2 + cy_data*xsize + cx) & 0x7fff];
//    number=((bank&0x1ff)<<10)+(data5&0xfff) ; color=color_base+((data5>>12)&0xf).
//    color_effect (sombra) = (color&0x3f==0x7f -> ==0x7f): var=pen (0..15); pen>=16 NO pinta.
//
//  DIFERENCIAS WR2 vs aligator (2026-06-26):
//   - MONITOR ÚNICO IZQUIERDO (index=0): se SALTAN los sprites con w0[15]=1 (monitor derecho).
//   - 5bpp REAL (plano4=ic68): por cada mitad (izq col0-7, der col8-15) se hacen DOS lecturas DW32 en
//     el MISMO puerto: rom_a[21]=0 -> {p0,p1,p2,p3}; rom_a[21]=1 -> {p4,0,0,0} (plano4=byte0). pen 5b.
//   - elemento gfx = number[15:0] (ELEMS=2MB/32=65536). rom_a = {p4sel, number[15:0], half, gpy}.
//   - spr_x_adjust (visarea 384) = -126 - vregs[0][4]. Ancho visible 384.
//
//  Line buffer (17b): {valid, var[3:0], idx[11:0]}. idx = color*32+pen (>=1 si pintado). var = variante
//    de sombra (0=normal). Doble buffer ping-pong (render N+1 mientras se muestra N).
// ============================================================================
`default_nettype none

module wrally2_gae1_sprite #(
    // Profundidad del line-buffer. DOBLE MOTOR (twin=0 por instancia, per-monitor): cada motor escribe sólo
    // 0..383 -> 512 SOBRA y HALA los muxes async (FIT). MOTOR ÚNICO con twin interno (escribe 0..767): 1024.
    parameter LBDEPTH = 512
)(
    input  wire        clk,
    input  wire        ce,
    input  wire        start,        // pulso: renderiza la linea `line`
    input  wire [8:0]  line,         // screenY a renderizar (0..239)
    input  wire        index,        // single: pantalla 0=izquierda (bit15==0), 1=derecha (bit15==1)
    input  wire        twin,         // 1=TWIN: pinta AMBOS subsets (bit15==0 en X, bit15==1 en X+384) -> lb 768
    input  wire [15:0] vreg0, vreg1, // 0x218004/6: spr_x_adjust (vreg0[4]) + base lista (vreg1[4])
    output reg         busy,

    // VRAM word (lista + indireccion). spr_a COMBINACIONAL, 1 estado ANTES del que lee spr_q.
    output reg  [14:0] spr_a,
    input  wire [15:0] spr_q,

    // gfx ROM (slot SDRAM gfxs, DW32). Se usa para 4 lecturas/celda (izq/der x planos0-3/plano4).
    output reg  [21:0] rom_a,
    input  wire [7:0]  d_p0, d_p1, d_p2, d_p3,
    input  wire        gfx_ok,

    // line buffer: lectura async para el compositor (X visible 0..383 single / 0..767 twin)
    input  wire [9:0]  lb_x,
    output wire [16:0] lb_q,         // {valid, var[3:0], idx[11:0]}

    input  wire        wbank,
    input  wire        rbank
);
    // EARLY-OUT: RDW1F lee w1 PRIMERO (en/sy/ysize) -> filtra disabled/no-cubiertos sin leer w0/w2/w3.
    localparam [4:0] IDLE=0, CLR=1, RDW1F=2, RDW0=3, RDW2=4, RDW3=5, SETUP=6,
                     D5ADR=7, D5RD=8, FSETL=9, FWL=10, FSETL4=11, FWL4=12,
                     FSETR=13, FWR=14, FSETR4=15, FWR4=16, PWR=17, NEXT=18, DON=19;

    reg [4:0]  state;
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

    // buffers de gfx de la fila (mitad izq [0..7] y der [8..15]) -> 5 planos c/u
    reg [7:0]  gl0,gl1,gl2,gl3,gl4, gr0,gr1,gr2,gr3,gr4;

    // ---- line buffer doble M10K (2 x LBDEPTH x 17) — LECTURA REGISTRADA (fix timing -3.196 + área) ----
    // Cada banco = 1W1R: escribe sólo el wbank; su puerto de lectura lee lb_wa (RMW, si es el wbank) o lb_x
    // (salida, si es el rbank). Registrar las lecturas -> Quartus infiere M10K -> decode de escritura por HW
    // (camino corto, pasa 96MHz) y saca el lb de las LUTs. El RMW de sombra pasa a PIPELINE (lectura registrada).
    localparam LBAW = $clog2(LBDEPTH);
    (* ramstyle = "no_rw_check, M10K" *) reg [16:0] lb0 [0:LBDEPTH-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [16:0] lb1 [0:LBDEPTH-1];
    wire        is0w   = (wbank_r==1'b0);                          // lb0 = banco de render (write+RMW) esta línea
    wire [LBAW-1:0] lb0_ra = is0w ? lb_wa[LBAW-1:0] : lb_x[LBAW-1:0];
    wire [LBAW-1:0] lb1_ra = is0w ? lb_x[LBAW-1:0]  : lb_wa[LBAW-1:0];
    reg  [16:0] lb0_rq, lb1_rq;                                    // lecturas registradas (M10K)
    assign      lb_q   = rbank ? lb1_rq : lb0_rq;                  // salida = banco de display (rbank), registrada

    // ---- base de la lista de sprites + spr_x_adjust ----
    wire [14:0] base_word = vreg1[4] ? 15'h800 : 15'h0;          // (vregs[1]&0x10)*0x100/2
    wire signed [11:0] spradj = -12'sd126 - {11'b0, vreg0[4]};   // wrally2 single-monitor (384)

    // ---- columna de celda con flip + base x de la celda (de la celda en FETCH) ----
    wire [4:0] ex      = xflip ? (xsize - 5'd1 - cx) : cx;
    wire [9:0] bx_cell = (sx0 + {1'b0, ex, 4'b0}) & 10'h3ff;     // (sx0 + ex*16) & 0x3ff
    // offset de monitor (twin): el sprite del monitor derecho (color_base[6]) se escribe en X+384.
    wire signed [11:0] xoff_cell = (twin & color_base[6]) ? 12'sd384 : 12'sd0;

    // ===== PREFETCH (doble-buffer de celda) =====
    // El FSM FETCHEA en gl/gr; al terminar (FWR4) hace SNAPSHOT a gld/grd + params y lanza el DIBUJADO
    // PARALELO (px_d). Así los 16px de dibujo se SOLAPAN con las 4 lecturas SDRAM de la celda SIGUIENTE
    // (fetch>>dibujo) -> el pwr queda escondido bajo el fetch -> menos/ningún overrun en twin. Mismo
    // resultado pixel-exacto (orden de escritura preservado: el dibujo va 1 celda por detrás del fetch).
    reg [7:0]  gld0,gld1,gld2,gld3,gld4, grd0,grd1,grd2,grd3,grd4;   // snapshot de planos a dibujar
    reg signed [11:0] cx0_d, xoff_d; reg [11:0] idx_d; reg shadow_d, xflip_d;
    reg [3:0]  px_d; reg draw_busy; reg draw_start;

    // ---- pixel a DIBUJAR (del draw-buffer, contador paralelo px_d) — pen 5 bits {p4,p3,p2,p1,p0} ----
    wire [3:0] gpx   = xflip_d ? (4'd15 - px_d) : px_d;
    wire [2:0] bsel  = 3'd7 - gpx[2:0];
    wire [7:0] p0b   = gpx[3] ? grd0 : gld0;                     // mitad der/izq
    wire [7:0] p1b   = gpx[3] ? grd1 : gld1;
    wire [7:0] p2b   = gpx[3] ? grd2 : gld2;
    wire [7:0] p3b   = gpx[3] ? grd3 : gld3;
    wire [7:0] p4b   = gpx[3] ? grd4 : gld4;
    wire [4:0] pen   = {p4b[bsel], p3b[bsel], p2b[bsel], p1b[bsel], p0b[bsel]};
    wire signed [11:0] xraw  = cx0_d + $signed({8'b0, px_d});    // X (clip por monitor 0..383)
    wire       xin   = (xraw >= 0) && (xraw < 12'sd384);
    wire [9:0] lb_wa = (xraw + xoff_d);

    // ---- RMW de sombra PIPELINE (lectura registrada M10K) ----
    // stage0 = pixel actual (PWR): presenta lb_wa al puerto de lectura (combinacional) y latchea el pixel.
    // stage1 = lb_cur (registrado) disponible -> computa lb_new. stage2 = escribe el line buffer.
    // sombra solo pinta pen 1..15 (pen>=16 NO pinta, como el golden); normal pinta pen 1..31.
    wire       pen_ok   = shadow_d ? (pen != 5'd0 && !pen[4]) : (pen != 5'd0);
    wire       do_write = draw_busy && pen_ok && xin;            // stage0: el dibujado PARALELO está activo
    reg        dw_s1, sh_s1; reg [4:0] pen_s1; reg [11:0] idx_s1; reg [LBAW-1:0] wa_s1;  // stage0 -> 1
    reg        dw_s2; reg [16:0] wd_s2; reg [LBAW-1:0] wa_s2;                             // stage1 -> 2
    reg        clr_we_q; reg [LBAW-1:0] clr_wa_q;                                         // CLR registrado
    wire [16:0] lb_cur  = is0w ? lb0_rq : lb1_rq;                 // RMW = lectura registrada del wbank
    wire [16:0] lb_new  = sh_s1
        ? {1'b1, pen_s1[3:0], (lb_cur[16] ? lb_cur[11:0] : 12'd0)}  // sombra: var=pen[3:0]; conserva idx bajo
        : {1'b1, 4'd0, (idx_s1 | {7'b0, pen_s1})};                  // normal: color*32 + pen (pen 5b)

    // ---- direccion gfx de la fila = {p4sel, number[15:0], half, gpy} ----
    wire [21:0] rom_a_l  = {1'b0, number[15:0], 1'b0, gpy};   // izq (col 0..7),  planos 0-3
    wire [21:0] rom_a_l4 = {1'b1, number[15:0], 1'b0, gpy};   // izq,             plano 4
    wire [21:0] rom_a_r  = {1'b0, number[15:0], 1'b1, gpy};   // der (col 8..15), planos 0-3
    wire [21:0] rom_a_r4 = {1'b1, number[15:0], 1'b1, gpy};   // der,             plano 4

    // ---- coverage del sprite ----
    wire [8:0]  rely    = (line_r - sy0) & 9'h1ff;
    wire        covered = (rely < {ysize, 4'b0});  // rely < ysize*16
    // ---- EARLY-OUT: en/covered COMBINACIONAL desde w1 (spr_q en RDW1F) ----
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

    // ---- line buffer M10K: lecturas registradas (puerto R) + escritura (puerto W) ----
    always @(posedge clk) if (ce) begin
        // puerto de LECTURA de cada banco (registrado -> infiere M10K). lb0_ra/lb1_ra = lb_wa (RMW) o lb_x (salida)
        lb0_rq <= lb0[lb0_ra];
        lb1_rq <= lb1[lb1_ra];
        // RMW pipeline: stage0->1 (latch del pixel) ; stage1->2 (lb_new ya usa lb_cur registrado de stage1)
        dw_s1 <= do_write; sh_s1 <= shadow_d; pen_s1 <= pen; idx_s1 <= idx_d; wa_s1 <= lb_wa[LBAW-1:0];
        dw_s2 <= dw_s1;    wd_s2 <= lb_new;       wa_s2  <= wa_s1;
        // CLR registrado: saca el state.CLR (camino crítico -3.196) del path de escritura del lb
        clr_we_q <= (state==CLR); clr_wa_q <= clr_i[LBAW-1:0];
        // puerto de ESCRITURA (sólo el wbank): CLR tiene prioridad; si no, el pixel drenado del pipeline (stage2)
        if (clr_we_q) begin
            if (is0w) lb0[clr_wa_q] <= 17'd0; else lb1[clr_wa_q] <= 17'd0;
        end else if (dw_s2) begin
            if (is0w) lb0[wa_s2] <= wd_s2; else lb1[wa_s2] <= wd_s2;
        end
    end

    // ---- DIBUJADO PARALELO (prefetch): px_d 0..15 mientras el FSM fetchea la celda siguiente ----
    // El FSM hace snapshot + pulsa draw_start (FWR4); este bloque dibuja los 16px (sin bloquear el FSM).
    always @(posedge clk) if (ce) begin
        if (start)           draw_busy <= 1'b0;   // nueva línea: aborta el dibujo en vuelo (FSM->CLR). El
                                                  // pipeline drena bajo la prioridad del CLR -> sin escritura espuria.
        else if (draw_start) begin px_d <= 4'd0; draw_busy <= 1'b1; end
        else if (draw_busy)  begin
            if (px_d == 4'd15) draw_busy <= 1'b0;
            else               px_d <= px_d + 4'd1;
        end
    end

    // ---- PROFILING de presupuesto por línea (sim-only) ----
    // synthesis translate_off
    `ifdef WRALLY2_SPRPROF
    integer c_clr=0, c_fetch=0, c_pwr=0, c_iter=0, c_cells=0;
    always @(posedge clk) if (ce && !start) begin
        if (state==CLR) c_clr <= c_clr+1;
        else if (state>=FSETL && state<=FWR4) c_fetch <= c_fetch+1;   // 8 estados de fetch (4 lecturas)
        else if (state!=IDLE && state!=DON) c_iter <= c_iter+1;
        if (draw_busy) c_pwr <= c_pwr+1;        // dibujado PARALELO (solapado con el fetch -> ya no en serie)
        if (draw_start) c_cells <= c_cells+1;
    end
    `endif
    // synthesis translate_on

    // ---- FSM ----
    always @(posedge clk) if (ce) begin
        draw_start <= 1'b0;                 // pulso de 1 ciclo (se pone a 1 sólo en FWR4)
        if (start) begin
            // synthesis translate_off
            `ifdef WRALLY2_SPRPROF
            if (state != IDLE && state != DON)
                $display("SPRCUT line=%0d cut spr_e=%0d st=%0d | clr=%0d fetch=%0d pwr=%0d iter=%0d cells=%0d tot=%0d",
                         line_r, spr_e, state, c_clr, c_fetch, c_pwr, c_iter, c_cells, c_clr+c_fetch+c_pwr+c_iter);
            else
                $display("SPROK  line=%0d fin spr_e=%0d | clr=%0d fetch=%0d pwr=%0d iter=%0d cells=%0d tot=%0d",
                         line_r, spr_e, c_clr, c_fetch, c_pwr, c_iter, c_cells, c_clr+c_fetch+c_pwr+c_iter);
            c_clr<=0; c_fetch<=0; c_pwr<=0; c_iter<=0; c_cells<=0;
            `endif
            // synthesis translate_on
            line_r <= line; clr_i <= 10'd0; busy <= 1'b1; wbank_r <= wbank; state <= CLR;
        end else case (state)
            IDLE: ;
            CLR: begin
                clr_i <= clr_i + 1'b1;
                if (clr_i == (twin ? 10'd767 : 10'd383)) begin spr_e <= 10'd0; state <= RDW1F; end
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
                // TWIN: dibuja ambos subsets (no salta). SINGLE: salta el sprite de la otra pantalla.
                state <= (~twin & (spr_q[15] != index)) ? NEXT : RDW2;
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
                cell_shadow <= (((color_base + {3'b0, spr_q[15:12]}) & 7'h3f) == 7'h3f); // (color&0x3f)==0x3f
                state <= FSETL;
            end
            // 4 lecturas: izq planos0-3, izq plano4, der planos0-3, der plano4 (gap entre cada par)
            FSETL:  begin rom_a <= rom_a_l;  state <= FWL; end
            // planos 2,3 = 0 en la zona GAP (number[15]=1 -> element[20]=1): el .mra reusa ic70 ahí como don't-care. No-op en sim.
            FWL:    if (gfx_ok) begin gl0<=d_p0; gl1<=d_p1; gl2<=number[15]?8'd0:d_p2; gl3<=number[15]?8'd0:d_p3; rom_a<=rom_a_l4; state<=FSETL4; end
            FSETL4: state <= FWL4;
            FWL4:   if (gfx_ok) begin gl4<=d_p0; rom_a<=rom_a_r; state<=FSETR; end
            FSETR:  state <= FWR;
            FWR:    if (gfx_ok) begin gr0<=d_p0; gr1<=d_p1; gr2<=number[15]?8'd0:d_p2; gr3<=number[15]?8'd0:d_p3; rom_a<=rom_a_r4; state<=FSETR4; end
            FSETR4: state <= FWR4;
            // fin del fetch: SNAPSHOT del draw-buffer + params, lanza el dibujado PARALELO, y AVANZA (el FSM
            // sigue fetcheando la celda/sprite siguiente mientras este dibujo corre). Espera draw_busy=0
            // (normalmente ya libre: el fetch ~60clk >> dibujo 16clk).
            FWR4:   if (gfx_ok && !draw_busy) begin
                       gr4<=d_p0;
                       gld0<=gl0; gld1<=gl1; gld2<=gl2; gld3<=gl3; gld4<=gl4;
                       grd0<=gr0; grd1<=gr1; grd2<=gr2; grd3<=gr3; grd4<=d_p0;
                       cx0_d   <= $signed({2'b0, bx_cell}) + spradj;
                       idx_d   <= cell_idx; shadow_d <= cell_shadow; xflip_d <= xflip; xoff_d <= xoff_cell;
                       draw_start <= 1'b1;
                       if (cx + 5'd1 < xsize) begin cx <= cx + 5'd1; state <= D5ADR; end
                       else state <= NEXT;
                   end
            NEXT: if (spr_e < 10'd511) begin
                      spr_e <= spr_e + 10'd1;
                      state <= RDW1F;
                  end else state <= DON;
            // DON: no terminar hasta que el dibujado PARALELO + el pipeline de escritura hayan DRENADO
            // (si no, los últimos pixeles del último sprite no se escribirían).
            DON:  if (!draw_busy && !dw_s1 && !dw_s2) begin busy <= 1'b0; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end

    // synthesis translate_off
    integer k;
    initial begin state=IDLE; busy=0; spr_e=0; px=0; clr_i=0; wbank_r=0; cx=0; number=0;
        dw_s1=0; dw_s2=0; clr_we_q=0; lb0_rq=0; lb1_rq=0; wd_s2=0; wa_s2=0;
        draw_busy=0; draw_start=0; px_d=0;
        for (k=0;k<LBDEPTH;k=k+1) begin lb0[k]=0; lb1[k]=0; end end
    // synthesis translate_on
endmodule

`default_nettype wire
