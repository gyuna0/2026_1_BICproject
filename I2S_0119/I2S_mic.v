module I2S_mic(
    input wire        RSTN,
    input wire        I2S_BCLK_IN,  // [변경] Top에서 들어오는 클럭
    input wire        I2S_DATA,
    
    output wire       I2S_BCLK_OUT, // [변경] 마이크로 바이패스
    output reg        I2S_WS,
    output reg [23:0] L_DATA,
    output reg [23:0] R_DATA,
    output reg        DATA_DONE
    );

    // 입력 클럭을 그대로 마이크에게 전달
    assign I2S_BCLK_OUT = I2S_BCLK_IN;

    reg [5:0] bit_cnt; 
    reg [23:0] shift_reg;

    // Next State Variables
    reg [5:0]  bit_cnt_next;
    reg        I2S_WS_next;
    reg [23:0] shift_reg_next;
    reg [23:0] L_DATA_next;
    reg [23:0] R_DATA_next;
    reg        DATA_DONE_next;

    // Sequential Logic (Clocked by I2S_BCLK_IN)
    always @(posedge I2S_BCLK_IN or negedge RSTN) begin
        if (!RSTN) begin
            bit_cnt    <= 0;
            I2S_WS     <= 0;
            shift_reg  <= 0;
            L_DATA     <= 0;
            R_DATA     <= 0;
            DATA_DONE  <= 0;
        end else begin
            bit_cnt    <= bit_cnt_next;
            I2S_WS     <= I2S_WS_next;
            shift_reg  <= shift_reg_next;
            L_DATA     <= L_DATA_next;
            R_DATA     <= R_DATA_next;
            DATA_DONE  <= DATA_DONE_next;
        end
    end

    // Combinational Logic
    always @(*) begin
        bit_cnt_next   = bit_cnt;
        I2S_WS_next    = I2S_WS;
        shift_reg_next = shift_reg;
        L_DATA_next    = L_DATA;
        R_DATA_next    = R_DATA;
        DATA_DONE_next = 0;
       
        // Counter
        if (bit_cnt == 63) 
            bit_cnt_next = 0;
        else 
            bit_cnt_next = bit_cnt + 1;
       
        // WS Generation
        if (bit_cnt == 31) 
            I2S_WS_next = 1; // WS high (Right)
        else if (bit_cnt == 63) 
            I2S_WS_next = 0; // WS low (Left)

      
        if (bit_cnt >= 1 && bit_cnt <= 24) begin
            shift_reg_next = {shift_reg[22:0], I2S_DATA};
        end
     
        else if (bit_cnt >= 33 && bit_cnt <= 56) begin
            shift_reg_next = {shift_reg[22:0], I2S_DATA};
        end

        // Data Latch
        if (bit_cnt == 31) begin
            L_DATA_next = shift_reg;
        end
        else if (bit_cnt == 63) begin
            R_DATA_next = shift_reg;
            DATA_DONE_next = 1;
        end
    end

endmodule