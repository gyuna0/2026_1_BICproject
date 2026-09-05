module I2S_DAC(
    input wire         RSTN,
    input wire         I2S_BCLK,    // 3.072MHz
    input wire [23:0]  L_DATA_IN,
    input wire [23:0]  R_DATA_IN,
    
    output reg         I2S_LRCK,    // WS
    output reg         I2S_DIN      // SDATA
    );

    reg [5:0]  bit_cnt = 0;
    reg [23:0] shift_reg;
    reg [23:0] latched_R;

    always @(negedge I2S_BCLK or negedge RSTN) begin // Falling Edge Output
        if (!RSTN) begin
            bit_cnt   <= 0;
            I2S_LRCK  <= 0;
            I2S_DIN   <= 0;
            shift_reg <= 0;
        end else begin
            // 1. Counter & WS
            if (bit_cnt == 63) bit_cnt <= 0;
            else               bit_cnt <= bit_cnt + 1;

            if (bit_cnt == 31)      I2S_LRCK <= 1;
            else if (bit_cnt == 63) I2S_LRCK <= 0;

            // 2. Data Load & Shift (Standard I2S Timing)
            
            // [Load Left]
            if (bit_cnt == 63) begin
                shift_reg <= L_DATA_IN;
                I2S_DIN   <= 0; // Padding (Delay Slot)
            end
            // [Load Right]
            else if (bit_cnt == 31) begin
                shift_reg <= R_DATA_IN; 
                I2S_DIN   <= 0; // Padding (Delay Slot)
            end
            // [Shift Data] (0   32          ?       ?      )
            else if ((bit_cnt >= 0 && bit_cnt <= 23) || (bit_cnt >= 32 && bit_cnt <= 55)) begin
                // ? ?      : bit_cnt   0      Load      , 
                // bit_cnt 1    ?      (       ) MSB            
                I2S_DIN   <= shift_reg[23];
                shift_reg <= {shift_reg[22:0], 1'b0};
            end
            else begin
                I2S_DIN <= 0; //             0
            end
        end
    end
endmodule