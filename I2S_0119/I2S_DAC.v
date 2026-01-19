module I2S_DAC(
		input wire	  RSTN,
		input wire	  I2S_BCLK,
		input wire [23:0] L_DATA_IN,
		input wire [23:0] R_DATA_IN,
		output reg I2S_LRCK,
		output reg I2S_DIN
	       );

   reg [5:0] bit_cnt;
   reg [23:0] shift_reg;
   reg [23:0] latched_R;

   reg [5:0]  bit_cnt_next;
   reg [23:0] shift_reg_next;
   reg [23:0] latched_R_next;
   reg	      I2S_LRCK_next;
   reg	      I2S_DIN_next;

   always @(negedge I2S_BCLK or negedge RSTN) begin
      if (!RSTN) begin
         bit_cnt   <= 0;
         shift_reg <= 0;
         latched_R <= 0;
         I2S_LRCK  <= 0;
         I2S_DIN   <= 0;
      end else begin
         bit_cnt   <= bit_cnt_next;
         shift_reg <= shift_reg_next;
         latched_R <= latched_R_next;
         I2S_LRCK  <= I2S_LRCK_next;
         I2S_DIN   <= I2S_DIN_next;
      end
   end

   always @(*) begin
      bit_cnt_next   = bit_cnt;
      shift_reg_next = shift_reg;
      latched_R_next = latched_R;
      I2S_LRCK_next  = I2S_LRCK;
      I2S_DIN_next   = I2S_DIN;

      if (bit_cnt == 63) 
        bit_cnt_next = 0;
      else 
        bit_cnt_next = bit_cnt + 1;

      if (bit_cnt == 63)      
        I2S_LRCK_next = 0;
      else if (bit_cnt == 31) 
        I2S_LRCK_next = 1;

      if (bit_cnt == 0) begin
         shift_reg_next = L_DATA_IN;
         latched_R_next = R_DATA_IN;
         I2S_DIN_next   = 0;
      end
      else if (bit_cnt == 32) begin
         shift_reg_next = latched_R;
         I2S_DIN_next   = 0;
      end
      else if ((bit_cnt >= 1 && bit_cnt <= 24) || (bit_cnt >= 33 && bit_cnt <= 56)) begin
         I2S_DIN_next   = shift_reg[23];
         shift_reg_next = {shift_reg[22:0], 1'b0};
      end
      else begin
         I2S_DIN_next = 0;
      end
   end

endmodule
