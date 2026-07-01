// ============================================================================
//  wrally2_adc.v — LS259 (IC6) + 2 ADC serie de los VOLANTES (gaelco2.cpp:2750-2776).
//
//  El 68k controla 2 ADC serie (uno por cabina) vía 2 líneas del LS259 en 0x400000:
//    q5 = ADC clock-in, q6 = ADC chip-select.   (q0/q1 = coin counters, ignorados.)
//  Protocolo (MAME):
//    - wrally2_adc_cs(state):  en state=0 (cs↓) -> latchea el valor analógico: ports[0/1]=wheel.
//    - wrally2_adc_clk(state): en state=0 (clk↓) -> shift-left de ambos ports (<<=1).
//    - wrally2_analog_bit_r<N>: devuelve el bit7 (MSB) -> IN0 b6 (ADC_1) / IN2 b6 (ADC_2).
//  Lectura MSB-first: tras el load se lee b7; cada clk↓ avanza al siguiente bit.
//
//  analog0/1 = volante (8b absoluto, centro ~0x80). En HW = eje X del stick analógico (joyana_l1/l2
//  de jtframe, signed->offset-binary en el game; paddle_* NO sirve: el wrapper memgen no lo conecta).
//  MAME: PADDLE default 0x8A, REVERSE. El ADC sólo se usa con DSW "Pot Wheel"; en "Joystick" (default)
//  el juego ignora estas líneas.
// ============================================================================
`default_nettype none

module wrally2_adc (
    input  wire        clk,
    input  wire        rst,
    input  wire        latch_we,    // nivel: el 68k escribe el LS259 (cs_latch & write & wr_ack)
    input  wire [2:0]  latch_sel,   // addr[5:3] = índice del bit del LS259 (write_bit(offset>>2) de MAME)
    input  wire        latch_dat,   // oEdb[0]
    input  wire [7:0]  analog0,     // volante cabina 1 (paddle_0)
    input  wire [7:0]  analog1,     // volante cabina 2 (paddle_1)
    output wire        adc1_bit,    // MSB serie -> IN0 b6
    output wire        adc2_bit     // MSB serie -> IN2 b6
);
    reg [7:0] ls259 = 8'd0;
    reg [7:0] sh0 = 8'd0, sh1 = 8'd0;
    reg       q5p = 1'b0, q6p = 1'b0;   // q5/q6 del clk anterior (detección de flanco)

    always @(posedge clk) begin
        if (rst) begin
            ls259 <= 8'd0; sh0 <= 8'd0; sh1 <= 8'd0; q5p <= 1'b0; q6p <= 1'b0;
        end else begin
            if (latch_we) ls259[latch_sel] <= latch_dat;
            q5p <= ls259[5];
            q6p <= ls259[6];
            // (q*p = clk anterior; ls259[*] = actual -> detección 1 ciclo retrasada, irrelevante)
            if      (q6p & ~ls259[6]) begin sh0 <= analog0;           sh1 <= analog1;           end // cs↓ = load
            else if (q5p & ~ls259[5]) begin sh0 <= {sh0[6:0],1'b0};   sh1 <= {sh1[6:0],1'b0};   end // clk↓ = shift
        end
    end

    assign adc1_bit = sh0[7];
    assign adc2_bit = sh1[7];
endmodule

`default_nettype wire
