// Section 6 Programmer handoff.
// Approved interface amendment: controller_fsm adds exactly bias_valid,
// layer2_group_valid, buffer_full, buffer_consume_valid, and
// buffer_consume_ready.  These are connected to their real producers in the
// fc16_accelerator wrapper.  No functional memory initialization is present.

package fp16_pkg;
  localparam integer FP16_EXTRA = 13;

  function automatic bit fp16_is_nan(input logic [15:0] x);
    fp16_is_nan = (&x[14:10]) && (|x[9:0]);
  endfunction

  function automatic bit fp16_is_inf(input logic [15:0] x);
    fp16_is_inf = (&x[14:10]) && !(|x[9:0]);
  endfunction

  // STEP-034: binary16 decode/classification and deterministic special-value policy.
  // STEP-035: rounded multiply normalization, subnormal, overflow, zero, infinity, and NaN.
  // STEP-036: rounded add alignment, cancellation, normalization, subnormal, overflow, and NaN.
  // STEP-037: product-before-add arithmetic boundary used by the golden-model check.

  function automatic longint unsigned rshift_sticky(
      input longint unsigned value, input integer sh);
    longint unsigned mask;
    begin
      if (sh <= 0)
        rshift_sticky = value;
      else if (sh >= 63)
        rshift_sticky = (value != 0);
      else begin
        mask = (64'h1 << sh) - 1;
        rshift_sticky = (value >> sh) | ((value & mask) != 0);
      end
    end
  endfunction

  function automatic [15:0] fp16_mul(
      input logic [15:0] a, input logic [15:0] b);
    integer sa, sb, ea, eb, expv, shiftv, j;
    integer ma, mb;
    longint unsigned prod, sig, discarded, work;
    longint unsigned main_sig;
    integer guard_bit, round_bit, sticky_bit;
    integer carry;
    logic signv;
    begin
      signv = a[15] ^ b[15];
      if (fp16_is_nan(a) || fp16_is_nan(b)) begin
        fp16_mul = 16'h7e00;
      end else if ((fp16_is_inf(a) && (b[14:0] == 0)) ||
                   (fp16_is_inf(b) && (a[14:0] == 0))) begin
        fp16_mul = 16'h7e00;
      end else if (fp16_is_inf(a) || fp16_is_inf(b)) begin
        fp16_mul = {signv,5'h1f,10'h000};
      end else if ((a[14:0] == 0) || (b[14:0] == 0)) begin
        fp16_mul = {signv,15'h0000};
      end else begin
        if (a[14:10] == 0) begin
          ma = a[9:0]; ea = -14;
          for (j=0; j<13 && ma < 1024; j=j+1) begin ma = ma << 1; ea = ea - 1; end
        end else begin
          ma = 1024 + a[9:0]; ea = integer'(a[14:10]) - 15;
        end
        if (b[14:10] == 0) begin
          mb = b[9:0]; eb = -14;
          for (j=0; j<13 && mb < 1024; j=j+1) begin mb = mb << 1; eb = eb - 1; end
        end else begin
          mb = 1024 + b[9:0]; eb = integer'(b[14:10]) - 15;
        end
        expv = ea + eb;
        prod = ma * mb;
        if (prod >= (64'h1 << 21)) begin
          sig = prod << 2;
          discarded = 0;
          expv = expv + 1;
        end else begin
          sig = prod << 3;
          discarded = 0;
        end
        work = sig;
        if (discarded != 0) work[0] = 1'b1;
        if (expv < -14) begin
          // Subnormal result: shift the UNROUNDED significand down to the
          // binary16 -14 boundary and round exactly once (avoids double
          // rounding and the exponent/significand skew of the old flow).
          shiftv = -14 - expv;
          work = rshift_sticky(work, shiftv);
          main_sig = work >> FP16_EXTRA;
          guard_bit = (work >> (FP16_EXTRA-1)) & 1;
          round_bit = (work >> (FP16_EXTRA-2)) & 1;
          sticky_bit = ((work & ((64'h1 << (FP16_EXTRA-2))-1)) != 0);
          if (guard_bit && (round_bit || sticky_bit || main_sig[0]))
            main_sig = main_sig + 1;
          if (main_sig >= 1024)
            fp16_mul = {signv,5'h01,10'h000};
          else
            fp16_mul = {signv,5'h00,main_sig[9:0]};
        end else begin
          main_sig = work >> FP16_EXTRA;
          guard_bit = (work >> (FP16_EXTRA-1)) & 1;
          round_bit = (work >> (FP16_EXTRA-2)) & 1;
          sticky_bit = ((work & ((64'h1 << (FP16_EXTRA-2))-1)) != 0);
          if (guard_bit && (round_bit || sticky_bit || main_sig[0]))
            main_sig = main_sig + 1;
          if (main_sig >= 2048) begin
            main_sig = main_sig >> 1;
            expv = expv + 1;
          end
          if (expv > 15)
            fp16_mul = {signv,5'h1f,10'h000};
          else
            fp16_mul = {signv,5'(expv+15),10'(main_sig-1024)};
        end
      end
    end
  endfunction

  function automatic [15:0] fp16_add(
      input logic [15:0] a, input logic [15:0] b);
    integer ea, eb, expv, delta, shiftv, j;
    integer ma, mb, sub_sum, sub_diff;
    logic sa, sb, signv;
    longint unsigned siga, sigb, sigsum, work;
    longint unsigned main_sig;
    integer guard_bit, round_bit, sticky_bit;
    begin
      if (fp16_is_nan(a) || fp16_is_nan(b)) begin
        fp16_add = 16'h7e00;
      end else if (fp16_is_inf(a) && fp16_is_inf(b) && (a[15] != b[15])) begin
        fp16_add = 16'h7e00;
      end else if (fp16_is_inf(a)) begin
        fp16_add = a;
      end else if (fp16_is_inf(b)) begin
        fp16_add = b;
      end else if ((a[14:0] == 0) && (b[14:0] == 0)) begin
        // IEEE-754 round-to-nearest: (-0)+(-0) = -0, every other zero sum = +0.
        fp16_add = {a[15] & b[15], 15'h0000};
      end else if (a[14:0] == 0) begin
        fp16_add = b;
      end else if (b[14:0] == 0) begin
        fp16_add = a;
      end else if ((a[14:10] == 0) && (b[14:10] == 0)) begin
        // Exact fixed-point path for two subnormal operands.  Their encoded
        // fractions share the same 2^-24 scale, so addition/subtraction can
        // be completed without normalizing away the low bits.
        if (a[15] == b[15]) begin
          sub_sum = a[9:0] + b[9:0];
          if (sub_sum >= 1024)
            fp16_add = {a[15],5'h01,10'(sub_sum-1024)};
          else
            fp16_add = {a[15],5'h00,10'(sub_sum)};
        end else if (a[9:0] > b[9:0]) begin
          sub_diff = a[9:0] - b[9:0];
          fp16_add = {a[15],5'h00,10'(sub_diff)};
        end else if (b[9:0] > a[9:0]) begin
          sub_diff = b[9:0] - a[9:0];
          fp16_add = {b[15],5'h00,10'(sub_diff)};
        end else begin
          fp16_add = 16'h0000;
        end
      end else begin
        sa = a[15]; sb = b[15];
        if (a[14:10] == 0) begin
          ma = a[9:0]; ea = -14;
          for (j=0; j<13 && (ma != 0) && (ma < 1024); j=j+1) begin ma = ma << 1; ea = ea - 1; end
        end else begin
          ma = 1024 + a[9:0]; ea = integer'(a[14:10]) - 15;
        end
        if (b[14:10] == 0) begin
          mb = b[9:0]; eb = -14;
          for (j=0; j<13 && (mb != 0) && (mb < 1024); j=j+1) begin mb = mb << 1; eb = eb - 1; end
        end else begin
          mb = 1024 + b[9:0]; eb = integer'(b[14:10]) - 15;
        end
        siga = ma << FP16_EXTRA;
        sigb = mb << FP16_EXTRA;
        if (ea > eb) begin
          expv = ea; delta = ea-eb; sigb = rshift_sticky(sigb,delta);
        end else begin
          expv = eb; delta = eb-ea; siga = rshift_sticky(siga,delta);
        end
        if (sa == sb) begin
          signv = sa;
          sigsum = siga + sigb;
          if (sigsum >= (64'd2048 << FP16_EXTRA)) begin
            sigsum = rshift_sticky(sigsum,1);
            expv = expv + 1;
          end
        end else begin
          if ((ea > eb) || ((ea == eb) && (ma >= mb))) begin
            signv = sa; sigsum = siga - sigb;
          end else begin
            signv = sb; sigsum = sigb - siga;
          end
          if (sigsum == 0) begin
            fp16_add = 16'h0000;
          end else begin
            for (j=0; j<40 && (sigsum < (64'd1024 << FP16_EXTRA)) && (expv > -40); j=j+1) begin
              sigsum = sigsum << 1; expv = expv - 1;
            end
            work = sigsum;
            if (expv < -14) begin
              shiftv = -14 - expv;
              work = rshift_sticky(work, shiftv);
              main_sig = work >> FP16_EXTRA;
              guard_bit = (work >> (FP16_EXTRA-1)) & 1;
              round_bit = (work >> (FP16_EXTRA-2)) & 1;
              sticky_bit = ((work & ((64'h1 << (FP16_EXTRA-2))-1)) != 0);
              if (guard_bit && (round_bit || sticky_bit || main_sig[0])) main_sig = main_sig+1;
              if (main_sig >= 1024) fp16_add = {signv,5'h01,10'h000};
              else fp16_add = {signv,5'h00,main_sig[9:0]};
            end else begin
              main_sig = work >> FP16_EXTRA;
              guard_bit = (work >> (FP16_EXTRA-1)) & 1;
              round_bit = (work >> (FP16_EXTRA-2)) & 1;
              sticky_bit = ((work & ((64'h1 << (FP16_EXTRA-2))-1)) != 0);
              if (guard_bit && (round_bit || sticky_bit || main_sig[0])) main_sig = main_sig + 1;
              if (main_sig >= 2048) begin main_sig = main_sig >> 1; expv = expv+1; end
              if (expv > 15) fp16_add = {signv,5'h1f,10'h000};
              else fp16_add = {signv,5'(expv+15),10'(main_sig-1024)};
            end
          end
        end
        if ((sa == sb) && (sigsum != 0)) begin
          work = sigsum;
          if (expv < -14) begin
            shiftv = -14 - expv; work = rshift_sticky(work, shiftv);
            main_sig = work >> FP16_EXTRA;
            guard_bit = (work >> (FP16_EXTRA-1)) & 1; round_bit = (work >> (FP16_EXTRA-2)) & 1;
            sticky_bit = ((work & ((64'h1 << (FP16_EXTRA-2))-1)) != 0);
            if (guard_bit && (round_bit || sticky_bit || main_sig[0])) main_sig = main_sig+1;
            if (main_sig >= 1024) fp16_add = {signv,5'h01,10'h000};
            else fp16_add = {signv,5'h00,main_sig[9:0]};
          end else begin
            main_sig = work >> FP16_EXTRA;
            guard_bit = (work >> (FP16_EXTRA-1)) & 1; round_bit = (work >> (FP16_EXTRA-2)) & 1;
            sticky_bit = ((work & ((64'h1 << (FP16_EXTRA-2))-1)) != 0);
            if (guard_bit && (round_bit || sticky_bit || main_sig[0])) main_sig = main_sig+1;
            if (main_sig >= 2048) begin main_sig = main_sig >> 1; expv = expv+1; end
            if (expv > 15) fp16_add = {signv,5'h1f,10'h000};
            else fp16_add = {signv,5'(expv+15),10'(main_sig-1024)};
          end
        end
      end
    end
  endfunction

  function automatic bit fp16_gt(input logic [15:0] a, input logic [15:0] b);
    begin
      if (fp16_is_nan(a) || fp16_is_nan(b)) fp16_gt = 1'b0;
      else if (a[15] != b[15]) fp16_gt = !a[15] && b[15];
      else if (!a[15]) fp16_gt = a[14:0] > b[14:0];
      else fp16_gt = a[14:0] < b[14:0];
    end
  endfunction
endpackage

module input_memory (
    input logic clk, input logic rst, input logic read_req,
    input logic [6:0] group_addr, output logic group_valid,
    output logic [15:0] input0_out,
    output logic [15:0] input1_out,
    output logic [15:0] input2_out,
    output logic [15:0] input3_out,
    output logic [15:0] input4_out,
    output logic [15:0] input5_out,
    output logic [15:0] input6_out,
    output logic [6:0] lane_valid);
  logic [15:0] pixel_mem [0:783];
  logic pending_valid; logic [6:0] pending_addr;
  // STEP-006: 784-entry storage and one-cycle response registers.
  // STEP-007: legal ordered group read.
  // STEP-008: reset and invalid suppression.
  always_ff @(posedge clk) begin
    if (rst) begin
      pending_valid<=0; pending_addr<=0; group_valid<=0; lane_valid<=0;
      input0_out<=0; input1_out<=0; input2_out<=0; input3_out<=0;
      input4_out<=0; input5_out<=0; input6_out<=0;
    end else begin
      group_valid<=0; lane_valid<=0;
      if (pending_valid) begin
        group_valid<=1; lane_valid<=7'b1111111;
        input0_out<=pixel_mem[7*pending_addr+0]; input1_out<=pixel_mem[7*pending_addr+1];
        input2_out<=pixel_mem[7*pending_addr+2]; input3_out<=pixel_mem[7*pending_addr+3];
        input4_out<=pixel_mem[7*pending_addr+4]; input5_out<=pixel_mem[7*pending_addr+5];
        input6_out<=pixel_mem[7*pending_addr+6];
      end else begin
        input0_out<=0; input1_out<=0; input2_out<=0; input3_out<=0;
        input4_out<=0; input5_out<=0; input6_out<=0;
      end
      pending_valid <= read_req && (group_addr < 112);
      if (read_req && (group_addr < 112)) pending_addr <= group_addr;
    end
  end
endmodule

module bias_memory (
    input logic clk, input logic rst, input logic read_req,
    input logic [4:0] bias_addr, output logic bias_valid,
    output logic [15:0] bias_out);
  logic [15:0] bias_mem [0:17]; logic pending_valid; logic [4:0] pending_addr;
  // STEP-013: 18-entry storage and response registers.
  // STEP-014: legal one-cycle ordered response.
  // STEP-015: reset and bounds checking.
  always_ff @(posedge clk) begin
    if (rst) begin pending_valid<=0; pending_addr<=0; bias_valid<=0; bias_out<=0; end
    else begin
      bias_valid<=0;
      if (pending_valid) begin bias_valid<=1; bias_out<=bias_mem[pending_addr]; end
      else bias_out<=0;
      pending_valid<=read_req && (bias_addr<18);
      if (read_req && (bias_addr<18)) pending_addr<=bias_addr;
    end
  end
endmodule

module weight_sram (
    input logic clk, input logic rst, input logic read_req,
    input logic [9:0] row_addr, output logic row_valid,
    output logic [15:0] weight0_out, output logic [15:0] weight1_out,
    output logic [15:0] weight2_out, output logic [15:0] weight3_out,
    output logic [15:0] weight4_out, output logic [15:0] weight5_out,
    output logic [15:0] weight6_out, output logic [6:0] lane_valid);
  logic [15:0] row_mem [0:907][0:6];
  logic pipe_valid [0:6]; logic [9:0] pipe_addr [0:6]; integer k;
  // STEP-009: seven-stage request pipeline and reset.
  // STEP-010: ordered request shifting.
  // STEP-011: seven-edge response and row-907 mask.
  // STEP-012: address bounds.
  always_ff @(posedge clk) begin
    if (rst) begin
      row_valid<=0; lane_valid<=0; weight0_out<=0; weight1_out<=0;
      weight2_out<=0; weight3_out<=0; weight4_out<=0; weight5_out<=0; weight6_out<=0;
      for (k=0;k<7;k=k+1) begin pipe_valid[k]<=0; pipe_addr[k]<=0; end
    end else begin
      row_valid<=pipe_valid[6]; lane_valid<=0;
      weight0_out<=0; weight1_out<=0; weight2_out<=0; weight3_out<=0;
      weight4_out<=0; weight5_out<=0; weight6_out<=0;
      if (pipe_valid[6]) begin
        row_valid<=1; lane_valid <= (pipe_addr[6]==907) ? 7'b0000111 : 7'b1111111;
        weight0_out<=row_mem[pipe_addr[6]][0]; weight1_out<=row_mem[pipe_addr[6]][1];
        weight2_out<=row_mem[pipe_addr[6]][2]; weight3_out<=row_mem[pipe_addr[6]][3];
        weight4_out<=row_mem[pipe_addr[6]][4]; weight5_out<=row_mem[pipe_addr[6]][5];
        weight6_out<=row_mem[pipe_addr[6]][6];
      end
      for (k=6;k>0;k=k-1) begin pipe_valid[k]<=pipe_valid[k-1]; pipe_addr[k]<=pipe_addr[k-1]; end
      pipe_valid[0] <= read_req && (row_addr<908);
      if (read_req && (row_addr<908)) pipe_addr[0]<=row_addr;
    end
  end
endmodule

module relu(input logic [15:0] data_in, input logic valid_in,
             output logic [15:0] data_out, output logic valid_out);
  // STEP-029: stateless combinational defaults and valid propagation.
  // STEP-030: sign-bit ReLU and negative-zero normalization.
  always @* begin
    valid_out=valid_in; data_out=16'h0000;
    if (valid_in && !data_in[15]) data_out=data_in;
  end
endmodule

module fp16_multiplier (
    input logic clk, input logic rst, input logic start_group,
    input logic [15:0] input0,input1,input2,input3,input4,input5,input6,
    input logic [15:0] weight0,weight1,weight2,weight3,weight4,weight5,weight6,
    input logic [6:0] lane_valid, output logic busy, output logic product_valid,
    output logic [15:0] product_out, output logic [2:0] product_index,
    output logic group_done);
  import fp16_pkg::*;
  logic [15:0] in_r[0:6], wt_r[0:6]; logic [6:0] mask_r; logic [2:0] lane_r; integer i;
  // STEP-016: operand capture and lane counter.
  // STEP-018: reset and lane-6 completion.
  always_ff @(posedge clk) begin
    if (rst) begin busy<=0; lane_r<=0; mask_r<=0; for(i=0;i<7;i=i+1) begin in_r[i]<=0; wt_r[i]<=0; end end
    else begin
      if (!busy && start_group) begin
        in_r[0]<=input0; in_r[1]<=input1; in_r[2]<=input2; in_r[3]<=input3; in_r[4]<=input4; in_r[5]<=input5; in_r[6]<=input6;
        wt_r[0]<=weight0; wt_r[1]<=weight1; wt_r[2]<=weight2; wt_r[3]<=weight3; wt_r[4]<=weight4; wt_r[5]<=weight5; wt_r[6]<=weight6;
        mask_r<=lane_valid; lane_r<=0; busy<=1;
      end else if (busy) begin
        if (lane_r==6) busy<=0; else lane_r<=lane_r+1'b1;
      end
    end
  end
  // STEP-017: one combinational product boundary per lane; the buffer samples
  // this stream on the following rising edge.
  always @* begin
    product_index=lane_r;
    product_valid=busy && mask_r[lane_r];
    product_out=(busy && mask_r[lane_r]) ? fp16_mul(wt_r[lane_r],in_r[lane_r]) : 16'h0000;
    group_done=busy && (lane_r==6);
  end
endmodule

module fp16_accumulator (
    input logic clk, input logic rst, input logic neuron_start,
    input logic [15:0] bias_in, input logic product_valid,
    input logic [15:0] product_in, input logic group_last,
    input logic neuron_last, output logic product_ready, output logic busy,
    output logic [15:0] result_out, output logic result_valid);
  import fp16_pkg::*;
  logic [15:0] acc_r; logic [15:0] add_value;
  // STEP-023: bias-first state.
  // STEP-024: one rounded add per accepted product.
  always @* begin product_ready=busy; add_value=fp16_add(acc_r,product_in); end
  // STEP-025: final-product inclusion, result pulse, and reset behavior.
  always_ff @(posedge clk) begin
    if (rst) begin acc_r<=0; busy<=0; result_out<=0; result_valid<=0; end
    else begin
      result_valid<=0;
      if (!busy && neuron_start) begin acc_r<=bias_in; busy<=1; end
      else if (busy && product_valid) begin
        acc_r<=add_value;
        if (neuron_last) begin result_out<=add_value; result_valid<=1; busy<=0; end
      end
    end
  end
endmodule

module layer2_register_file (
    input logic clk,input logic rst,input logic hidden_write_en,
    input logic [2:0] hidden_write_addr,input logic [15:0] hidden_write_data,
    input logic group_read_req,input logic group_addr,output logic group_valid,
    output logic [15:0] input0_out,input1_out,input2_out,input3_out,input4_out,input5_out,input6_out,
    output logic [6:0] lane_valid);
  logic [15:0] regs[0:9]; logic pending; logic pending_addr; integer i;
  // STEP-026: hidden storage reset.
  // STEP-027: hidden writes and reserved-address rejection.
  // STEP-028: one-cycle two-group response.
  always_ff @(posedge clk) begin
    if (rst) begin pending<=0; pending_addr<=0; group_valid<=0; lane_valid<=0; input0_out<=0; input1_out<=0; input2_out<=0; input3_out<=0; input4_out<=0; input5_out<=0; input6_out<=0; for(i=0;i<10;i=i+1) regs[i]<=0; end
    else begin
      group_valid<=0; lane_valid<=0;
      if (hidden_write_en && (hidden_write_addr<8)) regs[hidden_write_addr]<=hidden_write_data;
      if (pending) begin
        group_valid<=1;
        if (!pending_addr) begin
          lane_valid<=7'b1111111; input0_out<=regs[0]; input1_out<=regs[1]; input2_out<=regs[2]; input3_out<=regs[3]; input4_out<=regs[4]; input5_out<=regs[5]; input6_out<=regs[6];
        end else begin
          lane_valid<=7'b0000001; input0_out<=regs[7]; input1_out<=0; input2_out<=0; input3_out<=0; input4_out<=0; input5_out<=0; input6_out<=0;
        end
      end else begin input0_out<=0; input1_out<=0; input2_out<=0; input3_out<=0; input4_out<=0; input5_out<=0; input6_out<=0; end
      pending<=group_read_req; if (group_read_req) pending_addr<=group_addr;
    end
  end
endmodule

module ping_pong_buffer (
    input logic clk,input logic rst,input logic product_valid,
    input logic [15:0] product_in,input logic product_last,output logic write_ready,
    input logic consume_start,input logic consume_ready,output logic consume_valid,
    output logic [15:0] consume_data,output logic consume_last,
    output logic buffer_full,output logic buffer_empty);
  typedef enum logic [1:0] {EMPTY,WRITING,FULL,READING} half_state_t;
  half_state_t hs[0:1]; logic [15:0] mem[0:1][0:6]; logic write_sel,read_sel;
  logic [2:0] wpos[0:1],rpos[0:1],vcount[0:1]; logic [7:0] age[0:1]; logic [7:0] age_ctr; integer i;
  logic oldest; logic any_full,any_reading;
  // STEP-019: half state, pointers, ages, reset, and status selection.
  // STEP-022: same-half reuse exclusion and status stability.
  always @* begin
    write_ready=((hs[write_sel]==EMPTY)||(hs[write_sel]==WRITING)) && (vcount[write_sel]<7);
    any_full=(hs[0]==FULL)||(hs[1]==FULL); any_reading=(hs[0]==READING)||(hs[1]==READING);
    buffer_full=any_full; buffer_empty=!(any_full||any_reading);
    if ((hs[0]==FULL)&&(hs[1]==FULL)) oldest=(age[0]<=age[1])?1'b0:1'b1;
    else if (hs[0]==FULL) oldest=0; else oldest=1;
    consume_valid=(hs[read_sel]==READING)&&(rpos[read_sel]<vcount[read_sel]);
    consume_data=consume_valid ? mem[read_sel][rpos[read_sel]] : 16'h0000;
    consume_last=consume_valid && (rpos[read_sel]==vcount[read_sel]-1'b1);
  end
  // STEP-020: ordered writes, partial closure, and valid counts.
  // STEP-021: oldest-full reads and accepted final removal.
  always_ff @(posedge clk) begin
    if (rst) begin
      write_sel<=0; read_sel<=0; age_ctr<=0;
      for(i=0;i<2;i=i+1) begin hs[i]<=EMPTY; wpos[i]<=0; rpos[i]<=0; vcount[i]<=0; age[i]<=0; end
    end else begin
      if (product_valid && write_ready) begin
        mem[write_sel][wpos[write_sel]]<=product_in;
        if (hs[write_sel]==EMPTY) hs[write_sel]<=WRITING;
        wpos[write_sel]<=wpos[write_sel]+1'b1; vcount[write_sel]<=vcount[write_sel]+1'b1;
      end
      if (product_last && write_ready) begin
        hs[write_sel]<=FULL; age[write_sel]<=age_ctr; age_ctr<=age_ctr+1'b1;
        if (hs[1-write_sel]==EMPTY) write_sel<=1-write_sel;
      end
      if (consume_start && buffer_full) begin
        read_sel<=oldest; hs[oldest]<=READING; rpos[oldest]<=0;
      end
      if (consume_valid && consume_ready) begin
        if (consume_last) begin hs[read_sel]<=EMPTY; rpos[read_sel]<=0; wpos[read_sel]<=0; vcount[read_sel]<=0; if (write_sel!=read_sel) write_sel<=read_sel; end
        else rpos[read_sel]<=rpos[read_sel]+1'b1;
      end
    end
  end
endmodule

module argmax (
    input logic clk,input logic rst,input logic start,input logic logit_valid,
    input logic [15:0] logit_in,input logic [3:0] logit_index,input logic logit_last,
    output logic busy,output logic [3:0] prediction,output logic done,
    output logic [15:0] logit0_out,logit1_out,logit2_out,logit3_out,logit4_out,
    output logic [15:0] logit5_out,logit6_out,logit7_out,logit8_out,logit9_out);
  import fp16_pkg::*;
  logic [15:0] best_logit; logic [3:0] best_index; logic seen;
  logic cmp_gt; logic [15:0] best_next; logic [3:0] index_next; integer i;
  // STEP-031: collection and storage clearing.
  // STEP-032: strict-greater tie-low comparison.
  // STEP-033: final-sample inclusion and done pulse.
  always @* begin
    cmp_gt=fp16_gt(logit_in,best_logit);
    if (!seen) begin best_next=logit_in; index_next=logit_index; end
    else if (cmp_gt) begin best_next=logit_in; index_next=logit_index; end
    else begin best_next=best_logit; index_next=best_index; end
  end
  always_ff @(posedge clk) begin
    if (rst) begin busy<=0; prediction<=0; done<=0; best_logit<=0; best_index<=0; seen<=0; logit0_out<=0; logit1_out<=0; logit2_out<=0; logit3_out<=0; logit4_out<=0; logit5_out<=0; logit6_out<=0; logit7_out<=0; logit8_out<=0; logit9_out<=0; end
    else begin
      done<=0;
      if (!busy && start) begin busy<=1; seen<=0; best_logit<=0; best_index<=0; logit0_out<=0; logit1_out<=0; logit2_out<=0; logit3_out<=0; logit4_out<=0; logit5_out<=0; logit6_out<=0; logit7_out<=0; logit8_out<=0; logit9_out<=0; end
      else if (busy && logit_valid && (logit_index<10)) begin
        case(logit_index)
          0:logit0_out<=logit_in; 1:logit1_out<=logit_in; 2:logit2_out<=logit_in; 3:logit3_out<=logit_in; 4:logit4_out<=logit_in;
          5:logit5_out<=logit_in; 6:logit6_out<=logit_in; 7:logit7_out<=logit_in; 8:logit8_out<=logit_in; 9:logit9_out<=logit_in;
          default:;
        endcase
        best_logit<=best_next; best_index<=index_next; seen<=1;
        if (logit_last) begin prediction<=index_next; done<=1; busy<=0; end
      end
    end
  end
endmodule

module controller_fsm (
    input logic clk,input logic rst,input logic start,input logic input_group_valid,
    input logic bias_valid,input logic layer2_group_valid,input logic weight_row_valid,
    input logic [15:0] weight0_in,weight1_in,weight2_in,weight3_in,weight4_in,weight5_in,weight6_in,
    input logic [6:0] weight_lane_valid,input logic multiplier_busy,input logic buffer_write_ready,
    input logic buffer_full,input logic buffer_consume_valid,input logic buffer_consume_ready,
    input logic buffer_consume_last,input logic accumulator_result_valid,input logic argmax_done,
    output logic input_read_req,output logic [6:0] input_group_addr,output logic weight_read_req,
    output logic [9:0] weight_row_addr,output logic bias_read_req,output logic [4:0] bias_addr,
    output logic multiplier_start,output logic [15:0] selected_weight0,selected_weight1,selected_weight2,selected_weight3,selected_weight4,selected_weight5,selected_weight6,
    output logic [6:0] selected_weight_valid,output logic buffer_consume_start,output logic accumulator_start,
    output logic accumulator_neuron_last,output logic hidden_write_en,output logic [2:0] hidden_write_addr,
    output logic layer2_group_read_req,output logic layer2_group_addr,output logic argmax_start,
    output logic argmax_logit_valid,output logic [3:0] argmax_logit_index,output logic argmax_logit_last,
    output logic busy,output logic done);
  typedef enum logic [4:0] {IDLE,FC1_BIAS_REQ,FC1_BIAS_WAIT,FC1_INPUT_WEIGHT_REQ,FC1_OPERAND_WAIT,FC1_MAC_START,FC1_GROUP_WAIT,FC1_CONSUME_WAIT,FC1_RESULT_WAIT,FC1_RELU_STORE,FC2_ARGMAX_START,FC2_BIAS_REQ,FC2_BIAS_WAIT,FC2_GROUP_PREP,FC2_GATHER_WAIT,FC2_OPERAND_WAIT,FC2_MAC_START,FC2_GROUP_WAIT,FC2_CONSUME_WAIT,FC2_RESULT_WAIT,FC2_LOGIT_SEND,COMPLETE_WAIT} state_t;
  state_t state,next_state; logic [2:0] nidx; logic [6:0] gidx; logic [3:0] didx; logic fgroup;
  logic [15:0] sel_r[0:6]; logic in_seen,wt_seen,hidden_seen;
  logic [6:0] gather_mask,need_mask; logic [9:0] gather_row1,gather_row2,gather_row_current; logic need_second,second_requested; integer i,c;
  logic [9:0] fc2_first_row_c,fc2_second_row_c,fc2_lane_row_c[0:6]; logic [2:0] fc2_lane_num_c[0:6];
  // STEP-001: bounded sequencer, response flags, and FC2 staging.
  // STEP-002: FC1 bias and request sequencing.
  // STEP-003: FC1 operand, group, result, and hidden sequencing.
  // STEP-004: FC2 bias and physical-row gathering.
  // STEP-005: FC2 logits, completion, and illegal-state recovery.
  always_ff @(posedge clk) begin
    if (rst) begin
      state<=IDLE; nidx<=0; gidx<=0; didx<=0; fgroup<=0; in_seen<=0; wt_seen<=0; hidden_seen<=0; gather_mask<=0; need_mask<=0; gather_row1<=0; gather_row2<=0; gather_row_current<=0; need_second<=0; second_requested<=0;
      for(i=0;i<7;i=i+1) sel_r[i]<=0;
    end else begin
      state<=next_state;
      if (state==IDLE && start) begin
        nidx<=0; gidx<=0; didx<=0; fgroup<=0;
        in_seen<=0; wt_seen<=0; hidden_seen<=0;
        gather_mask<=0; need_mask<=0; gather_row1<=0; gather_row2<=0;
        gather_row_current<=0; need_second<=0; second_requested<=0;
      end
      if (state==FC1_INPUT_WEIGHT_REQ) begin in_seen<=0; wt_seen<=0; end
      if (state==FC1_OPERAND_WAIT) begin
        if (input_group_valid) in_seen<=1;
        if (weight_row_valid) begin wt_seen<=1; sel_r[0]<=weight0_in; sel_r[1]<=weight1_in; sel_r[2]<=weight2_in; sel_r[3]<=weight3_in; sel_r[4]<=weight4_in; sel_r[5]<=weight5_in; sel_r[6]<=weight6_in; end
      end
      if (state==FC1_RELU_STORE && nidx==7) begin end
      if (state==FC2_GROUP_PREP) begin
        need_mask <= fgroup ? 7'b0000001 : 7'b1111111;
        gather_row1<=fc2_first_row_c; gather_row_current<=fc2_first_row_c; gather_row2<=fc2_second_row_c; need_second <= (fc2_first_row_c != fc2_second_row_c); second_requested<=0; gather_mask<=0; hidden_seen<=0;
      end
      if ((state==FC2_GATHER_WAIT) && layer2_group_valid) hidden_seen<=1;
      if ((state==FC2_GATHER_WAIT) && weight_row_valid) begin
        for(i=0;i<7;i=i+1) begin
          if (need_mask[i]) begin
            if ((fc2_lane_row_c[i]==gather_row_current) && weight_lane_valid[fc2_lane_num_c[i]]) begin
              case(fc2_lane_num_c[i])
                0:sel_r[i]<=weight0_in;1:sel_r[i]<=weight1_in;2:sel_r[i]<=weight2_in;3:sel_r[i]<=weight3_in;4:sel_r[i]<=weight4_in;5:sel_r[i]<=weight5_in;6:sel_r[i]<=weight6_in;
                default:sel_r[i]<=0;
              endcase
              gather_mask[i]<=1;
            end
          end
        end
        if (need_second && !second_requested) begin second_requested<=1; gather_row_current<=gather_row2; end
      end
      if (state==FC1_GROUP_WAIT && buffer_full) begin end
      if (state==FC1_CONSUME_WAIT && buffer_consume_valid && buffer_consume_ready && buffer_consume_last) begin if (gidx==111) gidx<=gidx; else gidx<=gidx+1'b1; end
      if (state==FC2_CONSUME_WAIT && buffer_consume_valid && buffer_consume_ready && buffer_consume_last) begin if (!fgroup) fgroup<=1'b1; else fgroup<=0; end
      if (state==FC1_RELU_STORE && nidx<7) begin nidx<=nidx+1'b1; gidx<=0; end
      if (state==FC2_LOGIT_SEND && didx<9) begin didx<=didx+1'b1; fgroup<=0; end
    end
  end
  always @* begin
    fc2_first_row_c=896+((8*didx+(fgroup?7:0))/7);
    fc2_second_row_c=896+((8*didx+(fgroup?7:0)+6)/7);
    for(c=0;c<7;c=c+1) begin
      fc2_lane_row_c[c]=896+((8*didx+(fgroup?7:0)+c)/7);
      fc2_lane_num_c[c]=(8*didx+(fgroup?7:0)+c)%7;
    end
    next_state=state; input_read_req=0; input_group_addr=gidx; weight_read_req=0; weight_row_addr=0; bias_read_req=0; bias_addr=0; multiplier_start=0; selected_weight_valid=0; buffer_consume_start=0; accumulator_start=0; accumulator_neuron_last=0; hidden_write_en=0; hidden_write_addr=nidx; layer2_group_read_req=0; layer2_group_addr=fgroup; argmax_start=0; argmax_logit_valid=0; argmax_logit_index=didx; argmax_logit_last=0; done=0; busy=(state!=IDLE); selected_weight0=sel_r[0]; selected_weight1=sel_r[1]; selected_weight2=sel_r[2]; selected_weight3=sel_r[3]; selected_weight4=sel_r[4]; selected_weight5=sel_r[5]; selected_weight6=sel_r[6];
    if ((state==FC1_MAC_START)||(state==FC1_GROUP_WAIT)||(state==FC1_CONSUME_WAIT)) selected_weight_valid=7'b1111111;
    if ((state==FC2_OPERAND_WAIT)||(state==FC2_MAC_START)||(state==FC2_GROUP_WAIT)||(state==FC2_CONSUME_WAIT)) selected_weight_valid=fgroup ? 7'b0000001 : 7'b1111111;
    case(state)
      IDLE: if(start) next_state=FC1_BIAS_REQ;
      FC1_BIAS_REQ: begin bias_read_req=1; bias_addr=nidx; next_state=FC1_BIAS_WAIT; end
      FC1_BIAS_WAIT: if(bias_valid) next_state=FC1_INPUT_WEIGHT_REQ;
      FC1_INPUT_WEIGHT_REQ: begin input_read_req=1; input_group_addr=gidx; weight_read_req=1; weight_row_addr=nidx*112+gidx; next_state=FC1_OPERAND_WAIT; end
      FC1_OPERAND_WAIT: if(in_seen && wt_seen && buffer_write_ready) next_state=FC1_MAC_START;
      FC1_MAC_START: begin if(!multiplier_busy) begin multiplier_start=1; accumulator_start=(gidx==0); next_state=FC1_GROUP_WAIT; end end
      FC1_GROUP_WAIT: if(buffer_full) begin buffer_consume_start=1; next_state=FC1_CONSUME_WAIT; end
      FC1_CONSUME_WAIT: begin accumulator_neuron_last=(gidx==111)&&buffer_consume_last; if(buffer_consume_valid&&buffer_consume_ready&&buffer_consume_last) begin if(gidx==111) next_state=FC1_RESULT_WAIT; else next_state=FC1_INPUT_WEIGHT_REQ; end end
      FC1_RESULT_WAIT: if(accumulator_result_valid) next_state=FC1_RELU_STORE;
      FC1_RELU_STORE: begin hidden_write_en=1; if(nidx==7) next_state=FC2_ARGMAX_START; else next_state=FC1_BIAS_REQ; end
      FC2_ARGMAX_START: begin argmax_start=1; next_state=FC2_BIAS_REQ; end
      FC2_BIAS_REQ: begin bias_read_req=1; bias_addr=8+didx; next_state=FC2_BIAS_WAIT; end
      FC2_BIAS_WAIT: if(bias_valid) next_state=FC2_GROUP_PREP;
      FC2_GROUP_PREP: begin layer2_group_read_req=1; layer2_group_addr=fgroup; weight_read_req=1; weight_row_addr=fc2_first_row_c; next_state=FC2_GATHER_WAIT; end
      FC2_GATHER_WAIT: begin if((gather_mask==need_mask)&&hidden_seen) next_state=FC2_OPERAND_WAIT; else if(weight_row_valid && need_second && !second_requested) begin weight_read_req=1; weight_row_addr=gather_row2; end end
      FC2_OPERAND_WAIT: if((gather_mask==need_mask)&&hidden_seen&&buffer_write_ready) next_state=FC2_MAC_START;
      FC2_MAC_START: begin if(!multiplier_busy) begin multiplier_start=1; accumulator_start=(fgroup==0); next_state=FC2_GROUP_WAIT; end end
      FC2_GROUP_WAIT: if(buffer_full) begin buffer_consume_start=1; next_state=FC2_CONSUME_WAIT; end
      FC2_CONSUME_WAIT: begin accumulator_neuron_last=(fgroup==1)&&buffer_consume_last; if(buffer_consume_valid&&buffer_consume_ready&&buffer_consume_last) begin if(fgroup==1) next_state=FC2_RESULT_WAIT; else next_state=FC2_GROUP_PREP; end end
      FC2_RESULT_WAIT: if(accumulator_result_valid) next_state=FC2_LOGIT_SEND;
      FC2_LOGIT_SEND: begin argmax_logit_valid=1; argmax_logit_index=didx; argmax_logit_last=(didx==9); if(didx==9) next_state=COMPLETE_WAIT; else next_state=FC2_BIAS_REQ; end
      COMPLETE_WAIT: begin if(argmax_done) begin done=1; next_state=IDLE; end end
      default: next_state=IDLE;
    endcase
  end
endmodule

module fc16_accelerator (
    input logic clk,input logic rst,input logic start,output logic done,
    output logic [3:0] prediction,
    output logic [15:0] logit0,logit1,logit2,logit3,logit4,logit5,logit6,logit7,logit8,logit9);
  logic igv,wrv,biasv,l2gv,bfull,bcv,bcl,acc_rv,amax_done;
  logic [15:0] in0,in1,in2,in3,in4,in5,in6,bias_o,w0,w1,w2,w3,w4,w5,w6,prod,acc_out;
  logic [6:0] imask,wmask,selmask,l2mask; logic [2:0] pidx; logic mgroup_done;
  logic [15:0] l20,l21,l22,l23,l24,l25,l26; logic cstart,astart,aneuron_last,hwe,arstart,alv,allast;
  logic [6:0] iaddr; logic [9:0] waddr; logic [4:0] baddr; logic [2:0] haddr; logic l2req,l2addr; logic [3:0] aidx;
  logic [15:0] sw0,sw1,sw2,sw3,sw4,sw5,sw6;
  logic ireq,wreq,breq,mstart,wready,pvalid,acc_ready,accbusy,amaxbusy,bempty,relu_v;
  logic [15:0] relu_data,bdata; logic [15:0] m_in0,m_in1,m_in2,m_in3,m_in4,m_in5,m_in6;
  logic [15:0] bias_latched; logic fc2_mode;
  logic [15:0] fc1_in_latched[0:6], hidden_latched[0:6]; integer wi;
  input_memory im(.clk(clk),.rst(rst),.read_req(ireq),.group_addr(iaddr),.group_valid(igv),.input0_out(in0),.input1_out(in1),.input2_out(in2),.input3_out(in3),.input4_out(in4),.input5_out(in5),.input6_out(in6),.lane_valid(imask));
  bias_memory bm(.clk(clk),.rst(rst),.read_req(breq),.bias_addr(baddr),.bias_valid(biasv),.bias_out(bias_o));
  weight_sram ws(.clk(clk),.rst(rst),.read_req(wreq),.row_addr(waddr),.row_valid(wrv),.weight0_out(w0),.weight1_out(w1),.weight2_out(w2),.weight3_out(w3),.weight4_out(w4),.weight5_out(w5),.weight6_out(w6),.lane_valid(wmask));
  layer2_register_file l2(.clk(clk),.rst(rst),.hidden_write_en(hwe),.hidden_write_addr(haddr),.hidden_write_data(relu_data),.group_read_req(l2req),.group_addr(l2addr),.group_valid(l2gv),.input0_out(l20),.input1_out(l21),.input2_out(l22),.input3_out(l23),.input4_out(l24),.input5_out(l25),.input6_out(l26),.lane_valid(l2mask));
  // Keep the accumulator result valid through the controller's dedicated
  // FC1_RELU_STORE cycle; acc_out is held stable after result_valid pulses.
  relu rr(.data_in(acc_out),.valid_in(acc_rv || hwe),.data_out(relu_data),.valid_out(relu_v));
  fp16_multiplier mm(.clk(clk),.rst(rst),.start_group(mstart),.input0(m_in0),.input1(m_in1),.input2(m_in2),.input3(m_in3),.input4(m_in4),.input5(m_in5),.input6(m_in6),.weight0(sw0),.weight1(sw1),.weight2(sw2),.weight3(sw3),.weight4(sw4),.weight5(sw5),.weight6(sw6),.lane_valid(selmask),.busy(mbusy),.product_valid(pvalid),.product_out(prod),.product_index(pidx),.group_done(mgroup_done));
  ping_pong_buffer pp(.clk(clk),.rst(rst),.product_valid(pvalid),.product_in(prod),.product_last(mgroup_done),.write_ready(wready),.consume_start(cstart),.consume_ready(acc_ready),.consume_valid(bcv),.consume_data(bdata),.consume_last(bcl),.buffer_full(bfull),.buffer_empty(bempty));
  fp16_accumulator aa(.clk(clk),.rst(rst),.neuron_start(astart),.bias_in(bias_latched),.product_valid(bcv),.product_in(bdata),.group_last(bcl),.neuron_last(aneuron_last),.product_ready(acc_ready),.busy(accbusy),.result_out(acc_out),.result_valid(acc_rv));
  argmax ax(.clk(clk),.rst(rst),.start(arstart),.logit_valid(alv),.logit_in(acc_out),.logit_index(aidx),.logit_last(allast),.busy(amaxbusy),.prediction(prediction),.done(amax_done),.logit0_out(logit0),.logit1_out(logit1),.logit2_out(logit2),.logit3_out(logit3),.logit4_out(logit4),.logit5_out(logit5),.logit6_out(logit6),.logit7_out(logit7),.logit8_out(logit8),.logit9_out(logit9));
  // STEP-038: wrapper clock/reset domain and transaction ports.
  // STEP-039: one instance of every submodule and approved status connections.
  always_ff @(posedge clk) begin
    if (rst) begin bias_latched<=0; fc2_mode<=0; for(wi=0;wi<7;wi=wi+1) begin fc1_in_latched[wi]<=0; hidden_latched[wi]<=0; end end
    else begin
      if (start) fc2_mode<=0;
      if (arstart) fc2_mode<=1;
      if (biasv) bias_latched<=bias_o;
      if (igv) begin fc1_in_latched[0]<=in0; fc1_in_latched[1]<=in1; fc1_in_latched[2]<=in2; fc1_in_latched[3]<=in3; fc1_in_latched[4]<=in4; fc1_in_latched[5]<=in5; fc1_in_latched[6]<=in6; end
      if (l2gv) begin hidden_latched[0]<=l20; hidden_latched[1]<=l21; hidden_latched[2]<=l22; hidden_latched[3]<=l23; hidden_latched[4]<=l24; hidden_latched[5]<=l25; hidden_latched[6]<=l26; end
    end
  end
  controller_fsm cf(.clk(clk),.rst(rst),.start(start),.input_group_valid(igv),.bias_valid(biasv),.layer2_group_valid(l2gv),.weight_row_valid(wrv),.weight0_in(w0),.weight1_in(w1),.weight2_in(w2),.weight3_in(w3),.weight4_in(w4),.weight5_in(w5),.weight6_in(w6),.weight_lane_valid(wmask),.multiplier_busy(mbusy),.buffer_write_ready(wready),.buffer_full(bfull),.buffer_consume_valid(bcv),.buffer_consume_ready(acc_ready),.buffer_consume_last(bcl),.accumulator_result_valid(acc_rv),.argmax_done(amax_done),.input_read_req(ireq),.input_group_addr(iaddr),.weight_read_req(wreq),.weight_row_addr(waddr),.bias_read_req(breq),.bias_addr(baddr),.multiplier_start(mstart),.selected_weight0(sw0),.selected_weight1(sw1),.selected_weight2(sw2),.selected_weight3(sw3),.selected_weight4(sw4),.selected_weight5(sw5),.selected_weight6(sw6),.selected_weight_valid(selmask),.buffer_consume_start(cstart),.accumulator_start(astart),.accumulator_neuron_last(aneuron_last),.hidden_write_en(hwe),.hidden_write_addr(haddr),.layer2_group_read_req(l2req),.layer2_group_addr(l2addr),.argmax_start(arstart),.argmax_logit_valid(alv),.argmax_logit_index(aidx),.argmax_logit_last(allast),.busy(),.done(done));
  // STEP-040: controller-selected FC1/FC2 operand path.
  // STEP-041: stable transaction-level outputs.
  always @* begin
    if (!fc2_mode) begin m_in0=fc1_in_latched[0]; m_in1=fc1_in_latched[1]; m_in2=fc1_in_latched[2]; m_in3=fc1_in_latched[3]; m_in4=fc1_in_latched[4]; m_in5=fc1_in_latched[5]; m_in6=fc1_in_latched[6]; end
    else begin m_in0=hidden_latched[0]; m_in1=hidden_latched[1]; m_in2=hidden_latched[2]; m_in3=hidden_latched[3]; m_in4=hidden_latched[4]; m_in5=hidden_latched[5]; m_in6=hidden_latched[6]; end
  end
endmodule
