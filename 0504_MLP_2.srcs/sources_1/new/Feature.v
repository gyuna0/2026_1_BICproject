`timescale 1ns / 1ps

module Feature #(
    parameter FFT_SIZE             = 512,
    parameter FFT_BLOCKS_PER_FRAME = 16,
    parameter FRAME_SAMPLES        = 8192,
    parameter N_BANDS              = 16,
    parameter BINS_PER_BAND        = 16,
    parameter FEAT_PER_FRAME       = 37,
    parameter CONTEXT_DIM          = 111,

    parameter FFT_IN_WIDTH         = 16,
    parameter FFT_OUT_WIDTH         = 16,
    parameter FFT_POWER_RESTORE_SHIFT = 20,

    parameter DECIMATE             = 3,
    parameter NOISE_FLOOR          = 2
)(
    input  wire              CLK,
    input  wire              RSTN,

    input  wire [23:0]       MIC_L_DATA,
    input  wire              SAMPLE_VALID,

    input  wire              MLP_BUSY,

    output reg               FEATURE_WE,
    output reg  [6:0]        FEATURE_ADDR,
    output reg signed [7:0]  FEATURE_WDATA,
    output reg               MLP_START,

    output reg               BUSY,
    output reg               FRAME_FEATURE_DONE,
    output reg               FFT_FRAME_DONE,
    output reg               SAMPLE_DROP
);

    // =========================================================
    // State definition
    // =========================================================
    localparam S_COLLECT        = 4'd0;
    localparam S_WAIT_FFT       = 4'd1;
    localparam S_BUILD_INIT     = 4'd2;
    localparam S_SUM_PEAK       = 4'd3;
    localparam S_FIND_TOTAL_MSB = 4'd4;
    localparam S_BUILD_BASIC    = 4'd5;
    localparam S_FIND_BAND_MSB  = 4'd6;
    localparam S_WRITE_BAND     = 4'd7;
    localparam S_WAIT_MLP       = 4'd8;
    localparam S_SEND           = 4'd9;
    localparam S_SHIFT_RST      = 4'd10;

    reg [3:0] state;

    // =========================================================
    // FFT AXI wires - 내부 xfft_0 연결용
    // =========================================================
    wire [31:0] fft_s_tdata;
    wire        fft_s_tvalid;
    wire        fft_s_tready;
    wire        fft_s_tlast;

    wire [31:0] fft_m_tdata;
    wire        fft_m_tvalid;
    wire        fft_m_tready;
    wire        fft_m_tlast;

    wire [15:0] fft_config_tdata;
    wire        fft_config_tvalid;
    wire        fft_config_tready;

    wire        event_frame_started;
    wire        event_tlast_unexpected;
    wire        event_tlast_missing;
    wire        event_status_channel_halt;
    wire        event_data_in_channel_halt;
    wire        event_data_out_channel_halt;

    // =========================================================
    // FFT config
    // xfft_0.veo 기준:
    // s_axis_config_tdata = 16-bit
    //
    // 16'h0001: forward FFT 기본 설정
    // DC test에서 정상 동작 확인된 값
    // =========================================================
    reg fft_config_sent;

    assign fft_config_tdata  = 16'h0357;
    assign fft_config_tvalid = !fft_config_sent;

    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
            fft_config_sent <= 1'b0;
        end else begin
            if (fft_config_tvalid && fft_config_tready) begin
                fft_config_sent <= 1'b1;
            end
        end
    end

    assign fft_m_tready = 1'b1;

    // =========================================================
    // FFT IP Instance - Feature 내부에 포함
    // =========================================================
    xfft_0 u_fft (
        .aclk                       (CLK),

        .s_axis_config_tdata        (fft_config_tdata),
        .s_axis_config_tvalid       (fft_config_tvalid),
        .s_axis_config_tready       (fft_config_tready),

        .s_axis_data_tdata          (fft_s_tdata),
        .s_axis_data_tvalid         (fft_s_tvalid),
        .s_axis_data_tready         (fft_s_tready),
        .s_axis_data_tlast          (fft_s_tlast),

        .m_axis_data_tdata          (fft_m_tdata),
        .m_axis_data_tvalid         (fft_m_tvalid),
        .m_axis_data_tready         (fft_m_tready),
        .m_axis_data_tlast          (fft_m_tlast),

        .event_frame_started        (event_frame_started),
        .event_tlast_unexpected     (event_tlast_unexpected),
        .event_tlast_missing        (event_tlast_missing),
        .event_status_channel_halt  (event_status_channel_halt),
        .event_data_in_channel_halt (event_data_in_channel_halt),
        .event_data_out_channel_halt(event_data_out_channel_halt)
    );

    // =========================================================
    // FFT input pending buffer
    // =========================================================
    reg                         pending_valid;
    reg signed [FFT_IN_WIDTH-1:0] pending_real;
    reg                         pending_last;

    assign fft_s_tvalid = pending_valid;
    assign fft_s_tdata  = {{FFT_IN_WIDTH{1'b0}}, pending_real};
    assign fft_s_tlast  = pending_last;

    // =========================================================
    // FFT output unpack
    // 현재 가정:
    // fft_m_tdata[15:0]  = real
    // fft_m_tdata[31:16] = imag
    // =========================================================
    wire signed [FFT_OUT_WIDTH-1:0] fft_re;
    wire signed [FFT_OUT_WIDTH-1:0] fft_im;

    assign fft_re = fft_m_tdata[FFT_OUT_WIDTH-1:0];
    assign fft_im = fft_m_tdata[2*FFT_OUT_WIDTH-1:FFT_OUT_WIDTH];

    // =========================================================
    // MIC sample conversion
    // =========================================================
    wire signed [15:0] mic_s16;
    wire signed [7:0]  mic_s8;

    assign mic_s16 = MIC_L_DATA[23:8];
    assign mic_s8  = MIC_L_DATA[23:16];

    // =========================================================
    // Counters
    // =========================================================
    reg [1:0]  decim_cnt;

    reg [12:0] frame_sample_cnt;
    reg [8:0]  fft_in_sample_cnt;

    reg [8:0]  fft_out_bin_cnt;
    reg [4:0]  fft_out_block_cnt;

    reg [6:0]  send_idx;

    // =========================================================
    // Feature accumulators
    // =========================================================
    reg [31:0] sum_abs;
    reg [15:0] zcr_count;

    reg        prev_sign;
    reg        prev_valid;

    reg [63:0] band_energy [0:N_BANDS-1];

    // =========================================================
    // Feature memories
    // =========================================================
    reg signed [7:0] frame_feat [0:FEAT_PER_FRAME-1];
    reg signed [7:0] ctx1_feat  [0:FEAT_PER_FRAME-1];
    reg signed [7:0] ctx2_feat  [0:FEAT_PER_FRAME-1];

    reg signed [7:0] prev_energy_feat;
    reg signed [7:0] prev_peak_feat;

    // =========================================================
    // FSM variables
    // =========================================================
    reg [4:0]  band_idx;
    reg [5:0]  bit_idx;

    reg [63:0] total_energy;
    reg [63:0] peak_val;
    reg [3:0]  peak_idx;

    reg [5:0]  total_msb;
    reg [5:0]  norm_shift;
    reg [5:0]  band_msb;

    reg signed [7:0] energy_calc;
    reg signed [7:0] zcr_calc;
    reg signed [7:0] peak_calc;

    reg signed [8:0] delta_calc;

    reg [31:0] tmp32;
    reg [63:0] tmp64;
    reg [15:0] log_tmp;

    integer i;

    // =========================================================
    // abs for signed int8
    // =========================================================
    reg [8:0] abs_mic_s8;

    always @(*) begin
        if (mic_s8 < 0)
            abs_mic_s8 = -mic_s8;
        else
            abs_mic_s8 = mic_s8;
    end

    // =========================================================
    // FFT output power = real^2 + imag^2
    // =========================================================
    wire signed [2*FFT_OUT_WIDTH-1:0] re_sq_s;
    wire signed [2*FFT_OUT_WIDTH-1:0] im_sq_s;
    wire [2*FFT_OUT_WIDTH:0]          power_bin;

    assign re_sq_s = fft_re * fft_re;
    assign im_sq_s = fft_im * fft_im;

    assign power_bin =
        {1'b0, re_sq_s[2*FFT_OUT_WIDTH-1:0]} +
        {1'b0, im_sq_s[2*FFT_OUT_WIDTH-1:0]};

    wire [3:0] current_band;
    assign current_band = fft_out_bin_cnt[7:4];

    // =========================================================
    // Main FSM
    // =========================================================
    always @(posedge CLK or negedge RSTN) begin
        if (!RSTN) begin
            state              <= S_COLLECT;

            pending_valid      <= 1'b0;
            pending_real       <= 0;
            pending_last       <= 1'b0;

            decim_cnt          <= 0;
            frame_sample_cnt   <= 0;
            fft_in_sample_cnt  <= 0;
            fft_out_bin_cnt    <= 0;
            fft_out_block_cnt  <= 0;
            send_idx           <= 0;

            sum_abs            <= 0;
            zcr_count          <= 0;
            prev_sign          <= 0;
            prev_valid         <= 0;

            prev_energy_feat   <= 0;
            prev_peak_feat     <= 0;

            band_idx           <= 0;
            bit_idx            <= 0;

            total_energy       <= 0;
            peak_val           <= 0;
            peak_idx           <= 0;
            total_msb          <= 0;
            norm_shift         <= 0;
            band_msb           <= 0;

            energy_calc        <= 0;
            zcr_calc           <= 0;
            peak_calc          <= 0;
            delta_calc         <= 0;

            tmp32              <= 0;
            tmp64              <= 0;
            log_tmp            <= 0;

            FEATURE_WE         <= 1'b0;
            FEATURE_ADDR       <= 0;
            FEATURE_WDATA      <= 0;
            MLP_START          <= 1'b0;

            BUSY               <= 1'b0;
            FRAME_FEATURE_DONE <= 1'b0;
            FFT_FRAME_DONE     <= 1'b0;
            SAMPLE_DROP        <= 1'b0;

            for (i = 0; i < N_BANDS; i = i + 1) begin
                band_energy[i] <= 0;
            end

            for (i = 0; i < FEAT_PER_FRAME; i = i + 1) begin
                frame_feat[i] <= 0;
                ctx1_feat[i]  <= 0;
                ctx2_feat[i]  <= 0;
            end

        end else begin
            FEATURE_WE         <= 1'b0;
            MLP_START          <= 1'b0;
            FRAME_FEATURE_DONE <= 1'b0;
            FFT_FRAME_DONE     <= 1'b0;
            SAMPLE_DROP        <= 1'b0;

            // =====================================================
            // FFT input handshake
            // =====================================================
            if (pending_valid && fft_s_tready) begin
                pending_valid <= 1'b0;
                pending_last  <= 1'b0;
            end

            // =====================================================
            // FFT output processing
            // =====================================================
            if ((state == S_COLLECT || state == S_WAIT_FFT) && fft_m_tvalid) begin
                if (fft_out_bin_cnt < 9'd256) begin
                    band_energy[current_band] <= band_energy[current_band] + ({31'd0, power_bin} << FFT_POWER_RESTORE_SHIFT);
                end

                if (fft_m_tlast) begin
                    fft_out_bin_cnt <= 0;

                    if (fft_out_block_cnt == FFT_BLOCKS_PER_FRAME - 1) begin
                        fft_out_block_cnt <= 0;
                        FFT_FRAME_DONE    <= 1'b1;
                        state             <= S_BUILD_INIT;
                    end else begin
                        fft_out_block_cnt <= fft_out_block_cnt + 1'b1;
                    end
                end else begin
                    fft_out_bin_cnt <= fft_out_bin_cnt + 1'b1;
                end
            end

            case (state)

                S_COLLECT: begin
                    BUSY <= 1'b0;

                    if (SAMPLE_VALID) begin
                        if (decim_cnt == DECIMATE - 1)
                            decim_cnt <= 0;
                        else
                            decim_cnt <= decim_cnt + 1'b1;

                        if (decim_cnt == 0) begin
                            if (!pending_valid) begin
                                pending_valid <= 1'b1;
                                pending_real  <= mic_s16;
                                pending_last  <= (fft_in_sample_cnt == FFT_SIZE - 1);

                                sum_abs <= sum_abs + abs_mic_s8;

                                if (prev_valid && (abs_mic_s8 > NOISE_FLOOR)) begin
                                    if (prev_sign != mic_s8[7])
                                        zcr_count <= zcr_count + 1'b1;
                                end

                                if (abs_mic_s8 > NOISE_FLOOR) begin
                                    prev_sign  <= mic_s8[7];
                                    prev_valid <= 1'b1;
                                end

                                if (fft_in_sample_cnt == FFT_SIZE - 1)
                                    fft_in_sample_cnt <= 0;
                                else
                                    fft_in_sample_cnt <= fft_in_sample_cnt + 1'b1;

                                if (frame_sample_cnt == FRAME_SAMPLES - 1) begin
                                    frame_sample_cnt <= 0;
                                    state            <= S_WAIT_FFT;
                                    BUSY             <= 1'b1;
                                end else begin
                                    frame_sample_cnt <= frame_sample_cnt + 1'b1;
                                end
                            end else begin
                                SAMPLE_DROP <= 1'b1;
                            end
                        end
                    end
                end

                S_WAIT_FFT: begin
                    BUSY <= 1'b1;
                end

                S_BUILD_INIT: begin
                    BUSY         <= 1'b1;
                    total_energy <= 0;
                    peak_val     <= 0;
                    peak_idx     <= 0;
                    band_idx     <= 0;
                    state        <= S_SUM_PEAK;
                end

                S_SUM_PEAK: begin
                    total_energy <= total_energy + band_energy[band_idx];

                    if (band_energy[band_idx] > peak_val) begin
                        peak_val <= band_energy[band_idx];
                        peak_idx <= band_idx[3:0];
                    end

                    if (band_idx == N_BANDS - 1) begin
                        bit_idx <= 6'd63;
                        state   <= S_FIND_TOTAL_MSB;
                    end else begin
                        band_idx <= band_idx + 1'b1;
                    end
                end

                S_FIND_TOTAL_MSB: begin
                    if (total_energy[bit_idx]) begin
                        total_msb <= bit_idx;

                        if (bit_idx > 6'd7)
                            norm_shift <= bit_idx - 6'd7;
                        else
                            norm_shift <= 6'd0;

                        state <= S_BUILD_BASIC;
                    end else if (bit_idx == 0) begin
                        total_msb  <= 0;
                        norm_shift <= 0;
                        state      <= S_BUILD_BASIC;
                    end else begin
                        bit_idx <= bit_idx - 1'b1;
                    end
                end

                S_BUILD_BASIC: begin
                    tmp32 = sum_abs >> 13;

                    if (tmp32 > 127)
                        energy_calc = 8'sd127;
                    else
                        energy_calc = tmp32[7:0];

                    tmp32 = (zcr_count * 127) >> 13;

                    if (tmp32 > 127)
                        zcr_calc = 8'sd127;
                    else
                        zcr_calc = tmp32[7:0];

                    peak_calc = {1'b0, peak_idx, 3'b000};

                    frame_feat[0] <= energy_calc;
                    frame_feat[1] <= zcr_calc;
                    frame_feat[2] <= peak_calc;

                    delta_calc = energy_calc - prev_energy_feat;

                    if (delta_calc > 9'sd127)
                        frame_feat[35] <= 8'sd127;
                    else if (delta_calc < -9'sd128)
                        frame_feat[35] <= -8'sd128;
                    else
                        frame_feat[35] <= delta_calc[7:0];

                    delta_calc = peak_calc - prev_peak_feat;

                    if (delta_calc > 9'sd127)
                        frame_feat[36] <= 8'sd127;
                    else if (delta_calc < -9'sd128)
                        frame_feat[36] <= -8'sd128;
                    else
                        frame_feat[36] <= delta_calc[7:0];

                    prev_energy_feat <= energy_calc;
                    prev_peak_feat   <= peak_calc;

                    band_idx <= 0;
                    bit_idx  <= 6'd63;
                    state    <= S_FIND_BAND_MSB;
                end

                S_FIND_BAND_MSB: begin
                    if (band_energy[band_idx][bit_idx]) begin
                        band_msb <= bit_idx;
                        state    <= S_WRITE_BAND;
                    end else if (bit_idx == 0) begin
                        band_msb <= 0;
                        state    <= S_WRITE_BAND;
                    end else begin
                        bit_idx <= bit_idx - 1'b1;
                    end
                end

                S_WRITE_BAND: begin
                    log_tmp = band_msb * 6;

                    if (log_tmp > 127)
                        frame_feat[3 + band_idx] <= 8'sd127;
                    else
                        frame_feat[3 + band_idx] <= log_tmp[7:0];

                    tmp64 = band_energy[band_idx] >> norm_shift;

                    if (tmp64 > 127)
                        frame_feat[19 + band_idx] <= 8'sd127;
                    else
                        frame_feat[19 + band_idx] <= tmp64[7:0];

                    if (band_idx == N_BANDS - 1) begin
                        FRAME_FEATURE_DONE <= 1'b1;
                        send_idx <= 0;

                        if (MLP_BUSY)
                            state <= S_WAIT_MLP;
                        else
                            state <= S_SEND;
                    end else begin
                        band_idx <= band_idx + 1'b1;
                        bit_idx  <= 6'd63;
                        state    <= S_FIND_BAND_MSB;
                    end
                end

                S_WAIT_MLP: begin
                    BUSY <= 1'b1;

                    if (!MLP_BUSY) begin
                        send_idx <= 0;
                        state    <= S_SEND;
                    end
                end

                S_SEND: begin
                    BUSY <= 1'b1;

                    FEATURE_WE   <= 1'b1;
                    FEATURE_ADDR <= send_idx;

                    if (send_idx < FEAT_PER_FRAME) begin
                        FEATURE_WDATA <= ctx2_feat[send_idx];
                    end else if (send_idx < FEAT_PER_FRAME * 2) begin
                        FEATURE_WDATA <= ctx1_feat[send_idx - FEAT_PER_FRAME];
                    end else begin
                        FEATURE_WDATA <= frame_feat[send_idx - FEAT_PER_FRAME * 2];
                    end

                    if (send_idx == CONTEXT_DIM - 1) begin
                        send_idx <= 0;
                        state    <= S_SHIFT_RST;
                    end else begin
                        send_idx <= send_idx + 1'b1;
                    end
                end

                S_SHIFT_RST: begin
                    BUSY      <= 1'b1;
                    MLP_START <= 1'b1;

                    for (i = 0; i < FEAT_PER_FRAME; i = i + 1) begin
                        ctx2_feat[i] <= ctx1_feat[i];
                        ctx1_feat[i] <= frame_feat[i];
                    end

                    sum_abs           <= 0;
                    zcr_count         <= 0;
                    prev_valid        <= 0;

                    frame_sample_cnt  <= 0;
                    fft_in_sample_cnt <= 0;
                    fft_out_bin_cnt   <= 0;
                    fft_out_block_cnt <= 0;
                    decim_cnt         <= 0;

                    pending_valid     <= 1'b0;
                    pending_last      <= 1'b0;

                    for (i = 0; i < N_BANDS; i = i + 1) begin
                        band_energy[i] <= 0;
                    end

                    state <= S_COLLECT;
                end

                default: begin
                    state <= S_COLLECT;
                end

            endcase
        end
    end

endmodule