module AI_Calculte #(
    parameter IN_DW   = 8,     // Feature 입력 bit width
    parameter W_DW    = 8,     // Weight ROM bit width
    parameter B_DW    = 32,    // Bias ROM bit width
    parameter ACT_DW  = 16,    // Hidden activation 저장 bit width
    parameter ACC_DW  = 48,    // MAC accumulator bit width

    parameter N_IN    = 111,
    parameter N_L0    = 32,
    parameter N_L1    = 16,

    // Colab export PTQ requantization parameters
    // 0502_MLP.ipynb cell 13 output
    parameter signed [31:0] L0_REQUANT_MUL   = 32'sd5068,
    parameter        [5:0]  L0_REQUANT_SHIFT = 6'd20,
    parameter signed [31:0] L1_REQUANT_MUL   = 32'sd2838,
    parameter        [5:0]  L1_REQUANT_SHIFT = 6'd20,

    // sigmoid threshold 0.70 converted by layer2 accumulator scale
    parameter signed [47:0] THRESHOLD_SCORE = -48'sd4500,
    parameter [3:0] CONSECUTIVE_NEED_COUNT = 4'd1,


    // ROM address width
    parameter L0_W_ADDR_W = 12,   // 32*111 = 3552
    parameter L0_B_ADDR_W = 5,    // 32
    parameter L1_W_ADDR_W = 9,    // 16*32 = 512
    parameter L1_B_ADDR_W = 4,    // 16
    parameter L2_W_ADDR_W = 4,    // 16
    parameter L2_B_ADDR_W = 1     // 1
)(
    input  wire                  CLK,
    input  wire                  RSTN,

    // Feature write interface
    input  wire                  input_we,
    input  wire [6:0]            input_waddr,
    input  wire [IN_DW-1:0]      input_wdata,

    // Start pulse
    input  wire                  ai_start,

    // Result
    output reg                   ai_done,
    output wire                  ai_busy,
    output reg                   siren_detected,
    output reg  [15:0]           siren_score,
    output reg  [7:0]            confidence,
    output reg  signed [31:0]    final_logit,

    // Debug read interface
    input  wire                  output_re,
    input  wire [3:0]            output_raddr,
    output reg  [31:0]           output_rdata
);

    // ============================================================
    // 1. Internal memories
    // ============================================================
    reg [IN_DW-1:0] input_mem [0:N_IN-1];

    reg signed [ACT_DW-1:0] l0_act [0:N_L0-1];
    reg signed [ACT_DW-1:0] l1_act [0:N_L1-1];

    integer i;


    // ============================================================
    // 2. ROM address / data wires
    // ============================================================
    reg  [L0_W_ADDR_W-1:0] l0_w_addr;
    reg  [L0_B_ADDR_W-1:0] l0_b_addr;
    reg  [L1_W_ADDR_W-1:0] l1_w_addr;
    reg  [L1_B_ADDR_W-1:0] l1_b_addr;
    reg  [L2_W_ADDR_W-1:0] l2_w_addr;
    reg  [L2_B_ADDR_W-1:0] l2_b_addr;

    wire [W_DW-1:0] l0_w_dout;
    wire [B_DW-1:0] l0_b_dout;
    wire [W_DW-1:0] l1_w_dout;
    wire [B_DW-1:0] l1_b_dout;
    wire [W_DW-1:0] l2_w_dout;
    wire [B_DW-1:0] l2_b_dout;


    // ============================================================
    // 3. COE ROM BRAM instances
    //    Vivado Block Memory Generator 기준:
    //    clka, ena, addra, douta 포트 사용
    // ============================================================

    ROM_L0_W U_ROM_L0_W (
        .clka  (CLK),
        .ena   (1'b1),
        .addra (l0_w_addr),
        .douta (l0_w_dout)
    );

    ROM_L0_B U_ROM_L0_B (
        .clka  (CLK),
        .addra (l0_b_addr),
        .douta (l0_b_dout)
    );

    ROM_L1_W U_ROM_L1_W (
        .clka  (CLK),
        .addra (l1_w_addr),
        .douta (l1_w_dout)
    );

    ROM_L1_B U_ROM_L1_B (
        .clka  (CLK),
        .ena   (1'b1),
        .addra (l1_b_addr),
        .douta (l1_b_dout)
    );

    ROM_L2_W U_ROM_L2_W (
        .clka  (CLK),
        .addra (l2_w_addr),
        .douta (l2_w_dout)
    );

    ROM_L2_B U_ROM_L2_B (
        .clka  (CLK),
        .ena   (1'b1),
        .addra (l2_b_addr),
        .douta (l2_b_dout)
    );


    // ============================================================
    // 4. FSM states
    // ============================================================
    localparam S_IDLE        = 5'd0;

    localparam S_L0_B_ADDR   = 5'd1;
    localparam S_L0_B_WAIT   = 5'd2;
    localparam S_L0_B_LOAD   = 5'd3;
    localparam S_L0_W_ADDR   = 5'd4;
    localparam S_L0_W_WAIT   = 5'd5;
    localparam S_L0_MAC      = 5'd6;

    localparam S_L1_B_ADDR   = 5'd7;
    localparam S_L1_B_WAIT   = 5'd8;
    localparam S_L1_B_LOAD   = 5'd9;
    localparam S_L1_W_ADDR   = 5'd10;
    localparam S_L1_W_WAIT   = 5'd11;
    localparam S_L1_MAC      = 5'd12;

    localparam S_L2_B_ADDR   = 5'd13;
    localparam S_L2_B_WAIT   = 5'd14;
    localparam S_L2_B_LOAD   = 5'd15;
    localparam S_L2_W_ADDR   = 5'd16;
    localparam S_L2_W_WAIT   = 5'd17;
    localparam S_L2_MAC      = 5'd18;

    localparam S_DONE        = 5'd19;

    reg [4:0] state;

    assign ai_busy = (state != S_IDLE);


    // ============================================================
    // 5. Index / accumulator
    // ============================================================
    reg [6:0] k_idx;
    reg [5:0] l0_neuron;
    reg [4:0] l1_neuron;

    reg [L0_W_ADDR_W-1:0] l0_base_addr;
    reg [L1_W_ADDR_W-1:0] l1_base_addr;

    reg signed [ACC_DW-1:0] acc;

    reg ai_start_d;
    reg rom_wait_phase;
    reg [3:0] consecutive_count;
    wire ai_start_pulse;

    assign ai_start_pulse = ai_start & ~ai_start_d;


    // ============================================================
    // 6. Signed conversion / MAC wires
    // ============================================================

    wire signed [W_DW-1:0] l0_w_s = l0_w_dout;
    wire signed [W_DW-1:0] l1_w_s = l1_w_dout;
    wire signed [W_DW-1:0] l2_w_s = l2_w_dout;

    wire signed [B_DW-1:0] l0_b_s = l0_b_dout;
    wire signed [B_DW-1:0] l1_b_s = l1_b_dout;
    wire signed [B_DW-1:0] l2_b_s = l2_b_dout;

    wire signed [ACC_DW-1:0] l0_b_ext =
        {{(ACC_DW-B_DW){l0_b_s[B_DW-1]}}, l0_b_s};

    wire signed [ACC_DW-1:0] l1_b_ext =
        {{(ACC_DW-B_DW){l1_b_s[B_DW-1]}}, l1_b_s};

    wire signed [ACC_DW-1:0] l2_b_ext =
        {{(ACC_DW-B_DW){l2_b_s[B_DW-1]}}, l2_b_s};


    // L0: signed int8 feature x signed int8 weight
    wire signed [IN_DW-1:0] l0_in_s;
    assign l0_in_s = input_mem[k_idx];

    wire signed [IN_DW+W_DW-1:0] l0_mul_raw;
    assign l0_mul_raw = l0_in_s * l0_w_s;

    wire signed [ACC_DW-1:0] l0_mul_ext;
    assign l0_mul_ext =
        {{(ACC_DW-(IN_DW+W_DW)){l0_mul_raw[IN_DW+W_DW-1]}}, l0_mul_raw};

    wire signed [ACC_DW-1:0] l0_sum_next;
    assign l0_sum_next = acc + l0_mul_ext;


    // L1: signed activation x signed weight
    wire signed [ACT_DW-1:0] l1_in_s;
    assign l1_in_s = l0_act[k_idx[4:0]];

    wire signed [ACT_DW+W_DW-1:0] l1_mul_raw;
    assign l1_mul_raw = l1_in_s * l1_w_s;

    wire signed [ACC_DW-1:0] l1_mul_ext;
    assign l1_mul_ext =
        {{(ACC_DW-(ACT_DW+W_DW)){l1_mul_raw[ACT_DW+W_DW-1]}}, l1_mul_raw};

    wire signed [ACC_DW-1:0] l1_sum_next;
    assign l1_sum_next = acc + l1_mul_ext;


    // L2: signed activation x signed weight
    wire signed [ACT_DW-1:0] l2_in_s;
    assign l2_in_s = l1_act[k_idx[3:0]];

    wire signed [ACT_DW+W_DW-1:0] l2_mul_raw;
    assign l2_mul_raw = l2_in_s * l2_w_s;

    wire signed [ACC_DW-1:0] l2_mul_ext;
    assign l2_mul_ext =
        {{(ACC_DW-(ACT_DW+W_DW)){l2_mul_raw[ACT_DW+W_DW-1]}}, l2_mul_raw};

    wire signed [ACC_DW-1:0] l2_sum_next;
    assign l2_sum_next = acc + l2_mul_ext;

    wire signed [ACC_DW-1:0] logit_margin;
    assign logit_margin = l2_sum_next - THRESHOLD_SCORE;


    // ============================================================
    // 7. Utility functions
    // ============================================================

    localparam [ACT_DW-1:0] ACT_MAX = {1'b0, {(ACT_DW-1){1'b1}}};

    function [ACT_DW-1:0] relu_requant;
        input signed [ACC_DW-1:0] value;
        input signed [31:0] mult;
        input [5:0] shift_amt;
        reg signed [ACC_DW+31:0] product;
        reg signed [ACC_DW+31:0] shifted;
        reg signed [ACC_DW+31:0] act_max_ext;
        begin
            product = value * mult;
            shifted = product >>> shift_amt;
            act_max_ext = {{(ACC_DW+32-ACT_DW){1'b0}}, ACT_MAX};

            if (shifted <= 0)
                relu_requant = {ACT_DW{1'b0}};
            else if (shifted > act_max_ext)
                relu_requant = ACT_MAX;
            else
                relu_requant = shifted[ACT_DW-1:0];
        end
    endfunction


    function [15:0] sat16_pos;
        input signed [ACC_DW-1:0] value;
        begin
            if (value <= 0)
                sat16_pos = 16'd0;
            else if (value > 48'sd65535)
                sat16_pos = 16'hFFFF;
            else
                sat16_pos = value[15:0];
        end
    endfunction


    function [7:0] sat8_pos;
        input signed [ACC_DW-1:0] value;
        begin
            if (value <= 0)
                sat8_pos = 8'd0;
            else if (value > 48'sd255)
                sat8_pos = 8'd255;
            else
                sat8_pos = value[7:0];
        end
    endfunction


    // ============================================================
    // 8. Input feature memory write
    // ============================================================
    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
            for (i = 0; i < N_IN; i = i + 1) begin
                input_mem[i] <= {IN_DW{1'b0}};
            end
        end else begin
            if (input_we && input_waddr < N_IN) begin
                input_mem[input_waddr] <= input_wdata;
            end
        end
    end


    // ============================================================
    // 9. Main FSM
    // ============================================================
    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
            state          <= S_IDLE;

            ai_start_d     <= 1'b0;
            ai_done        <= 1'b0;
            siren_detected <= 1'b0;
            siren_score    <= 16'd0;
            confidence     <= 8'd0;
            final_logit    <= 32'sd0;

            k_idx          <= 7'd0;
            l0_neuron      <= 6'd0;
            l1_neuron      <= 5'd0;

            l0_base_addr   <= {L0_W_ADDR_W{1'b0}};
            l1_base_addr   <= {L1_W_ADDR_W{1'b0}};

            l0_w_addr      <= {L0_W_ADDR_W{1'b0}};
            l0_b_addr      <= {L0_B_ADDR_W{1'b0}};
            l1_w_addr      <= {L1_W_ADDR_W{1'b0}};
            l1_b_addr      <= {L1_B_ADDR_W{1'b0}};
            l2_w_addr      <= {L2_W_ADDR_W{1'b0}};
            l2_b_addr      <= {L2_B_ADDR_W{1'b0}};

            acc            <= {ACC_DW{1'b0}};
            rom_wait_phase <= 1'b0;
            consecutive_count <= 4'd0;

            for (i = 0; i < N_L0; i = i + 1) begin
                l0_act[i] <= {ACT_DW{1'b0}};
            end

            for (i = 0; i < N_L1; i = i + 1) begin
                l1_act[i] <= {ACT_DW{1'b0}};
            end
        end else begin
            ai_start_d <= ai_start;
            ai_done    <= 1'b0;

            case (state)

                // ------------------------------------------------
                // IDLE
                // ------------------------------------------------
                S_IDLE: begin
                    if (ai_start_pulse) begin
                        l0_neuron    <= 6'd0;
                        l1_neuron    <= 5'd0;
                        k_idx        <= 7'd0;
                        l0_base_addr <= {L0_W_ADDR_W{1'b0}};
                        l1_base_addr <= {L1_W_ADDR_W{1'b0}};
                        acc          <= {ACC_DW{1'b0}};

                        state        <= S_L0_B_ADDR;
                    end
                end


                // =================================================
                // Layer 0: 111 -> 32, ReLU
                // =================================================
                S_L0_B_ADDR: begin
                    l0_b_addr <= l0_neuron[L0_B_ADDR_W-1:0];
                    rom_wait_phase <= 1'b0;
                    state     <= S_L0_B_WAIT;
                end

                S_L0_B_WAIT: begin
                    if (!rom_wait_phase) begin
                        rom_wait_phase <= 1'b1;
                    end else begin
                        rom_wait_phase <= 1'b0;
                        state <= S_L0_B_LOAD;
                    end
                end

                S_L0_B_LOAD: begin
                    acc   <= l0_b_ext;
                    k_idx <= 7'd0;
                    state <= S_L0_W_ADDR;
                end

                S_L0_W_ADDR: begin
                    l0_w_addr <= l0_base_addr + k_idx;
                    rom_wait_phase <= 1'b0;
                    state     <= S_L0_W_WAIT;
                end

                S_L0_W_WAIT: begin
                    if (!rom_wait_phase) begin
                        rom_wait_phase <= 1'b1;
                    end else begin
                        rom_wait_phase <= 1'b0;
                        state <= S_L0_MAC;
                    end
                end

                S_L0_MAC: begin
                    if (k_idx == N_IN-1) begin
                        l0_act[l0_neuron] <= relu_requant(l0_sum_next, L0_REQUANT_MUL, L0_REQUANT_SHIFT);

                        if (l0_neuron == N_L0-1) begin
                            l1_neuron    <= 5'd0;
                            l1_base_addr <= {L1_W_ADDR_W{1'b0}};
                            state        <= S_L1_B_ADDR;
                        end else begin
                            l0_neuron    <= l0_neuron + 6'd1;
                            l0_base_addr <= l0_base_addr + N_IN;
                            state        <= S_L0_B_ADDR;
                        end
                    end else begin
                        acc   <= l0_sum_next;
                        k_idx <= k_idx + 7'd1;
                        state <= S_L0_W_ADDR;
                    end
                end


                // =================================================
                // Layer 1: 32 -> 16, ReLU
                // =================================================
                S_L1_B_ADDR: begin
                    l1_b_addr <= l1_neuron[L1_B_ADDR_W-1:0];
                    rom_wait_phase <= 1'b0;
                    state     <= S_L1_B_WAIT;
                end

                S_L1_B_WAIT: begin
                    if (!rom_wait_phase) begin
                        rom_wait_phase <= 1'b1;
                    end else begin
                        rom_wait_phase <= 1'b0;
                        state <= S_L1_B_LOAD;
                    end
                end

                S_L1_B_LOAD: begin
                    acc   <= l1_b_ext;
                    k_idx <= 7'd0;
                    state <= S_L1_W_ADDR;
                end

                S_L1_W_ADDR: begin
                    l1_w_addr <= l1_base_addr + k_idx;
                    rom_wait_phase <= 1'b0;
                    state     <= S_L1_W_WAIT;
                end

                S_L1_W_WAIT: begin
                    if (!rom_wait_phase) begin
                        rom_wait_phase <= 1'b1;
                    end else begin
                        rom_wait_phase <= 1'b0;
                        state <= S_L1_MAC;
                    end
                end

                S_L1_MAC: begin
                    if (k_idx == N_L0-1) begin
                        l1_act[l1_neuron] <= relu_requant(l1_sum_next, L1_REQUANT_MUL, L1_REQUANT_SHIFT);

                        if (l1_neuron == N_L1-1) begin
                            state <= S_L2_B_ADDR;
                        end else begin
                            l1_neuron    <= l1_neuron + 5'd1;
                            l1_base_addr <= l1_base_addr + N_L0;
                            state        <= S_L1_B_ADDR;
                        end
                    end else begin
                        acc   <= l1_sum_next;
                        k_idx <= k_idx + 7'd1;
                        state <= S_L1_W_ADDR;
                    end
                end


                // =================================================
                // Layer 2: 16 -> 1, final logit
                // =================================================
                S_L2_B_ADDR: begin
                    l2_b_addr <= {L2_B_ADDR_W{1'b0}};
                    rom_wait_phase <= 1'b0;
                    state     <= S_L2_B_WAIT;
                end

                S_L2_B_WAIT: begin
                    if (!rom_wait_phase) begin
                        rom_wait_phase <= 1'b1;
                    end else begin
                        rom_wait_phase <= 1'b0;
                        state <= S_L2_B_LOAD;
                    end
                end

                S_L2_B_LOAD: begin
                    acc   <= l2_b_ext;
                    k_idx <= 7'd0;
                    state <= S_L2_W_ADDR;
                end

                S_L2_W_ADDR: begin
                    l2_w_addr <= k_idx[L2_W_ADDR_W-1:0];
                    rom_wait_phase <= 1'b0;
                    state     <= S_L2_W_WAIT;
                end

                S_L2_W_WAIT: begin
                    if (!rom_wait_phase) begin
                        rom_wait_phase <= 1'b1;
                    end else begin
                        rom_wait_phase <= 1'b0;
                        state <= S_L2_MAC;
                    end
                end

                S_L2_MAC: begin
                    if (k_idx == N_L1-1) begin
                        final_logit <= l2_sum_next[31:0];

                        if (l2_sum_next >= THRESHOLD_SCORE) begin
                            if (consecutive_count >= CONSECUTIVE_NEED_COUNT - 1'b1) begin
                                siren_detected <= 1'b1;
                                siren_score    <= sat16_pos(logit_margin);
                                confidence     <= sat8_pos(logit_margin);
                            end else begin
                                siren_detected <= 1'b0;
                                siren_score    <= 16'd0;
                                confidence     <= 8'd0;
                            end

                            if (consecutive_count < 4'hf)
                                consecutive_count <= consecutive_count + 1'b1;
                        end else begin
                            consecutive_count <= 4'd0;
                            siren_detected    <= 1'b0;
                            siren_score       <= 16'd0;
                            confidence        <= 8'd0;
                        end

                        state <= S_DONE;
                    end else begin
                        acc   <= l2_sum_next;
                        k_idx <= k_idx + 7'd1;
                        state <= S_L2_W_ADDR;
                    end
                end


                // ------------------------------------------------
                // DONE
                // ------------------------------------------------
                S_DONE: begin
                    ai_done <= 1'b1;
                    state   <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end

            endcase
        end
    end


    // ============================================================
    // 10. Debug output
    // ============================================================
    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
            output_rdata <= 32'd0;
        end else begin
            if (output_re) begin
                case (output_raddr)
                    4'd0: output_rdata <= {31'd0, siren_detected};
                    4'd1: output_rdata <= {16'd0, siren_score};
                    4'd2: output_rdata <= {24'd0, confidence};
                    4'd3: output_rdata <= final_logit;
                    4'd4: output_rdata <= {27'd0, state};
                    4'd5: output_rdata <= {25'd0, k_idx};
                    4'd6: output_rdata <= {26'd0, l0_neuron};
                    4'd7: output_rdata <= {27'd0, l1_neuron};
                    default: output_rdata <= 32'd0;
                endcase
            end
        end
    end

endmodule