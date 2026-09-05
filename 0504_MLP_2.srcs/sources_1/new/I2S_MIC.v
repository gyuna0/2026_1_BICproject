module I2S_MIC(
    input wire         RSTN,
    input wire         I2S_BCLK_IN, // 3.072MHz
    input wire         I2S_DATA,
    
    output wire        I2S_BCLK_OUT,
    output reg         I2S_WS,
    output reg [23:0]  L_DATA,
    output reg [23:0]  R_DATA,
    output reg         DATA_DONE
    );

    assign I2S_BCLK_OUT = I2S_BCLK_IN; // 마이크에 클락 공급

    reg [5:0]  bit_cnt; 
    reg [23:0] shift_reg;

    // 초기화
    initial begin
        bit_cnt = 0; I2S_WS = 0;
    end

    always @(negedge I2S_BCLK_IN or negedge RSTN) begin // Edge 주의 (Negedge 동작)
        if (!RSTN) begin
            bit_cnt   <= 0;
            I2S_WS    <= 0;
            shift_reg <= 0;
            DATA_DONE <= 0;
        end else begin
            // 1. Counter & WS
            if (bit_cnt == 63) bit_cnt <= 0;
            else               bit_cnt <= bit_cnt + 1;

            if (bit_cnt == 31)      I2S_WS <= 1; // Right Start
            else if (bit_cnt == 63) I2S_WS <= 0; // Left Start

            // 2. Data Shift (Standard I2S: 1-bit Delay 있음)
            // bit 1~24: 유효 데이터
            if ((bit_cnt >= 1 && bit_cnt <= 24) || (bit_cnt >= 33 && bit_cnt <= 56)) begin
                shift_reg <= {shift_reg[22:0], I2S_DATA};
            end

            // 3. Data Latch
            DATA_DONE <= 0;
            if (bit_cnt == 31) begin
                L_DATA <= shift_reg; // Left 데이터 완성
            end
            else if (bit_cnt == 63) begin
                R_DATA <= shift_reg; // Right 데이터 완성
                DATA_DONE <= 1;      // 한 프레임 끝
            end
        end
    end
endmodule