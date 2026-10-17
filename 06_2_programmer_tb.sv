`timescale 1ns/1ps

// Section 6 RTL verification testbench.
// Run from the CAD directory, for example:
//   iverilog -g2012 -s fc16_programmer_tb -o /tmp/fc16_tb.out \
//     06_2_programmer.v 06_2_programmer_tb.sv
//   vvp /tmp/fc16_tb.out
// An alternate asset directory may be supplied with +ASSET_DIR=<path>.
// A different image may be supplied with +IMAGE_MEM=<path>.
// For a non-golden image, use +SKIP_GOLDEN and optionally +EXPECTED_LABEL=<n>.

module fc16_programmer_tb;
  logic clk = 1'b0;
  logic rst = 1'b1;
  logic start = 1'b0;
  logic done;
  logic [3:0] prediction;
  logic [15:0] logit0, logit1, logit2, logit3, logit4;
  logic [15:0] logit5, logit6, logit7, logit8, logit9;

  logic [15:0] image_mem [0:783];
  logic [15:0] fc1_weight_mem [0:6271];
  logic [15:0] fc1_bias_mem [0:7];
  logic [15:0] fc2_weight_mem [0:79];
  logic [15:0] fc2_bias_mem [0:9];

  logic [15:0] expected_logits [0:9];
  integer i, row, lane;
  integer cycle_count;
  integer done_count;
  integer errors;
  string asset_dir;
  string image_file;
  integer expected_label;
  integer check_golden;

  fc16_accelerator dut (
    .clk(clk), .rst(rst), .start(start), .done(done),
    .prediction(prediction),
    .logit0(logit0), .logit1(logit1), .logit2(logit2), .logit3(logit3),
    .logit4(logit4), .logit5(logit5), .logit6(logit6), .logit7(logit7),
    .logit8(logit8), .logit9(logit9)
  );

  always #5 clk = ~clk;

  task automatic check_outputs;
    begin
      if (check_golden != 0) begin
        if (prediction !== 4'd2) begin
          $display("ERROR: prediction=%0d expected=2", prediction);
          errors = errors + 1;
        end
      end else if (expected_label >= 0 && prediction !== expected_label[3:0]) begin
        $display("ERROR: prediction=%0d expected label=%0d", prediction, expected_label);
        errors = errors + 1;
      end
      if (check_golden != 0) begin
        if (logit0 !== expected_logits[0]) begin $display("ERROR: logit0=%h expected=%h", logit0, expected_logits[0]); errors = errors + 1; end
      if (logit1 !== expected_logits[1]) begin $display("ERROR: logit1=%h expected=%h", logit1, expected_logits[1]); errors = errors + 1; end
      if (logit2 !== expected_logits[2]) begin $display("ERROR: logit2=%h expected=%h", logit2, expected_logits[2]); errors = errors + 1; end
      if (logit3 !== expected_logits[3]) begin $display("ERROR: logit3=%h expected=%h", logit3, expected_logits[3]); errors = errors + 1; end
      if (logit4 !== expected_logits[4]) begin $display("ERROR: logit4=%h expected=%h", logit4, expected_logits[4]); errors = errors + 1; end
      if (logit5 !== expected_logits[5]) begin $display("ERROR: logit5=%h expected=%h", logit5, expected_logits[5]); errors = errors + 1; end
      if (logit6 !== expected_logits[6]) begin $display("ERROR: logit6=%h expected=%h", logit6, expected_logits[6]); errors = errors + 1; end
      if (logit7 !== expected_logits[7]) begin $display("ERROR: logit7=%h expected=%h", logit7, expected_logits[7]); errors = errors + 1; end
      if (logit8 !== expected_logits[8]) begin $display("ERROR: logit8=%h expected=%h", logit8, expected_logits[8]); errors = errors + 1; end
        if (logit9 !== expected_logits[9]) begin $display("ERROR: logit9=%h expected=%h", logit9, expected_logits[9]); errors = errors + 1; end
      end
    end
  endtask

  initial begin
    asset_dir = "assests";
    void'($value$plusargs("ASSET_DIR=%s", asset_dir));
    image_file = {asset_dir, "/test_image.mem"};
    void'($value$plusargs("IMAGE_MEM=%s", image_file));
    expected_label = -1;
    void'($value$plusargs("EXPECTED_LABEL=%d", expected_label));
    check_golden = 1;
    if ($test$plusargs("SKIP_GOLDEN")) check_golden = 0;

    expected_logits[0] = 16'h411b;
    expected_logits[1] = 16'hc2bb;
    expected_logits[2] = 16'h4844;
    expected_logits[3] = 16'h43eb;
    expected_logits[4] = 16'hcd2b;
    expected_logits[5] = 16'h43e8;
    expected_logits[6] = 16'h444e;
    expected_logits[7] = 16'hcaa1;
    expected_logits[8] = 16'h3310;
    expected_logits[9] = 16'hcad4;

    $readmemh(image_file, image_mem);
    $readmemh({asset_dir, "/fc1_weights.mem"}, fc1_weight_mem);
    $readmemh({asset_dir, "/fc1_bias.mem"}, fc1_bias_mem);
    $readmemh({asset_dir, "/fc2_weights.mem"}, fc2_weight_mem);
    $readmemh({asset_dir, "/fc2_bias.mem"}, fc2_bias_mem);

    // The DUT intentionally has no functional initial block. Load its
    // externally supplied memories through the simulation hierarchy.
    for (i = 0; i < 784; i = i + 1)
      dut.im.pixel_mem[i] = image_mem[i];
    for (i = 0; i < 8; i = i + 1)
      dut.bm.bias_mem[i] = fc1_bias_mem[i];
    for (i = 0; i < 10; i = i + 1)
      dut.bm.bias_mem[8+i] = fc2_bias_mem[i];
    for (row = 0; row < 896; row = row + 1)
      for (lane = 0; lane < 7; lane = lane + 1)
        dut.ws.row_mem[row][lane] = fc1_weight_mem[7*row+lane];
    for (row = 0; row < 12; row = row + 1)
      for (lane = 0; lane < 7; lane = lane + 1)
        dut.ws.row_mem[896+row][lane] =
          ((7*row+lane) < 80) ? fc2_weight_mem[7*row+lane] : 16'h0000;

    errors = 0;
    done_count = 0;
    cycle_count = 0;

    // Synchronous reset, followed by one accepted start transaction.
    repeat (2) @(posedge clk);
    rst <= 1'b0;
    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;

    // This start occurs while the controller is busy and must be ignored.
    repeat (100) @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;

    // Wait for completion, with a guard against a deadlocked transaction.
    while (!done && cycle_count < 30000) begin
      @(posedge clk);
      cycle_count = cycle_count + 1;
    end
    if (!done) begin
      $display("ERROR: timeout waiting for done after %0d cycles", cycle_count);
      errors = errors + 1;
    end else begin
      done_count = done_count + 1;
      check_outputs();
      $display("PASS: done at cycle %0d, prediction=%0d", cycle_count, prediction);
    end

    // Outputs must remain stable after completion, and done must not repeat.
    repeat (3) begin
      @(posedge clk);
      if (done) done_count = done_count + 1;
      check_outputs();
    end
    if (done_count != 1) begin
      $display("ERROR: expected one done pulse, observed %0d", done_count);
      errors = errors + 1;
    end

    if (errors == 0)
      $display("TESTBENCH PASS");
    else
      $display("TESTBENCH FAIL: %0d error(s)", errors);
    $finish;
  end
endmodule
