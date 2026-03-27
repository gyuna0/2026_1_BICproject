`timescale 1ns / 1ps

module TOP_PathA(
    input wire       SYSCLK,    // 12MHz (Cmod A7)
    input wire       BTN,       // Reset Button (Active High, btn[0])
    input wire       BTN_ANC,   // [추가] ANC ON/OFF Toggle Button (btn[1])
    
    // Mic Interface
    input wire       MIC_DATA,
    output wire      MIC_BCLK,
    output wire      MIC_WS,
    
    // Speaker Interface (DAC)
    output wire      DAC_DIN,
    output wire      DAC_BCLK,
    output wire      DAC_LRCK,
    output wire      DAC_SCK,   
    
    output wire [1:0] LED       // 동작 확인용 (LED[0]: Lock, LED[1]: ANC State)
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

    // 리셋 신호 정의
    assign rstn = locked && !BTN;
    
    // DAC_SCK를 0으로 고정
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

    // ==========================================
    // [핵심 추가] ANC 버튼 디바운스 및 ON/OFF 토글
    // ==========================================
    reg [2:0] btn_sync;
    reg [15:0] db_cnt;
    reg btn_clean;
    reg btn_clean_d;
    reg anc_enable;

    always @(posedge clk_6m or negedge rstn) begin
        if (!rstn) begin
            btn_sync <= 0;
            db_cnt <= 0;
            btn_clean <= 0;
            btn_clean_d <= 0;
            anc_enable <= 0; // 초기 상태: ANC OFF (보강 간섭 상태)
        end else begin
            // 1) Synchronizer (메타스테빌리티 방지)
            btn_sync <= {btn_sync[1:0], BTN_ANC};

            // 2) Debounce Counter (버튼의 기계적 튐 현상 무시)
            if (btn_sync[2] == btn_clean) begin
                db_cnt <= 0;
            end else begin
                db_cnt <= db_cnt + 1;
                if (db_cnt == 16'hFFFF) begin // 약 10ms 동안 유지되면 상태 인정
                    btn_clean <= btn_sync[2];
                end
            end

            // 3) Edge Detection & Toggle (버튼을 '누르는 순간'마다 반전)
            btn_clean_d <= btn_clean;
            if (btn_clean && !btn_clean_d) begin
                anc_enable <= ~anc_enable;
            end
        end
    end

    // ==========================================
    // 4. Path A: 노이즈 캔슬링 신호 믹싱 (MUX)
    // ==========================================
    wire [23:0] w_inv_L = ~w_mic_L + 1'b1;   // 역위상 데이터 (-1)
    //wire [23:0] w_norm_L = w_mic_L;          // 정상 위상 데이터 (+1)
    wire [23:0] w_norm_L = 24'd0; 
    // anc_enable이 1이면 역위상(상쇄), 0이면 정상위상(보강) 출력
    wire [23:0] dac_data_L = anc_enable ? w_inv_L : w_norm_L;
    
    // Right 채널은 항상 기준이 되는 정상 위상 출력
    wire [23:0] dac_data_R = w_mic_L; 
    
    // 5. 스피커 출력 (Transmitter)
    I2S_DAC u_dac (
        .RSTN(rstn),
        .I2S_BCLK(clk_3m),
        .L_DATA_IN(dac_data_L),
        .R_DATA_IN(dac_data_R),
        .I2S_LRCK(DAC_LRCK),
        .I2S_DIN(DAC_DIN)
    );

    // ==========================================
    // 상태 표시 LED
    // ==========================================
    assign LED[0] = locked;       // Red LED: PLL 정상 작동 중
    assign LED[1] = anc_enable;   // Green LED: 불이 켜지면 노이즈 캔슬링 ON!

endmodule