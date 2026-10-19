`timescale 1ns/1ps

// Directed unit tests for the Section 9 items that the end-to-end testbench
// (06_2_programmer_tb.sv) does not cover directly:
//   1. FP16 multiply / add bit-exactness against numpy reference vectors,
//   2. weight_sram exact seven-edge latency, row-907 lane mask,
//   3. relu (negative zero normalisation, invalid input),
//   4. argmax tie-breaking (lowest index) and one-cycle done,
//   5. synchronous reset of the complete accelerator while busy.
//
// Run from the repository root:
//   iverilog -g2012 -s fc16_unit_tb -o /tmp/fc16_unit.out \
//     06_2_programmer.v tests/fc16_unit_tb.sv
//   vvp /tmp/fc16_unit.out
// Vector file: tests/fp16_vectors.mem, one line per vector, 16 hex digits
//   {a[15:0], b[15:0], a*b[15:0], a+b[15:0]} (reference = numpy float16).

module fc16_unit_tb;
  import fp16_pkg::*;

  localparam integer NVEC = 4096;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5 clk = ~clk;

  integer errors = 0;
  integer i, k;

  // ---------------------------------------------------------------- 1. FP16
  logic [63:0] vec [0:NVEC-1];
  logic [15:0] va, vb, vm, vs, got_m, got_s;
  integer mul_err, add_err;

  // ---------------------------------------------------------------- 2. SRAM
  logic        sram_req = 1'b0;
  logic [9:0]  sram_addr = 10'd0;
  logic        sram_valid;
  logic [15:0] sw0, sw1, sw2, sw3, sw4, sw5, sw6;
  logic [6:0]  sram_mask;

  weight_sram u_sram (
    .clk(clk), .rst(rst), .read_req(sram_req), .row_addr(sram_addr),
    .row_valid(sram_valid),
    .weight0_out(sw0), .weight1_out(sw1), .weight2_out(sw2), .weight3_out(sw3),
    .weight4_out(sw4), .weight5_out(sw5), .weight6_out(sw6),
    .lane_valid(sram_mask));

  // ---------------------------------------------------------------- 3. ReLU
  logic [15:0] relu_in, relu_out;
  logic        relu_vin, relu_vout;
  relu u_relu (.data_in(relu_in), .valid_in(relu_vin),
               .data_out(relu_out), .valid_out(relu_vout));

  // -------------------------------------------------------------- 4. argmax
  logic        am_start = 1'b0, am_lv = 1'b0, am_last = 1'b0;
  logic [15:0] am_in = 16'h0000;
  logic [3:0]  am_idx = 4'd0;
  logic        am_busy, am_done;
  logic [3:0]  am_pred;
  logic [15:0] l0, l1, l2, l3, l4, l5, l6, l7, l8, l9;
  logic [15:0] am_vals [0:9];
  integer done_pulses;

  argmax u_am (
    .clk(clk), .rst(rst), .start(am_start), .logit_valid(am_lv),
    .logit_in(am_in), .logit_index(am_idx), .logit_last(am_last),
    .busy(am_busy), .prediction(am_pred), .done(am_done),
    .logit0_out(l0), .logit1_out(l1), .logit2_out(l2), .logit3_out(l3),
    .logit4_out(l4), .logit5_out(l5), .logit6_out(l6), .logit7_out(l7),
    .logit8_out(l8), .logit9_out(l9));

  // ----------------------------------------------------- 5. whole accelerator
  logic        start = 1'b0;
  logic        top_done;
  logic [3:0]  top_pred;
  logic [15:0] t0, t1, t2, t3, t4, t5, t6, t7, t8, t9;
  integer r5, l5i;

  fc16_accelerator dut (
    .clk(clk), .rst(rst), .start(start), .done(top_done), .prediction(top_pred),
    .logit0(t0), .logit1(t1), .logit2(t2), .logit3(t3), .logit4(t4),
    .logit5(t5), .logit6(t6), .logit7(t7), .logit8(t8), .logit9(t9));

  task automatic expect_true(input bit cond, input string what);
    begin
      if (!cond) begin
        $display("ERROR: %s", what);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    // ------------------------------------------------------------- reset
    repeat (3) @(posedge clk);
    #1 rst = 1'b0;

    // --------------------------------------------- 1. arithmetic vectors
    $readmemh("tests/fp16_vectors.mem", vec);
    mul_err = 0; add_err = 0;
    for (i = 0; i < NVEC; i = i + 1) begin
      va = vec[i][63:48]; vb = vec[i][47:32]; vm = vec[i][31:16]; vs = vec[i][15:0];
      got_m = fp16_mul(va, vb);
      got_s = fp16_add(va, vb);
      if (got_m !== vm) begin
        mul_err = mul_err + 1;
        if (mul_err <= 10) $display("MUL mismatch a=%h b=%h rtl=%h ref=%h", va, vb, got_m, vm);
      end
      if (got_s !== vs) begin
        add_err = add_err + 1;
        if (add_err <= 10) $display("ADD mismatch a=%h b=%h rtl=%h ref=%h", va, vb, got_s, vs);
      end
    end
    $display("FP16 vectors: %0d checked, mul mismatches=%0d, add mismatches=%0d", NVEC, mul_err, add_err);
    errors = errors + mul_err + add_err;

    // --------------------------------------- 2. SRAM latency and lane mask
    for (k = 0; k < 7; k = k + 1) begin
      u_sram.row_mem[5][k]   = 16'h1000 + k;
      u_sram.row_mem[907][k] = 16'h2000 + k;
    end
    @(negedge clk);
    sram_req = 1'b1; sram_addr = 10'd5;
    @(posedge clk);                       // edge E0: request accepted
    @(negedge clk);
    sram_req = 1'b0;
    for (k = 1; k <= 7; k = k + 1) begin
      @(posedge clk); #1;
      if (k < 7) expect_true(sram_valid === 1'b0, $sformatf("row_valid high %0d edge(s) after request (must be 7)", k));
      else       expect_true(sram_valid === 1'b1, "row_valid not high exactly 7 edges after request");
    end
    expect_true(sw0 === 16'h1000 && sw3 === 16'h1003 && sw6 === 16'h1006, "row 5 data/lane order wrong");
    expect_true(sram_mask === 7'b1111111, "row 5 lane mask must be 1111111");
    @(posedge clk); #1;
    expect_true(sram_valid === 1'b0, "row_valid must be a single-cycle pulse");

    @(negedge clk);
    sram_req = 1'b1; sram_addr = 10'd907;
    @(posedge clk);
    @(negedge clk);
    sram_req = 1'b0;
    repeat (7) @(posedge clk);
    #1;
    expect_true(sram_valid === 1'b1, "row 907 not valid after 7 edges");
    expect_true(sram_mask === 7'b0000111, "row 907 lane mask must be 0000111 (3 valid weights)");

    // ------------------------------------------------------------ 3. ReLU
    relu_vin = 1'b1;
    relu_in = 16'h8000; #1 expect_true(relu_out === 16'h0000, "relu(-0) must be +0");
    relu_in = 16'hc000; #1 expect_true(relu_out === 16'h0000, "relu(-2) must be +0");
    relu_in = 16'h4000; #1 expect_true(relu_out === 16'h4000, "relu(+2) must pass through");
    relu_in = 16'h0000; #1 expect_true(relu_out === 16'h0000, "relu(+0) must stay +0");
    relu_vin = 1'b0;
    relu_in = 16'h4000; #1 expect_true(relu_vout === 1'b0, "relu valid_out must follow valid_in");

    // ----------------------------------------------- 4. argmax tie-breaking
    // logits 3 and 5 share the maximum (8.0); the lowest index (3) must win.
    am_vals[0] = 16'h3c00; am_vals[1] = 16'h4000; am_vals[2] = 16'h4400;
    am_vals[3] = 16'h4800; am_vals[4] = 16'hc000; am_vals[5] = 16'h4800;
    am_vals[6] = 16'h4400; am_vals[7] = 16'h0000; am_vals[8] = 16'h8000;
    am_vals[9] = 16'hbc00;
    @(negedge clk); am_start = 1'b1;
    @(posedge clk);
    @(negedge clk); am_start = 1'b0;
    done_pulses = 0;
    for (k = 0; k < 10; k = k + 1) begin
      am_lv = 1'b1; am_in = am_vals[k]; am_idx = k[3:0]; am_last = (k == 9);
      @(posedge clk); #1;
      if (am_done) done_pulses = done_pulses + 1;
      @(negedge clk);
    end
    am_lv = 1'b0; am_last = 1'b0;
    expect_true(done_pulses == 1, "argmax done must pulse exactly once, on the cycle after the last logit");
    expect_true(am_pred === 4'd3, $sformatf("argmax tie: prediction=%0d expected 3", am_pred));
    expect_true(l3 === 16'h4800 && l5 === 16'h4800 && l9 === 16'hbc00, "argmax logit storage wrong");
    repeat (2) begin
      @(posedge clk); #1;
      expect_true(am_done === 1'b0, "argmax done repeated");
      expect_true(am_pred === 4'd3, "argmax prediction not stable after done");
    end

    // ---------------------------------- 5. reset of the complete accelerator
    // Zero all memories so no X values enter the data path, start a transaction,
    // reset in the middle of it and check that every output returns to zero and
    // the controller returns to IDLE.
    for (r5 = 0; r5 < 784; r5 = r5 + 1) dut.im.pixel_mem[r5] = 16'h3c00;
    for (r5 = 0; r5 < 18; r5 = r5 + 1)  dut.bm.bias_mem[r5] = 16'h0000;
    for (r5 = 0; r5 < 908; r5 = r5 + 1)
      for (l5i = 0; l5i < 7; l5i = l5i + 1) dut.ws.row_mem[r5][l5i] = 16'h3c00;
    @(negedge clk); rst = 1'b1;
    repeat (2) @(posedge clk);
    @(negedge clk); rst = 1'b0;
    @(negedge clk); start = 1'b1;
    @(posedge clk);
    @(negedge clk); start = 1'b0;
    repeat (300) @(posedge clk);
    expect_true(dut.cf.state !== 5'd0, "controller should be busy 300 cycles after start");
    @(negedge clk); rst = 1'b1;
    repeat (2) @(posedge clk);
    #1;
    expect_true(dut.cf.state === 5'd0, "controller not in IDLE after reset");
    expect_true(top_done === 1'b0 && top_pred === 4'd0, "done/prediction not cleared by reset");
    expect_true(t0 === 16'h0 && t1 === 16'h0 && t2 === 16'h0 && t3 === 16'h0 && t4 === 16'h0 &&
                t5 === 16'h0 && t6 === 16'h0 && t7 === 16'h0 && t8 === 16'h0 && t9 === 16'h0,
                "logits not cleared by reset");
    @(negedge clk); rst = 1'b0;
    repeat (5) @(posedge clk);
    expect_true(dut.cf.state === 5'd0 && top_done === 1'b0, "accelerator must stay idle without start");

    if (errors == 0) $display("UNIT TESTBENCH PASS");
    else             $display("UNIT TESTBENCH FAIL: %0d error(s)", errors);
    $finish;
  end

  initial begin
    #50000000;
    $display("UNIT TESTBENCH TIMEOUT");
    $finish;
  end
endmodule
