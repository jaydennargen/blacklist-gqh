// Timing constraint for the Tang Nano 20K 27 MHz onboard oscillator (sys_clk, pin 4).
// The organizer ships only the .cst; without this Gowin assumes 100 MHz (TA1132).
// Syntax follows the Gowin V1.9.11.03 examples (IDE/data/examples/*/src/*.sdc).
create_clock -name sys_clk -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]
