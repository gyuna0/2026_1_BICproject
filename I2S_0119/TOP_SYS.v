`timescale 1ns / 1ps

module TOP_SYS(
    input wire       SYSCLK,    // 12MHz
    input wire       RSTN,      // 리셋 버튼 (Active High 가정)
    input wire       MIC_DATA,  // 마이크 SD 핀
    
    output wire      MIC_BCLK,  // 마이크 SCK 핀
    output wire      MIC_WS,    // 마이크 WS 핀

    output wire      DAC_DIN,   // DAC DIN 핀
    output wire      DAC_BCLK,  // DAC BCK 핀
    output wire      DAC_LRCK,  // DAC LCK 핀 (오타 수정됨: LCRK -> LRCK)
    output wire [1:0] LED
    );

    wire clk_6m;
    wire locked;
    reg  clk_3m;
    wire rstn; // Active Low Reset (내부용)

    // 1. Clock Wizard (12MHz -> 6.144MHz)
    clk_wiz_0 u_clk_gen (
        .clk_in1(SYSCLK),
        .reset(RSTN),      // 버튼 누르면 리셋 (Active High)
        .clk_out1(clk_6m), 
        .locked(locked)
    );

    // 2. 3.072MHz 생성 (6.144MHz 분주)
    always @(posedge clk_6m or negedge locked) begin
        if (!locked) begin
            clk_3m <= 0;
        end else begin
            clk_3m <= ~clk_3m; 
        end
    end

    // [중요] 내부 리셋 신호 생성 (Locked가 1이면 리셋 풀림)
    assign rstn = locked; 

    wire [23:0] left_data;
    wire [23:0] right_data;
    wire        data_valid;

    I2S_mic u_mic_receiver (
        .RSTN(rstn),
        .I2S_BCLK_IN(clk_3m),   // Top에서 만든 3.072MHz 주입
        .I2S_DATA(MIC_DATA),    
        
        .I2S_BCLK_OUT(MIC_BCLK),// 마이크 핀으로 전달 (오타 수정: BCLk -> BCLK)
        .I2S_WS(MIC_WS),        
        
        .L_DATA(left_data),     
        .R_DATA(right_data),    
        .DATA_DONE(data_valid)
    );

    I2S_DAC u_dac_transmitter (
        .RSTN(rstn),
        .I2S_BCLK(clk_3m),      // 같은 클럭 사용
        
        .L_DATA_IN(left_data),  // Loopback 연결
        .R_DATA_IN(right_data), 
       
        .I2S_LRCK(DAC_LRCK),    // DAC 핀으로 연결
        .I2S_DIN(DAC_DIN)       
    );
    
    // DAC BCLK 연결 (Top에서 바로 연결)
    assign DAC_BCLK = clk_3m;

    // LED 디버깅
    assign LED[0] = locked;
    assign LED[1] = data_valid; // 데이터 들어오면 깜빡임

endmodule