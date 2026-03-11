`timescale 1ns / 1ps

module TOP_PathA(
    input wire       SYSCLK,    // 12MHz (Cmod A7)
    input wire       BTN,       // Reset Button (Active High)
    
    // Mic Interface
    input wire       MIC_DATA,
    output wire      MIC_BCLK,
    output wire      MIC_WS,
    
    // Speaker Interface (DAC)
    output wire      DAC_DIN,
    output wire      DAC_BCLK,
    output wire      DAC_LRCK,
    output wire      DAC_SCK,   // [추가] 친구 코드처럼 SCK 포트 추가
    
    output wire [1:0] LED       // 동작 확인용
    );

    wire clk_6m;
    wire locked;
    reg  clk_3m = 0;
    wire rstn;

    // 1. Clock Wizard (12MHz -> 6.144MHz)
    clk_wiz_0 u_clk_gen (
        .clk_in1(SYSCLK),
        .reset(BTN),       
        .clk_out1(clk_6m), 
        .locked(locked)
    );

    // 2. BCLK 생성 (6.144MHz -> 3.072MHz)
    always @(posedge clk_6m or posedge BTN) begin
        if (BTN) clk_3m <= 0;
        else     clk_3m <= ~clk_3m;
    end

    // 리셋 신호 정의 (PLL이 Lock되고 버튼을 떼었을 때 Active Low 리셋 해제)
    assign rstn = locked && !BTN;
    
    // [핵심] DAC_SCK를 0으로 고정하여 DAC 내부 PLL 활성화
    assign DAC_SCK = 1'b0; 
    assign DAC_BCLK = clk_3m;

    // --- 데이터 신호 ---
    wire [23:0] w_mic_L, w_mic_R;
    wire        w_data_done;
    
    // 3. 마이크 입력 (Receiver)
    I2S_mic u_mic (
        .RSTN(rstn),
        .I2S_BCLK_IN(clk_3m),
        .I2S_DATA(MIC_DATA),
        .I2S_BCLK_OUT(MIC_BCLK),
        .I2S_WS(MIC_WS),
        .L_DATA(w_mic_L),
        .R_DATA(w_mic_R),
        .DATA_DONE(w_data_done)
    );

    // 4. Path A: Signal Bypass (테스트용 그대로 출력)
    wire [23:0] w_mic_L_amp = w_mic_L << 1; // 1비트 시프트로 2배 증폭
    wire [23:0] w_inv_L = ~w_mic_L_amp + 1'b1;
    wire [23:0] w_inv_R = w_mic_L_amp;
    //wire [23:0] w_inv_L = ~w_mic_L +1'b1;
    //wire [23:0] w_inv_R = w_mic_L;
    
    // 5. 스피커 출력 (Transmitter)
    I2S_DAC u_dac (
        .RSTN(rstn),
        .I2S_BCLK(clk_3m),
        .L_DATA_IN(w_inv_L),
        .R_DATA_IN(w_inv_R),
        .I2S_LRCK(DAC_LRCK),
        .I2S_DIN(DAC_DIN)
    );

    // LED Status
    assign LED[0] = locked;       
    assign LED[1] = w_data_done;  

endmodule