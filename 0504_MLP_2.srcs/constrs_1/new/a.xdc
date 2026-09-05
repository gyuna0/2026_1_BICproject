## This file is a general .xdc for the CmodA7 rev. B
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Clock signal 12 MHz
set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} [get_ports SYSCLK]
create_clock -period 83.330 -name sys_clk_pin -waveform {0.000 41.660} -add [get_ports SYSCLK]


## LEDs
set_property -dict { PACKAGE_PIN A17   IOSTANDARD LVCMOS33 } [get_ports { LED[1] }]; #IO_L12N_T1_MRCC_16 Sch=led[1]
#set_property -dict { PACKAGE_PIN C16   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_L13P_T2_MRCC_16 Sch=led[2]

#set_property -dict { PACKAGE_PIN B17   IOSTANDARD LVCMOS33 } [get_ports { led_b}]; #IO_L14N_T2_SRCC_16 Sch=led0_b
#set_property -dict { PACKAGE_PIN B16   IOSTANDARD LVCMOS33 } [get_ports { led_g }]; #IO_L13N_T2_MRCC_16 Sch=led0_g
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 } [get_ports { LED[0] }]; #IO_L14P_T2_SRCC_16 Sch=led0_r


# Buttons (btn[0] = Reset / btn[1] = ANC Toggle)
set_property -dict {PACKAGE_PIN A18 IOSTANDARD LVCMOS33} [get_ports BTN]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports BTN_ANC]

# Microphone Interface (SPH0645) - PIO 26, 27, 28
set_property -dict {PACKAGE_PIN R3 IOSTANDARD LVCMOS33} [get_ports MIC_WS]
set_property -dict {PACKAGE_PIN T3 IOSTANDARD LVCMOS33} [get_ports MIC_DATA]
set_property -dict {PACKAGE_PIN R2 IOSTANDARD LVCMOS33} [get_ports MIC_BCLK]

# Speaker/DAC Interface (PCM5102A) - PIO 45, 46, 47, 48
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports DAC_LRCK]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports DAC_DIN]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33} [get_ports DAC_BCLK]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33} [get_ports DAC_SCK]



## UART
set_property -dict { PACKAGE_PIN J18   IOSTANDARD LVCMOS33 } [get_ports { UART_TX }]; #IO_L7N_T1_D10_14 Sch=uart_rxd_out
#set_property -dict { PACKAGE_PIN J17   IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in  }]; #IO_L7P_T1_D09_14 Sch=uart_txd_in


