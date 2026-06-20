// ============================================================================
//  World Rally (Gaelco) — Motor de SPRITES por LINEA (line buffer síncrono)
//
//  Renderiza UNA línea de pantalla a un LINE BUFFER. El mezclador lee el buffer
//  por X (= sx visible) y, si el pen != 0, pinta el sprite (paleta 0x200+...).
//
//  Modelo de MAME (gaelco_wrally_sprites.cpp draw_sprites), 4 words/sprite, lista
//  recorrida i = 3,7,..,2043 (i<(0x1000-6)/2), 3 words usados:
//    w0(i)  : [7:0]=Y  [14]=flipX [15]=flipY
//    w2(i+2): [9:0]=X  [13:10]=color  [14]=color_effect(sombra, ignorado de momento)
//    w3(i+3): [13:0]=code
//  Geometría: sy=(240-Y)&0xff ; en pantalla py=(line-sy)&0x1ff (visible si <16) ;
//    xpos = ((X+px)&0x3ff - 0x0f)&0x3ff ; recorte X∈[8,375], línea visible Y∈[16,247].
//    flipX/Y sobre px/py. **Último sprite escrito gana** (sobrescribe).
//  (Prioridad alta y sombras: refinamiento posterior con frames golden de juego.)
//
//  Memorias: gfx ROM SÍNCRONA (dir. registrada, 1 ciclo). Sprite RAM async (puerto
//  pequeño). Line buffer: ESCRITURA SÍNCRONA (block-RAM); lectura async para el mix.
// ============================================================================
`default_nettype none

module wrally_sprite_engine (
    input  wire        clk,
    input  wire        ce,
    input  wire        start,        // pulso: renderiza la línea `line`
    input  wire [8:0]  line,         // screenY (16..247)
    output reg         busy,
    output reg         done,         // pulso 1 ciclo al terminar

    // sprite RAM (lectura REGISTRADA, +1 ciclo = BRAM; word index 0..2047)
    output wire [10:0] spr_a,
    input  wire [15:0] spr_q,

    // gfx ROM (lectura registrada, 1 ciclo; o slot SDRAM con gfx_ok)
    output wire [18:0] rom_a,
    input  wire [7:0]  d_i07, d_i09, d_i11, d_i13,
    input  wire        gfx_ok,        // 1 = d_iXX valido para rom_a. Con BRAM de latencia
                                      //     fija (1 ciclo) atar a 1'b1; con SDRAM, el slot
                                      //     lo baja hasta tener el dato -> PADDR espera.

    // line buffer: lectura async para el mezclador
    input  wire [9:0]  lb_x,         // 0..367 (= sx visible)
    output wire [11:0] lb_q,         // {shadow_en, shadowlevel[2:0], color[3:0], pen[3:0]}; pen 0 = transparente
                                     //   shadow_en=1 -> sprite SOMBRA: oscurece el tile de debajo (banco shadowlevel)
    output wire        lb_high,      // high_priority del pixel de sprite (code>=0x3700; MAME gaelco_wrally_sprites:66)

    // DOBLE BUFFER (ping-pong): banco donde RENDERIZAR (wbank, latcheado en start) y
    // banco que se LEE para el mezclador (rbank). Para uso single-buffer: ambos a 0.
    input  wire        wbank,
    input  wire        rbank
);
    localparam [3:0] IDLE=0, CLR=1, RDW0=2, RDW2=3, RDW3=4, TEST=5, PADDR=6, PWR=7, NEXT=8, DON=9;

    reg [3:0]  state;
    reg [10:0] spr_idx;
    reg [9:0]  clr_i;
    reg [8:0]  line_r;
    reg [15:0] w0_r, w2_r, w3_r;
    reg        flipx_r, flipy_r;
    reg [9:0]  sx_r;
    reg [3:0]  color_r, gpy_r, px;
    reg [13:0] code_r;

    // line buffer DOBLE (2 x 368 x 8): escritura síncrona al banco wbank_r, lectura
    // async del banco rbank (para mezclar la línea que se muestra mientras se
    // renderiza la siguiente en el otro banco).
    reg [11:0] lb0 [0:367];          // {shadow_en, shadowlevel[2:0], color[3:0], pen[3:0]}
    reg [11:0] lb1 [0:367];
    reg       lb0h [0:367];          // line buffer paralelo de high_priority (1 bit)
    reg       lb1h [0:367];
    reg       wbank_r;               // banco de escritura (latcheado en start)
    reg       high_r;                // high_priority del sprite actual (latcheado en TEST)
    reg       shad_r;                // color_effect (sombra) del sprite actual (latcheado en TEST)
    assign lb_q    = rbank ? lb1[lb_x[8:0]]  : lb0[lb_x[8:0]];   // [8:0]: array 0..367 (9 bits)
    assign lb_high = rbank ? lb1h[lb_x[8:0]] : lb0h[lb_x[8:0]];

    // ---- direcciones de memoria (combinacionales) ----
    // sprite RAM REGISTRADA (+1 ciclo). Para NO añadir latencia, se presenta la direccion
    // UN CICLO ANTES de capturar: addr0 durante CLR(last)/NEXT, addr1 en RDW0, addr2 en RDW2.
    // Asi las capturas en RDW0/RDW2/RDW3 mantienen el timing original (3 ciclos, sin shift).
    assign spr_a = (state==CLR && clr_i==10'd367) ? 11'd3 :        // 1er sprite: addr0 (=3)
                   (state==NEXT) ? (spr_idx + 11'd4) :             // sig. sprite: addr0
                   (state==RDW0) ? (spr_idx + 11'd2) :             // addr1
                   (state==RDW2) ? (spr_idx + 11'd3) : 11'd0;      // addr2

    wire [3:0] gpx = flipx_r ? (4'd15 - px) : px;       // columna gfx con flipX
    assign rom_a = {code_r, 5'b00000} + {14'b0, gpx[3], gpy_r};

    // ---- decodificación del pixel (válida en PWR, con gfx ya leído) ----
    wire [2:0] bsel = 3'd7 - gpx[2:0];
    wire [3:0] pen  = { d_i07[bsel], d_i09[bsel], d_i11[bsel], d_i13[bsel] };
    wire [9:0] sumx = (sx_r + {6'b0, px}) & 10'h3ff;
    wire [9:0] xpos = (sumx - 10'd15) & 10'h3ff;
    wire       xin  = (xpos >= 10'd8) && (xpos <= 10'd375);

    // ---- SOMBRA (MAME gaelco_wrally_sprites: color_effect): el sprite-sombra NO pinta color, sino
    //      que marca el pixel para oscurecer el tile de debajo. Solo pens 8-15 cuentan;
    //      shadowlevel = pen-8 (= pen[2:0]) selecciona el banco de paleta oscurecido (shadowlevel<<10).
    //      Sprite normal: presente si pen!=0. Sprite sombra: presente si pen>=8 (pen[3]). ----
    wire        spr_on = shad_r ? pen[3] : (pen != 4'd0);
    wire [11:0] lb_wd  = shad_r ? {1'b1, pen[2:0], 8'd0}     // {shadow_en, shadowlevel, (color/pen sin usar)}
                                : {1'b0, 3'd0, color_r, pen}; // {!shadow, 0, color, pen}

    // ---- intersección sprite/línea (combinacional sobre w0_r en TEST) ----
    wire [7:0] sy_c   = 8'd240 - w0_r[7:0];
    wire [8:0] py_c   = (line_r - {1'b0, sy_c}) & 9'h1ff;
    wire       on_line= (py_c < 9'd16);

    // ---- EARLY-OUT: test de línea sobre spr_q (=w0 recién leído) YA en RDW0, para saltar las
    //      lecturas w2/w3 de los sprites fuera de línea (la mayoría) y caber en el presupuesto
    //      de scanline a clk48 (~2.8K < 3072 ciclos). w0[7:0]=Y -> sy=240-Y, py=line-sy. ----
    wire [7:0] sy0    = 8'd240 - spr_q[7:0];
    wire [8:0] py0    = (line_r - {1'b0, sy0}) & 9'h1ff;
    wire       online0= (py0 < 9'd16);

    // ---- line buffer: escritura síncrona al banco wbank_r ----
    always @(posedge clk) if (ce) begin
        if (state==CLR) begin
            if (wbank_r) begin lb1[clr_i[8:0]] <= 12'd0; lb1h[clr_i[8:0]] <= 1'b0; end
            else         begin lb0[clr_i[8:0]] <= 12'd0; lb0h[clr_i[8:0]] <= 1'b0; end
        end else if (state==PWR && spr_on && xin) begin
            if (wbank_r) begin lb1[xpos - 10'd8] <= lb_wd; lb1h[xpos - 10'd8] <= high_r; end
            else         begin lb0[xpos - 10'd8] <= lb_wd; lb0h[xpos - 10'd8] <= high_r; end
        end
    end

    // ---- FSM ----
    // start SIEMPRE (re)arranca el render de la linea actual, incluso si el motor sigue
    // `busy` por un OVERRUN de presupuesto (escena densa: letras del titulo, arco
    // start/finish). Antes el start se perdia si state!=IDLE -> esa linea NO se
    // re-renderizaba y mostraba el buffer de la MISMA paridad de 2 lineas atras (stale)
    // = aspecto de "desentrelazado" en movimiento vertical. Abortando el render en curso,
    // bajo sobrecarga se truncan los sprites de mayor indice (comportamiento arcade), pero
    // NUNCA se cae una linea entera. Sin overrun, start llega en IDLE -> identico al diseno
    // original (tb_sprite_layer 0-diff preservado).
    always @(posedge clk) if (ce) begin
        done <= 1'b0;
        if (start) begin
            line_r <= line; clr_i <= 10'd0; busy <= 1'b1; wbank_r <= wbank; state <= CLR;
        end else case (state)
            IDLE: ;   // espera start (gestionado arriba)
            CLR:  begin clr_i <= clr_i + 1'b1; if (clr_i == 10'd367) begin spr_idx <= 11'd3; state <= RDW0; end end
            // sprite RAM registrada (+1 ciclo): la direccion ya se presento 1 ciclo antes
            // (ver spr_a), asi que aqui se captura en el mismo estado -> 3 ciclos, sin shift.
            // EARLY-OUT: si el sprite NO está en esta línea, saltar w2/w3 (ahorra 2 ciclos/sprite).
            // En NEXT se vuelve a presentar la dirección del próximo w0, así que el salto es seguro.
            RDW0: begin w0_r <= spr_q; state <= online0 ? RDW2 : NEXT; end // sprRAM[spr_idx] (addr0 de CLR/NEXT)
            RDW2: begin w2_r <= spr_q; state <= RDW3; end // sprRAM[spr_idx+2] (addr1 de RDW0)
            RDW3: begin w3_r <= spr_q; state <= TEST; end // sprRAM[spr_idx+3] (addr2 de RDW2)
            TEST: begin
                flipx_r <= w0_r[14]; flipy_r <= w0_r[15];
                sx_r    <= w2_r[9:0]; color_r <= w2_r[13:10]; code_r <= w3_r[13:0];
                high_r  <= (w3_r[13:0] >= 14'h3700);                   // high_priority (MAME: number>=0x3700)
                shad_r  <= w2_r[14];                                   // color_effect/sombra (MAME: BIT(color,4)=bit14 de w2)
                if (on_line) begin
                    gpy_r <= w0_r[15] ? (4'd15 - py_c[3:0]) : py_c[3:0];   // flipY sobre la fila
                    px    <= 4'd0;
                    state <= PADDR;
                end else state <= NEXT;
            end
            // rom_a SOLO cambia con gpx[3] (cada 8 px); el byte gfx (d_iXX) cubre 8 pixeles.
            // Fetch 1 vez por grupo de 8 (PADDR) y escribe los 8 pixeles en PWR consecutivos
            // SIN re-esperar gfx_ok (rom_a estable -> dato estable). Reduce 16 PADDR -> 2 PADDR
            // por sprite (clave con stalls de SDRAM). Salida identica (mismo pen/pos) -> 0-diff.
            PADDR: if (gfx_ok) state <= PWR;           // espera el dato de gfx del grupo (rom_a estable)
            PWR:   begin
                if (px == 4'd15)            state <= NEXT;          // ultimo pixel del sprite
                else if (px[2:0] == 3'd7) begin px <= px + 1'b1; state <= PADDR; end // fin de grupo -> re-fetch
                else                       begin px <= px + 1'b1; state <= PWR;   end // mismo grupo -> sigue escribiendo
            end
            NEXT:  if (spr_idx < 11'd2041) begin spr_idx <= spr_idx + 11'd4; state <= RDW0; end
                   else state <= DON;
            DON:   begin done <= 1'b1; busy <= 1'b0; state <= IDLE; end
            default: state <= IDLE;
        endcase
    end

    // init solo-sim
    // synthesis translate_off
    integer k;
    initial begin state=IDLE; busy=0; done=0; spr_idx=3; px=0; clr_i=0; wbank_r=0; high_r=0; shad_r=0;
        for (k=0;k<368;k=k+1) begin lb0[k]=0; lb1[k]=0; lb0h[k]=0; lb1h[k]=0; end end
    // synthesis translate_on
endmodule

`default_nettype wire
