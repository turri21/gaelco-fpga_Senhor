// ============================================================================
//  World Rally (Gaelco) — generador de clock-enables (BLOQUE 5).
//
//  De un reloj maestro saca los enables que pide `wrally_main`:
//    - 68000: dos fases NO solapadas a 12 MHz (XTAL 24/2). phi1 y phi2.
//    - DS5002 (R8051): enable a 12 MHz (mismo reloj que el 68000 en la placa real).
//    - OKI MSM6295: enable a 1 MHz.
//
//  Los DEFAULTS (CPUDIV=4/OKIDIV=48) son para MASTER=48 MHz, PERO en este proyecto wrally_fpga
//  lo instancia con CPUDIV=8/OKIDIV=96 sobre un MASTER de 96 MHz -> 12 MHz CPU/MCU, 1 MHz OKI.
//  Ajustar los parámetros segun la frecuencia real del PLL del wrapper.
// ============================================================================
`default_nettype none

module wrally_clocks #(
    parameter CPUDIV = 4,    // master/CPUDIV = 12 MHz (48/4)
    parameter OKIDIV = 48    // master/OKIDIV = 1 MHz  (48/48)
)(
    input  wire clk,
    input  wire rst,
    output reg  cpu_cen_phi1 = 1'b0,
    output reg  cpu_cen_phi2 = 1'b0,
    output reg  mcu_cen = 1'b0,
    output reg  oki_cen = 1'b0
);
    // divisor del 68000/MCU (12 MHz): fases en mitades opuestas del periodo
    // (valor inicial 0: en sim el reset async puede no tener flanco 0->1 -> sin init
    //  cdiv quedaria en X y los cen nunca pulsarian; en HW = estado de power-on)
    reg [$clog2(CPUDIV)-1:0] cdiv = 0;
    // divisor del OKI (1 MHz)
    reg [$clog2(OKIDIV)-1:0] odiv = 0;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cdiv <= 0; odiv <= 0;
            cpu_cen_phi1 <= 1'b0; cpu_cen_phi2 <= 1'b0;
            mcu_cen <= 1'b0; oki_cen <= 1'b0;
        end else begin
            cdiv <= (cdiv == CPUDIV-1) ? 0 : cdiv + 1'b1;
            // phi1 al inicio del periodo, phi2 a mitad (no solapadas)
            cpu_cen_phi1 <= (cdiv == 0);
            cpu_cen_phi2 <= (cdiv == (CPUDIV/2));
            mcu_cen      <= (cdiv == 0);              // DS5002 a 12 MHz (= phi1)
            odiv <= (odiv == OKIDIV-1) ? 0 : odiv + 1'b1;
            oki_cen <= (odiv == 0);
        end
    end
endmodule

`default_nettype wire
