`timescale 1ns/1ps

module TB_Feature;

    reg CLK;
    reg RSTN;
    reg [23:0] MIC_L_DATA;
    reg SAMPLE_VALID;

    wire feat_we;
    wire [6:0] feat_addr;
    wire signed [7:0] feat_wdata;
    wire feature_mlp_start;
    wire feature_busy;
    wire feature_frame_done;
    wire feature_fft_done;
    wire feature_sample_drop;

    reg tb_inject_mode;
    reg tb_input_we;
    reg [6:0] tb_input_waddr;
    reg signed [7:0] tb_input_wdata;
    reg tb_ai_start;

    wire ai_input_we;
    wire [6:0] ai_input_waddr;
    wire signed [7:0] ai_input_wdata;
    wire ai_start;

    wire ai_done;
    wire ai_busy;
    wire siren_detected;
    wire [15:0] siren_score;
    wire [7:0] ai_confidence;
    wire signed [31:0] final_logit;
    wire [31:0] ai_output_rdata;

    integer sample_idx;
    integer ai_done_count;
    integer mismatch_count;
    reg saw_siren_detected;
    reg signed [31:0] expected_logit [0:6];
    reg expected_detect [0:6];
    real PI;
    real sine_val;
    real freq;
    real amp;
    real fs;
    reg signed [23:0] sample_now;

    assign ai_input_we    = tb_inject_mode ? tb_input_we    : feat_we;
    assign ai_input_waddr = tb_inject_mode ? tb_input_waddr : feat_addr;
    assign ai_input_wdata = tb_inject_mode ? tb_input_wdata : feat_wdata;
    assign ai_start       = tb_inject_mode ? tb_ai_start    : feature_mlp_start;

    Feature u_feature (
        .CLK(CLK),
        .RSTN(RSTN),
        .MIC_L_DATA(MIC_L_DATA),
        .SAMPLE_VALID(SAMPLE_VALID),
        .MLP_BUSY(ai_busy),
        .FEATURE_WE(feat_we),
        .FEATURE_ADDR(feat_addr),
        .FEATURE_WDATA(feat_wdata),
        .MLP_START(feature_mlp_start),
        .BUSY(feature_busy),
        .FRAME_FEATURE_DONE(feature_frame_done),
        .FFT_FRAME_DONE(feature_fft_done),
        .SAMPLE_DROP(feature_sample_drop)
    );

    AI_Calculte u_ai (
        .CLK(CLK),
        .RSTN(RSTN),
        .input_we(ai_input_we),
        .input_waddr(ai_input_waddr),
        .input_wdata(ai_input_wdata),
        .ai_start(ai_start),
        .ai_done(ai_done),
        .ai_busy(ai_busy),
        .siren_detected(siren_detected),
        .siren_score(siren_score),
        .confidence(ai_confidence),
        .final_logit(final_logit),
        .output_re(1'b0),
        .output_raddr(4'd0),
        .output_rdata(ai_output_rdata)
    );

    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    task inject_positive_vector;
        integer j;
        begin
            wait (ai_busy == 1'b0);
            @(posedge CLK);

            for (j = 0; j < 111; j = j + 1) begin
                tb_input_we    <= 1'b1;
                tb_input_waddr <= j[6:0];
                tb_input_wdata <= j[0] ? -8'sd56 : 8'sd20;
                @(posedge CLK);
            end

            tb_input_we <= 1'b0;
            @(posedge CLK);
            tb_ai_start <= 1'b1;
            @(posedge CLK);
            tb_ai_start <= 1'b0;
        end
    endtask

    initial begin
        RSTN = 1'b0;
        MIC_L_DATA = 24'd0;
        SAMPLE_VALID = 1'b0;
        tb_inject_mode = 1'b0;
        tb_input_we = 1'b0;
        tb_input_waddr = 7'd0;
        tb_input_wdata = 8'sd0;
        tb_ai_start = 1'b0;
        sample_idx = 0;
        ai_done_count = 0;
        mismatch_count = 0;
        saw_siren_detected = 1'b0;

        expected_logit[0] = -32'sd11268;
        expected_logit[1] = -32'sd11474;
        expected_logit[2] = -32'sd15060;
        expected_logit[3] = -32'sd12799;
        expected_logit[4] = -32'sd12442;
        expected_logit[5] =  32'sd25404;
        expected_logit[6] =  32'sd25404;
        expected_detect[0] = 1'b0;
        expected_detect[1] = 1'b0;
        expected_detect[2] = 1'b0;
        expected_detect[3] = 1'b0;
        expected_detect[4] = 1'b0;
        expected_detect[5] = 1'b0;
        expected_detect[6] = 1'b1;

        PI = 3.14159265358979323846;
        fs = 48000.0;
        amp = 2000000.0;

        repeat (20) @(posedge CLK);
        RSTN = 1'b1;
        repeat (20) @(posedge CLK);

        while (ai_done_count < 5) begin
            @(posedge CLK);
            sample_idx = sample_idx + 1;

            if (sample_idx < 9000)
                freq = 300.0;
            else
                freq = 2500.0;

            sine_val = amp * $sin(2.0 * PI * freq * (sample_idx / fs));
            sample_now = $rtoi(sine_val);
            MIC_L_DATA <= sample_now;
            SAMPLE_VALID <= 1'b1;
        end

        SAMPLE_VALID <= 1'b0;
        MIC_L_DATA <= 24'd0;
        repeat (20) @(posedge CLK);

        $display("Starting injected positive siren feature checks.");
        tb_inject_mode <= 1'b1;

        inject_positive_vector();
        wait (ai_done_count >= 6);
        repeat (10) @(posedge CLK);

        inject_positive_vector();
        wait (ai_done_count >= 7);
    end

    always @(posedge CLK) begin
        if (RSTN && feature_frame_done) begin
            $display("[%0t] FEATURE_DONE sample_idx=%0d", $time, sample_idx);
        end

        if (RSTN && feature_fft_done) begin
            $display("[%0t] FFT_FRAME_DONE sample_idx=%0d", $time, sample_idx);
        end

        if (RSTN && feature_sample_drop) begin
            $display("[%0t] WARNING: FEATURE_SAMPLE_DROP sample_idx=%0d", $time, sample_idx);
        end
    end

    always @(posedge ai_done) begin
        ai_done_count = ai_done_count + 1;

        $display("=================================================");
        $display("[%0t] AI_DONE #%0d", $time, ai_done_count);
        $display("siren_detected = %0d", siren_detected);
        $display("siren_score    = %0d", siren_score);
        $display("confidence     = %0d", ai_confidence);
        $display("final_logit    = %0d", final_logit);
        $display("sample_idx     = %0d", sample_idx);
        $display("=================================================");

        if (siren_detected)
            saw_siren_detected = 1'b1;

        if (ai_done_count <= 7) begin
            if (final_logit !== expected_logit[ai_done_count - 1] || siren_detected !== expected_detect[ai_done_count - 1]) begin
                mismatch_count = mismatch_count + 1;
                $display("MISMATCH #%0d: expected_detect=%0d expected_logit=%0d", ai_done_count, expected_detect[ai_done_count - 1], expected_logit[ai_done_count - 1]);
            end else begin
                $display("MATCH #%0d: Colab golden detect/logit matched.", ai_done_count);
            end
        end

        if (ai_done_count >= 7) begin
            if (mismatch_count == 0 && saw_siren_detected)
                $display("PASS: Feature negative path and injected positive siren path matched Colab golden outputs.");
            else
                $display("FAIL: mismatch_count=%0d saw_siren_detected=%0d", mismatch_count, saw_siren_detected);
            $finish;
        end
    end

    initial begin
        #20_000_000;
        $display("FAIL: timeout before 7 AI results. ai_done_count=%0d sample_idx=%0d", ai_done_count, sample_idx);
        $finish;
    end

endmodule