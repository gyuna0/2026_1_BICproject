`timescale 1ns/1ns

module TOP_PathB(
    input wire       SYSCLK,  
    input wire       BTN,       
    input wire       BTN_ANC,  
    
    input wire       MIC_DATA,
    output wire      MIC_BCLK,
    output wire      MIC_WS,
    
    output wire      DAC_DIN,
    output wire      DAC_BCLK,
    output wire      DAC_LRCK,
    output wire      DAC_SCK,   
    
    output wire [1:0] LED,
    output wire UART_TX
);

    wire clk_6m;
    wire locked;
    reg  clk_3m = 1'b0;
    wire rstn;
    
    // =========================================================
    // Clock & Reset
    // =========================================================
    clk_wiz_0 u_clk_gen (
        .clk_in1  (SYSCLK),
        .reset    (BTN),       
        .clk_out1 (clk_6m), 
        .locked   (locked)
    );
    
    always @(posedge clk_6m or posedge BTN) begin
        if (BTN) clk_3m <= 1'b0;
        else     clk_3m <= ~clk_3m;
    end

    assign rstn     = locked && !BTN;
    assign DAC_SCK  = 1'b0; 
    assign DAC_BCLK = clk_3m;

    // =========================================================
    // I2S MIC Input
    // =========================================================
    wire [23:0] w_mic_L;
    wire [23:0] w_mic_R;
    wire        w_data_done;
    
    I2S_MIC u_mic (
        .RSTN         (rstn),
        .I2S_BCLK_IN  (clk_3m),
        .I2S_DATA     (MIC_DATA),
        .I2S_BCLK_OUT (MIC_BCLK),
        .I2S_WS       (MIC_WS),
        .L_DATA       (w_mic_L),
        .R_DATA       (w_mic_R),
        .DATA_DONE    (w_data_done)
    );

    // =========================================================
    // Synchronize MIC sample valid from clk_3m domain to clk_6m
    // =========================================================
    reg        done_s0;
    reg        done_s1;
    reg        done_s2;
    reg        sample_valid_6m;
    reg [23:0] mic_l_6m;

    always @(posedge clk_6m or negedge rstn) begin
        if (!rstn) begin
            done_s0         <= 1'b0;
            done_s1         <= 1'b0;
            done_s2         <= 1'b0;
            sample_valid_6m <= 1'b0;
            mic_l_6m        <= 24'd0;
        end else begin
            done_s0 <= w_data_done;
            done_s1 <= done_s0;
            done_s2 <= done_s1;

            sample_valid_6m <= done_s1 & ~done_s2;

            if (done_s1 & ~done_s2) begin
                mic_l_6m <= w_mic_L;
            end
        end
    end

    // =========================================================
    // Button Debounce & ANC Toggle
    // =========================================================
    reg [2:0]  btn_sync;
    reg [15:0] db_cnt;
    reg        btn_clean;
    reg        btn_clean_d;
    reg        anc_enable;

    always @(posedge clk_6m or negedge rstn) begin
        if (!rstn) begin
            btn_sync    <= 3'd0;
            db_cnt      <= 16'd0;
            btn_clean   <= 1'b0;
            btn_clean_d <= 1'b0;
            anc_enable  <= 1'b0; 
        end else begin
            btn_sync <= {btn_sync[1:0], BTN_ANC};

            if (btn_sync[2] == btn_clean) begin
                db_cnt <= 16'd0;
            end else begin
                db_cnt <= db_cnt + 1'b1;
                if (db_cnt == 16'hFFFF) begin 
                    btn_clean <= btn_sync[2];
                end
            end

            btn_clean_d <= btn_clean;

            if (btn_clean && !btn_clean_d) begin
                anc_enable <= ~anc_enable;
            end
        end
    end

    // =========================================================
    // Feature Extractor wires
    // FFT IP�� Feature ���ο� ����
    // =========================================================
    wire              feat_we;
    wire [6:0]        feat_addr;
    wire signed [7:0] feat_wdata;

    wire              feature_mlp_start;
    wire              feature_busy;
    wire              feature_frame_done;
    wire              feature_fft_done;
    wire              feature_sample_drop;

    // =========================================================
    // AI wires
    // =========================================================
    wire              ai_busy;
    wire              ai_done;
    wire              siren_detected;
    wire [15:0]       siren_score;
    wire [7:0]        ai_confidence;
    wire signed [31:0] final_logit;
    wire [31:0]       ai_output_rdata;

    Feature u_feature (
        .CLK                (clk_6m),
        .RSTN               (rstn),

        .MIC_L_DATA         (mic_l_6m),
        .SAMPLE_VALID       (sample_valid_6m),

        .MLP_BUSY           (ai_busy),

        .FEATURE_WE         (feat_we),
        .FEATURE_ADDR       (feat_addr),
        .FEATURE_WDATA      (feat_wdata),
        .MLP_START          (feature_mlp_start),

        .BUSY               (feature_busy),
        .FRAME_FEATURE_DONE (feature_frame_done),
        .FFT_FRAME_DONE     (feature_fft_done),
        .SAMPLE_DROP        (feature_sample_drop)
    );

    AI_Calculte u_ai (
        .CLK             (clk_6m),
        .RSTN            (rstn),

        .input_we        (feat_we),
        .input_waddr     (feat_addr),
        .input_wdata     (feat_wdata),

        .ai_start        (feature_mlp_start),

        .ai_done         (ai_done),
        .ai_busy         (ai_busy),
        .siren_detected  (siren_detected),
        .siren_score     (siren_score),
        .confidence      (ai_confidence),
        .final_logit     (final_logit),

        .output_re       (1'b0),
        .output_raddr    (4'd0),
        .output_rdata    (ai_output_rdata)
    );

    // =========================================================
    // Audio Output & ANC Logic
    // =========================================================
    wire [23:0] w_inv_L;
    wire [23:0] w_norm_L;
    wire [23:0] dac_data_L; 
    wire [23:0] dac_data_R;

    assign w_inv_L  = ~w_mic_L + 1'b1; 
    assign w_norm_L = w_mic_L; 

    assign dac_data_L = (anc_enable) ? 
                        (siren_detected ? w_norm_L : w_inv_L) : 
                        w_norm_L;

    assign dac_data_R = w_mic_L; 
    
    I2S_DAC u_dac (
        .RSTN       (rstn),
        .I2S_BCLK   (clk_3m),
        .L_DATA_IN  (dac_data_L),
        .R_DATA_IN  (dac_data_R),
        .I2S_LRCK   (DAC_LRCK),
        .I2S_DIN    (DAC_DIN)
    );

    reg [22:0] siren_led_hold;

    always @(posedge clk_6m or negedge rstn) begin
        if (!rstn) begin
            siren_led_hold <= 23'd0;
        end else begin
            if (siren_detected) begin
                siren_led_hold <= 23'd6_000_000;
            end else if (siren_led_hold != 23'd0) begin
                siren_led_hold <= siren_led_hold - 1'b1;
            end
        end
    end

    assign LED[1] = (siren_led_hold != 23'd0);
    assign LED[0] = anc_enable;

    UART_Logit_TX #(
        .CLK_HZ(6000000),
        .BAUD  (115200)
    ) u_uart_logit (
        .CLK    (clk_6m),
        .RSTN   (rstn),
        .START  (ai_done),
        .LOGIT  (final_logit),
        .DETECT (siren_detected),
        .TX     (UART_TX)
    );

endmodule
module UART_Logit_TX #(
    parameter CLK_HZ = 6000000,
    parameter BAUD   = 115200
)(
    input  wire              CLK,
    input  wire              RSTN,
    input  wire              START,
    input  wire signed [31:0] LOGIT,
    input  wire              DETECT,
    output wire              TX
);

    localparam integer BAUD_DIV = CLK_HZ / BAUD;

    reg signed [31:0] logit_latched;
    reg               detect_latched;
    reg               active;
    reg [4:0]         char_idx;
    reg [7:0]         tx_data;
    reg               tx_start;

    reg               tx_reg;
    reg               tx_busy;
    reg [15:0]        baud_cnt;
    reg [3:0]         bit_idx;
    reg [9:0]         tx_shift;

    reg [7:0]         next_char;

    assign TX = tx_reg;

    function [7:0] hex_char;
        input [3:0] nibble;
        begin
            if (nibble < 4'd10)
                hex_char = 8'h30 + nibble;
            else
                hex_char = 8'h41 + (nibble - 4'd10);
        end
    endfunction

    always @(*) begin
        case (char_idx)
            5'd0:  next_char = "L";
            5'd1:  next_char = "=";
            5'd2:  next_char = "0";
            5'd3:  next_char = "x";
            5'd4:  next_char = hex_char(logit_latched[31:28]);
            5'd5:  next_char = hex_char(logit_latched[27:24]);
            5'd6:  next_char = hex_char(logit_latched[23:20]);
            5'd7:  next_char = hex_char(logit_latched[19:16]);
            5'd8:  next_char = hex_char(logit_latched[15:12]);
            5'd9:  next_char = hex_char(logit_latched[11:8]);
            5'd10: next_char = hex_char(logit_latched[7:4]);
            5'd11: next_char = hex_char(logit_latched[3:0]);
            5'd12: next_char = " ";
            5'd13: next_char = "D";
            5'd14: next_char = "=";
            5'd15: next_char = detect_latched ? "1" : "0";
            5'd16: next_char = 8'h0D;
            5'd17: next_char = 8'h0A;
            default: next_char = 8'h20;
        endcase
    end

    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
            logit_latched  <= 32'sd0;
            detect_latched <= 1'b0;
            active         <= 1'b0;
            char_idx       <= 5'd0;
            tx_data        <= 8'd0;
            tx_start       <= 1'b0;
        end else begin
            tx_start <= 1'b0;

            if (!active) begin
                if (START && !tx_busy) begin
                    logit_latched  <= LOGIT;
                    detect_latched <= DETECT;
                    active         <= 1'b1;
                    char_idx       <= 5'd0;
                end
            end else if (!tx_busy && !tx_start) begin
                tx_data  <= next_char;
                tx_start <= 1'b1;

                if (char_idx == 5'd17) begin
                    active   <= 1'b0;
                    char_idx <= 5'd0;
                end else begin
                    char_idx <= char_idx + 1'b1;
                end
            end
        end
    end

    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
            tx_reg    <= 1'b1;
            tx_busy   <= 1'b0;
            baud_cnt  <= 16'd0;
            bit_idx   <= 4'd0;
            tx_shift  <= 10'b1111111111;
        end else begin
            if (tx_start && !tx_busy) begin
                tx_busy  <= 1'b1;
                baud_cnt <= 16'd0;
                bit_idx  <= 4'd0;
                tx_shift <= {1'b1, tx_data, 1'b0};
                tx_reg   <= 1'b0;
            end else if (tx_busy) begin
                if (baud_cnt == BAUD_DIV - 1) begin
                    baud_cnt <= 16'd0;
                    bit_idx  <= bit_idx + 1'b1;
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    tx_reg   <= tx_shift[1];

                    if (bit_idx == 4'd9) begin
                        tx_busy <= 1'b0;
                        tx_reg  <= 1'b1;
                    end
                end else begin
                    baud_cnt <= baud_cnt + 1'b1;
                end
            end
        end
    end

endmodule