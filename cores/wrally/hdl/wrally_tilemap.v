// ============================================================================
//  World Rally (Gaelco) — Motor de TILEMAP de una capa (16x16, 4bpp, 64x32)
//
//  Genera el pixel de UNA capa para una coordenada del espacio del tilemap
//  (1024x512). El SCROLL es solo un offset de direccion: lo aplica el llamante
//  antes de pasar (tmx,tmy) — igual que en el HW real y en el spike verificado
//  render_visible.cpp. Asi el motor es agnostico al scroll y reutilizable.
//
//  Reune los bloques YA VERIFICADOS:
//    - wrally_tile_attr  : VRAM word-par/impar -> code/color/prio/flip
//    - formato de gfx de wrally_gfx_decode    : romaddr = code*32 + (col>=8?16:0)+row
//                                               pen = {i07,i09,i11,i13}[7-col[2:0]]
//
//  Memorias SINCRONAS (block-RAM, latencia 1 ciclo), pipeline de 3 etapas:
//    N    : request (tmx,tmy) -> vram_a   (combinacional desde la entrada)
//    N+1  : llega vram_q={data,data2} -> decodifica attr -> rom_a
//    N+2  : llegan los 4 bytes de gfx -> pen
//    N+3  : salida registrada (pen,color,prio) valida
//  El llamante alinea la salida con la coordenada usando este retardo fijo.
//
//  VRAM (16 KB): byte addr = layer*0x2000 + T*4, con T = ty*64 + tx (scan por
//  filas, 64 de ancho). Puerto de 32 bits: vram_q = {data(par), data2(impar)}.
// ============================================================================
`default_nettype none

module wrally_tilemap (
    input  wire        clk,
    input  wire        ce,         // pixel clock enable

    // peticion de pixel (coordenadas en espacio del tilemap, scroll ya aplicado)
    input  wire [9:0]  tmx,        // 0..1023
    input  wire [8:0]  tmy,        // 0..511
    input  wire        layer,      // 0 = L0, 1 = L1

    // puerto de lectura VRAM (32 bits = {data, data2}), latencia registrada de 1
    output wire [13:0] vram_a,     // direccion de BYTE dentro de los 16 KB de VRAM
    input  wire [31:0] vram_q,     // {data[31:16], data2[15:0]}  (1 ciclo despues)

    // puerto de lectura ROM gfx (4 planos), latencia registrada de 1
    output wire [18:0] rom_a,      // misma direccion para i07/i09/i11/i13
    input  wire [7:0]  d_i07,
    input  wire [7:0]  d_i09,
    input  wire [7:0]  d_i11,
    input  wire [7:0]  d_i13,
    input  wire        gfx_ok,     // 1 = d_iXX valido para rom_a (slot SDRAM). Sin esto se latchea
                                   // dato RANCIO en los limites de tile -> lineas verticales.

    // salida del pixel (latencia de 3 ciclos respecto a la peticion)
    output reg  [3:0]  pen,        // 0..15 (pen 0 = transparente fuera del modulo)
    output reg  [4:0]  color,      // bloque de paleta
    output reg         prio        // categoria/prioridad de la capa
);
    // ---- Etapa -1 : REGISTRAR la coordenada de entrada en `ce` -----------------
    // Imprescindible para que `vram_a` (combinacional) y `col0_d` (registrado) deriven
    // del MISMO valor: si se usara `tmx` directo, con una fuente de hpos REGISTRADA
    // (p.ej. el generador de timing, que cambia EN el flanco de ce) `vram_a` usaria el
    // tmx nuevo y `col0_d` el viejo -> desfase de 1 px en cada tile. Registrando la
    // entrada, el modulo es robusto a cualquier fuente sincrona. (+1 ce de latencia.)
    reg [9:0] tmx_r; reg [8:0] tmy_r;
    always @(posedge clk) if (ce) begin tmx_r <= tmx; tmy_r <= tmy; end

    // ---- Etapa 0 : pedir el word de VRAM del tile que contiene (tmx_r,tmy_r) ----
    wire [5:0]  tx = tmx_r[9:4];
    wire [4:0]  ty = tmy_r[8:4];
    wire [10:0] T  = {ty, tx};            // indice de tile 0..2047 (fila*64+col)
    assign vram_a  = {layer, T, 2'b00};   // layer*0x2000 + T*4

    // alinear col/row del pixel con vram_q (que llega 1 ciclo despues)
    reg [3:0] col0_d, row0_d;
    always @(posedge clk) if (ce) begin
        col0_d <= tmx_r[3:0];
        row0_d <= tmy_r[3:0];
    end

    // ---- Etapa 1 : VRAM disponible -> attrs -> direccion de gfx --------------
    wire [15:0] data  = vram_q[31:16];
    wire [15:0] data2 = vram_q[15:0];
    wire [13:0] code;
    wire [4:0]  color1;
    wire        prio1, flipx, flipy;
    wrally_tile_attr u_attr (
        .data (data), .data2(data2),
        .code (code), .color(color1), .prio(prio1),
        .flipx(flipx), .flipy(flipy)
    );

    wire [3:0] row1 = flipy ? ~row0_d : row0_d;   // flipY sobre la fila
    wire [3:0] col1 = flipx ? ~col0_d : col0_d;   // flipX sobre la columna

    // direccion de gfx (formato verificado en wrally_gfx_decode)
    assign rom_a = {code, 5'b00000} + {14'b0, col1[3], row1};

    // ---- Etapa 1.5 : PREFETCH de gfx con handshake gfx_ok (doble buffer lo/hi) ----------
    // El gfx viene de SDRAM (latencia VARIABLE). El motor original asumia latencia fija de 1
    // ciclo y latcheaba dato RANCIO cuando el slot no llegaba a tiempo -> LINEAS VERTICALES
    // (gfx0/1_ok=0 en ~0.8% de los ce_pix). FIX: latchear cada MITAD del tile-row (lo=col[3]=0,
    // hi=col[3]=1) en un registro SOLO cuando gfx_ok, y CONSUMIR la decodificacion LEAD ce_pix
    // despues. rom_a es estable 8 ce_pix por mitad -> con doble buffer y LEAD=7 el dato SIEMPRE
    // esta listo antes de consumirse (margen ~7 ce_pix = ~84 ciclos a 96MHz >> latencia SDRAM +
    // refresco). NO toca la logica de direccion/atributos (verificada). Anade LEAD de latencia
    // (la compensan LATV/cadena-sprite en wrally_video_top con shift UNIFORME -> skew intacto).
    localparam integer LEAD = 7;
    reg [7:0] gl07, gl09, gl11, gl13;     // buffer mitad LO (col[3]=0)
    reg [7:0] gh07, gh09, gh11, gh13;     // buffer mitad HI (col[3]=1)
    always @(posedge clk) if (ce && gfx_ok) begin
        if (col1[3]) begin gh07<=d_i07; gh09<=d_i09; gh11<=d_i11; gh13<=d_i13; end
        else         begin gl07<=d_i07; gl09<=d_i09; gl11<=d_i11; gl13<=d_i13; end
    end

    // registrar attr + columna (col1[3:0] = mitad + bit) y RETRASAR LEAD ce_pix para alinear
    // con el buffer ya cargado.
    reg [4:0] color_d; reg prio_d; reg [3:0] col_d;
    always @(posedge clk) if (ce) begin
        color_d <= color1; prio_d <= prio1; col_d <= col1;
    end
    reg [4:0] color_sr [0:LEAD-1];
    reg       prio_sr  [0:LEAD-1];
    reg [3:0] col_sr   [0:LEAD-1];
    integer si;
    always @(posedge clk) if (ce) begin
        color_sr[0] <= color_d; prio_sr[0] <= prio_d; col_sr[0] <= col_d;
        for (si = 1; si < LEAD; si = si + 1) begin
            color_sr[si] <= color_sr[si-1];
            prio_sr [si] <= prio_sr [si-1];
            col_sr  [si] <= col_sr  [si-1];
        end
    end
    wire [4:0] color_c = color_sr[LEAD-1];
    wire       prio_c  = prio_sr [LEAD-1];
    wire [3:0] col_c   = col_sr  [LEAD-1];

    // ---- Etapa 2 : decodificar pen del BUFFER (mitad por col_c[3], bit por col_c[2:0]) ----
    wire [7:0] db07 = col_c[3] ? gh07 : gl07;
    wire [7:0] db09 = col_c[3] ? gh09 : gl09;
    wire [7:0] db11 = col_c[3] ? gh11 : gl11;
    wire [7:0] db13 = col_c[3] ? gh13 : gl13;
    wire [2:0] bbit = 3'd7 - col_c[2:0];  // bit dentro del byte (MSB-first)
    wire [3:0] pen2 = { db07[bbit], db09[bbit], db11[bbit], db13[bbit] };  // i07=MSB..i13=LSB
    always @(posedge clk) if (ce) begin
        pen   <= pen2;
        color <= color_c;
        prio  <= prio_c;
    end

endmodule

`default_nettype wire
