## This file is a general .xdc for the CmodA7 rev. B
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# Clock signal 12 MHz
set_property -dict { PACKAGE_PIN L17   IOSTANDARD LVCMOS33 } [get_ports { SYSCLK }]; #IO_L12P_T1_MRCC_14 Sch=gclk
create_clock -add -name sys_clk_pin -period 83.33 -waveform {0 41.66} [get_ports { SYSCLK }];

## RGB LED (프로젝트의 LED[0], LED[1]에 매핑)
set_property -dict { PACKAGE_PIN B16   IOSTANDARD LVCMOS33 } [get_ports { LED[1] }]; #IO_L13N_T2_MRCC_16 Sch=led0_g
set_property -dict { PACKAGE_PIN C17   IOSTANDARD LVCMOS33 } [get_ports { LED[0] }]; #IO_L14P_T2_SRCC_16 Sch=led0_r

# Buttons (btn[0] = Reset / btn[1] = ANC Toggle)
set_property -dict { PACKAGE_PIN A18   IOSTANDARD LVCMOS33 } [get_ports { BTN }];     #IO_L19N_T3_VREF_16 Sch=btn[0]
set_property -dict { PACKAGE_PIN B18   IOSTANDARD LVCMOS33 } [get_ports { BTN_ANC }]; #IO_L19P_T3_16 Sch=btn[1]

# Microphone Interface (SPH0645) - PIO 26, 27, 28
set_property -dict { PACKAGE_PIN R3    IOSTANDARD LVCMOS33 } [get_ports { MIC_WS    }]; #IO_L2P_T0_34 Sch=pio[26]
set_property -dict { PACKAGE_PIN T3    IOSTANDARD LVCMOS33 } [get_ports { MIC_DATA  }]; #IO_L2N_T0_34 Sch=pio[27]
set_property -dict { PACKAGE_PIN R2    IOSTANDARD LVCMOS33 } [get_ports { MIC_BCLK  }]; #IO_L1P_T0_34 Sch=pio[28]

# Speaker/DAC Interface (PCM5102A) - PIO 45, 46, 47, 48
set_property -dict { PACKAGE_PIN U7    IOSTANDARD LVCMOS33 } [get_ports { DAC_LRCK }]; #IO_L19P_T3_34 Sch=pio[45]
set_property -dict { PACKAGE_PIN W7    IOSTANDARD LVCMOS33 } [get_ports { DAC_DIN  }]; #IO_L13P_T2_MRCC_34 Sch=pio[46]
set_property -dict { PACKAGE_PIN U8    IOSTANDARD LVCMOS33 } [get_ports { DAC_BCLK }]; #IO_L14P_T2_SRCC_34 Sch=pio[47]
set_property -dict { PACKAGE_PIN V8    IOSTANDARD LVCMOS33 } [get_ports { DAC_SCK  }]; #IO_L14N_T2_SRCC_34 Sch=pio[48]

## Configuration options for Bitstream
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]