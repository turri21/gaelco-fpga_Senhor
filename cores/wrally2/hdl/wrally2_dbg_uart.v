// ============================================================================
//  wrally_dbg_uart.v — transmisor UART de DEBUG. Envia repetidamente un paquete de
//  NB bytes (8N1, 9600 baud), por defecto @clk48 (DIV=5000). MiSTer enruta el UART del
//  core a /dev/ttyS1:  stty -F /dev/ttyS1 9600 raw; cat /dev/ttyS1 | xxd
//  Los 2 primeros bytes son sync (0x55 0xAA) para alinear el paquete; el ultimo 0x0A.
//  TELEMETRIA PAGINADA: `pkt_start` pulsa al iniciar cada paquete -> el game rota de
//  pagina y latchea en `data` el struct de esa pagina (estable toda la transmision).
//  Asi multiplexamos muchas mas señales (MCU/68k/RAM/Dallas...) de las que caben en NB.
// ============================================================================
`default_nettype none

module wrally2_dbg_uart #(
    parameter integer NB  = 20,        // numero de bytes del paquete
    parameter integer DIV = 10000      // clk / 9600 baud (clk48 -> 5000)
) (
    input  wire              clk,
    input  wire              rst,
    input  wire [8*NB-1:0]   data,      // data[8*i +: 8] = byte i (i=0,1 = sync 0x55,0xAA)
    output reg               pkt_start, // pulso de 1 clk al ARRANCAR un paquete (rotar pagina + latch)
    output reg               txd
);
    reg [13:0]      divcnt = 0;
    reg [3:0]       bitcnt = 0; // 0=start, 1..8=datos (LSB first), 9=stop
    reg [7:0]       shreg  = 8'hFF;
    reg [5:0]       bidx   = 0; // indice de byte 0..NB-1 (6 bits: soporta NB hasta ~63)
    reg [15:0]      gap    = 0; // espera entre paquetes (~1.4 ms @clk48): paquetes ~30/s -> con 5 paginas
                                // cada pagina ~6/s, asi una captura de 2 s ve TODAS las paginas de sobra.
    reg             busy   = 0;
    reg [8*NB-1:0]  buf_q  = 0; // paquete LATCHEADO al arrancar -> `data` solo importa en pkt_start
                                // (asi el game puede cambiar `data` -rotar pagina- sin corromper el envio)

    always @(posedge clk) begin
        pkt_start <= 1'b0;                     // pulso de 1 clk por defecto
        if (rst) begin
            txd<=1'b1; bitcnt<=0; bidx<=0; gap<=0; busy<=0; divcnt<=0; shreg<=8'hFF;
        end else if (!busy) begin
            txd <= 1'b1;                       // idle alto
            gap <= gap + 1'b1;
            if (&gap) begin                    // arranca un paquete nuevo
                busy<=1'b1; bidx<=0; bitcnt<=0; divcnt<=0;
                buf_q <= data; shreg <= data[7:0]; // LATCH del paquete entero (pagina actual)
                pkt_start <= 1'b1;             // -> el game rota a la pagina siguiente
            end
        end else begin
            if (divcnt < DIV-1) divcnt <= divcnt + 1'b1;
            else begin
                divcnt <= 0;
                // emitir el bit segun bitcnt
                if      (bitcnt==4'd0) txd <= 1'b0;          // start
                else if (bitcnt==4'd9) txd <= 1'b1;          // stop
                else begin txd <= shreg[0]; shreg <= {1'b0, shreg[7:1]}; end  // dato LSB first
                // avanzar
                if (bitcnt==4'd9) begin
                    if (bidx==NB-1) begin busy<=1'b0; gap<=0; end
                    else begin bidx<=bidx+1'b1; bitcnt<=4'd0; shreg<=buf_q[8*(bidx+1) +: 8]; end
                end else bitcnt <= bitcnt + 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
