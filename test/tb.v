// ============================================================
// tb.v — Nano-Forge 4-Lane MAC Testbench (Gate-Level Fixed)
// ============================================================
`timescale 1ns/1ps
`default_nettype none

module tb;

    reg clk, rst_n, ena;
    reg  [7:0] ui_in, uio_in;
    wire [7:0] uo_out, uio_out, uio_oe;

    localparam [2:0] CMD_LOAD_W  = 3'b000;
    localparam [2:0] CMD_MAC_ONE = 3'b001;
    localparam [2:0] CMD_MAC_ALL = 3'b010;
    localparam [2:0] CMD_CLR_ONE = 3'b011;
    localparam [2:0] CMD_CLR_ALL = 3'b100;
    localparam [2:0] CMD_NOP     = 3'b101;

    integer errors;
    integer k;

    tt_um_nanoforge_mac dut (
        .clk(clk), .rst_n(rst_n), .ena(ena),
        .ui_in(ui_in), .uio_in(uio_in),
        .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        $dumpfile("nanoforge_mac.vcd");
        $dumpvars(0, tb);
    end

    task send_cmd(input [2:0] cmd, input [1:0] lane, input [7:0] data);
        begin
            @(negedge clk);
            ui_in  = data;
            uio_in = {1'b1, 2'b00, lane, cmd};
            @(posedge clk);
            #1;
            uio_in[7] = 1'b0;
        end
    endtask

    task read_acc(input [1:0] lane, output [31:0] value);
        reg [7:0] b0, b1, b2, b3;
        begin
            @(negedge clk);
            uio_in = {1'b0, 2'b00, lane, CMD_NOP}; #1; b0 = uo_out;
            uio_in = {1'b0, 2'b01, lane, CMD_NOP}; #1; b1 = uo_out;
            uio_in = {1'b0, 2'b10, lane, CMD_NOP}; #1; b2 = uo_out;
            uio_in = {1'b0, 2'b11, lane, CMD_NOP}; #1; b3 = uo_out;
            value = {b3, b2, b1, b0};
        end
    endtask

    // Updated to use pin-based read_acc so it works in gate-level simulation
    task check_lane(input [1:0] lane, input [31:0] expected);
        reg [31:0] actual;
        begin
            read_acc(lane, actual);
            if (actual !== expected) begin
                $display("FAIL lane=%0d expected=%h actual=%h time=%0t",
                          lane, expected, actual, $time);
                errors = errors + 1;
            end
        end
    endtask

    task check_readback(input [1:0] lane, input [31:0] expected);
        reg [31:0] actual;
        begin
            read_acc(lane, actual);
            if (actual !== expected) begin
                $display("FAIL readback lane=%0d expected=%h actual=%h",
                          lane, expected, actual);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0; ena = 1'b1; rst_n = 1'b0; ui_in = 8'h00; uio_in = 8'h00;

        repeat (4) @(posedge clk); #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("---------------------------------------");
        $display("Nano-Forge 4-Lane MAC Testbench (fixed)");
        $display("---------------------------------------");

        // TEST 1: Reset + I/O safety
        $display("TEST 1: Reset and I/O safety");
        check_lane(0, 32'h0); check_lane(1, 32'h0);
        check_lane(2, 32'h0); check_lane(3, 32'h0);
        if (uio_oe !== 8'b0000_0001) begin
            $display("FAIL uio_oe=%b", uio_oe); errors = errors + 1;
        end
        if (uio_out[7:1] !== 7'b0) begin
            $display("FAIL non-flag uio_out bits are not zero"); errors = errors + 1;
        end

        // TEST 2: Basic MAC_ONE : 5 * 10 = 50
        $display("TEST 2: Basic MAC_ONE");
        send_cmd(CMD_LOAD_W, 2'd0, 8'd10);
        send_cmd(CMD_MAC_ONE, 2'd0, 8'd5);
        check_lane(0, 32'd50);
        check_readback(0, 32'd50);

        // TEST 3: MAC_ALL updates all lanes in parallel
        $display("TEST 3: MAC_ALL");
        send_cmd(CMD_LOAD_W, 2'd0, 8'd1);
        send_cmd(CMD_LOAD_W, 2'd1, 8'd2);
        send_cmd(CMD_LOAD_W, 2'd2, 8'd3);
        send_cmd(CMD_LOAD_W, 2'd3, 8'd4);
        send_cmd(CMD_CLR_ALL, 2'd0, 8'd0);
        send_cmd(CMD_MAC_ALL, 2'd0, 8'd10);
        check_lane(0, 32'd10); check_lane(1, 32'd20);
        check_lane(2, 32'd30); check_lane(3, 32'd40);

        // TEST 4: CLR_ONE only clears the selected lane
        $display("TEST 4: CLR_ONE isolation");
        send_cmd(CMD_CLR_ONE, 2'd1, 8'd0);
        check_lane(0, 32'd10); check_lane(1, 32'd0);
        check_lane(2, 32'd30); check_lane(3, 32'd40);

        // TEST 5: ena=0 must freeze all state
        $display("TEST 5: ena=0 freeze");
        ena = 1'b0;
        send_cmd(CMD_CLR_ONE, 2'd0, 8'd0);
        send_cmd(CMD_LOAD_W, 2'd0, 8'd99);
        send_cmd(CMD_MAC_ALL, 2'd0, 8'd7);
        check_lane(0, 32'd10); check_lane(1, 32'd0);
        check_lane(2, 32'd30); check_lane(3, 32'd40);
        
        `ifndef GATES
        if (dut.weight[0] !== 8'd1) begin
            $display("FAIL weight changed while ena=0"); errors = errors + 1;
        end
        `endif
        ena = 1'b1;

        // TEST 6: Negative saturation to INT32_MIN
        $display("TEST 6: Negative saturation");
        send_cmd(CMD_CLR_ALL, 2'd0, 8'd0);
        send_cmd(CMD_LOAD_W, 2'd0, 8'd127);
        for (k = 0; k < 132105; k = k + 1)
            send_cmd(CMD_MAC_ONE, 2'd0, -8'sd128);
        check_lane(0, 32'h8000_0000);
        if (uio_out[0] !== 1'b1) begin
            $display("FAIL overflow flag not set on negative saturation");
            errors = errors + 1;
        end

        // TEST 7: CLR_ONE must NOT clear the sticky overflow flag
        $display("TEST 7: CLR_ONE does not clear sticky overflow");
        send_cmd(CMD_CLR_ONE, 2'd0, 8'd0);
        check_lane(0, 32'd0); 
        if (uio_out[0] !== 1'b1) begin
            $display("FAIL sticky overflow flag was cleared by CLR_ONE (should NOT be)");
            errors = errors + 1;
        end else
            $display("PASS: overflow flag remains sticky after CLR_ONE");

        // TEST 8: CLR_ALL clears the sticky overflow flag
        $display("TEST 8: CLR_ALL clears sticky overflow");
        send_cmd(CMD_CLR_ALL, 2'd0, 8'd0);
        if (uio_out[0] !== 1'b0) begin
            $display("FAIL CLR_ALL did not clear overflow flag");
            errors = errors + 1;
        end

        // TEST 9: Positive saturation to INT32_MAX
        $display("TEST 9: Positive saturation");
        send_cmd(CMD_LOAD_W, 2'd1, 8'd127);
        for (k = 0; k < 133150; k = k + 1)
            send_cmd(CMD_MAC_ONE, 2'd1, 8'd127);
        check_lane(1, 32'h7FFF_FFFF);
        if (uio_out[0] !== 1'b1) begin
            $display("FAIL overflow flag not set on positive saturation");
            errors = errors + 1;
        end

        // TEST 10: Mid-operation asynchronous reset recovery
        $display("TEST 10: Mid-operation reset");
        send_cmd(CMD_CLR_ALL, 2'd0, 8'd0); 
        send_cmd(CMD_LOAD_W, 2'd2, 8'd7);
        send_cmd(CMD_MAC_ONE, 2'd2, 8'd9);
        check_lane(2, 32'd63);

        #2 rst_n = 1'b0;
        #1;
        check_lane(0, 32'd0); check_lane(1, 32'd0);
        check_lane(2, 32'd0); check_lane(3, 32'd0);
        
        `ifndef GATES
        if (dut.weight[2] !== 8'sd0) begin
            $display("FAIL weight not cleared by reset"); errors = errors + 1;
        end
        `endif
        
        if (uio_out[0] !== 1'b0) begin
            $display("FAIL overflow flag not cleared by reset"); errors = errors + 1;
        end

        @(negedge clk);
        rst_n = 1'b1;
        send_cmd(CMD_LOAD_W, 2'd2, 8'd3);
        send_cmd(CMD_MAC_ONE, 2'd2, 8'd4);
        check_lane(2, 32'd12);

        $display("---------------------------------------");
        if (errors == 0) $display("ALL TESTS PASSED");
        else $display("TESTS FAILED: %0d errors", errors);
        $display("---------------------------------------");
        $finish;
    end

endmodule

`default_nettype wire
