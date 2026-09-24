// ============================================================
// design.v — Nano-Forge 4-Lane MAC (Grok-audit fixed version)
// ============================================================
`default_nettype none

module tt_um_nanoforge_mac (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ena,

    input  wire [7:0] ui_in,
    input  wire [7:0] uio_in,

    output wire [7:0] uo_out,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe
);

    localparam [2:0] CMD_LOAD_W  = 3'b000;
    localparam [2:0] CMD_MAC_ONE = 3'b001;
    localparam [2:0] CMD_MAC_ALL = 3'b010;
    localparam [2:0] CMD_CLR_ONE = 3'b011;
    localparam [2:0] CMD_CLR_ALL = 3'b100;
    localparam [2:0] CMD_NOP     = 3'b101;

    // ------------------------------------------------------------
    // Tiny Tapeout I/O — only pad 0 is driven (sticky overflow flag)
    // ------------------------------------------------------------
    reg overflow_flag;

    assign uio_oe  = 8'b0000_0001;
    assign uio_out = {7'b0000000, overflow_flag};

    // ------------------------------------------------------------
    // Architectural state
    // ------------------------------------------------------------
    reg signed [7:0]  weight [0:3];
    reg signed [31:0] acc    [0:3];

    wire       valid    = uio_in[7];
    wire [1:0] byte_sel = uio_in[6:5];
    wire [1:0] lane_sel = uio_in[4:3];
    wire [2:0] command  = uio_in[2:0];

    // ------------------------------------------------------------
    // Readback mux — pure combinational, fully specified, no latch
    // ------------------------------------------------------------
    reg [31:0] selected_acc;
    reg [7:0]  read_byte;

    always @(*) begin
        selected_acc = acc[lane_sel];
        case (byte_sel)
            2'b00:   read_byte = selected_acc[7:0];
            2'b01:   read_byte = selected_acc[15:8];
            2'b10:   read_byte = selected_acc[23:16];
            default: read_byte = selected_acc[31:24];
        endcase
    end

    assign uo_out = read_byte;

    // ------------------------------------------------------------
    // FIX: fully combinational MAC datapath, 4 dedicated lanes.
    // No shared temp registers, no for-loop reuse. Every product,
    // sum and saturation wire is plain `wire`, computed every
    // cycle, and consumed by BOTH CMD_MAC_ONE (via mux) and
    // CMD_MAC_ALL (all 4 lanes in parallel, same cycle).
    // ------------------------------------------------------------
    wire signed [15:0] product0 = $signed(ui_in) * $signed(weight[0]);
    wire signed [15:0] product1 = $signed(ui_in) * $signed(weight[1]);
    wire signed [15:0] product2 = $signed(ui_in) * $signed(weight[2]);
    wire signed [15:0] product3 = $signed(ui_in) * $signed(weight[3]);

    wire signed [32:0] sum0 = {acc[0][31], acc[0]} + {{17{product0[15]}}, product0};
    wire signed [32:0] sum1 = {acc[1][31], acc[1]} + {{17{product1[15]}}, product1};
    wire signed [32:0] sum2 = {acc[2][31], acc[2]} + {{17{product2[15]}}, product2};
    wire signed [32:0] sum3 = {acc[3][31], acc[3]} + {{17{product3[15]}}, product3};

    wire ovf0 = (sum0[32] != sum0[31]);
    wire ovf1 = (sum1[32] != sum1[31]);
    wire ovf2 = (sum2[32] != sum2[31]);
    wire ovf3 = (sum3[32] != sum3[31]);

    wire signed [31:0] next_acc0 = ovf0 ? (sum0[32] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum0[31:0];
    wire signed [31:0] next_acc1 = ovf1 ? (sum1[32] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum1[31:0];
    wire signed [31:0] next_acc2 = ovf2 ? (sum2[32] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum2[31:0];
    wire signed [31:0] next_acc3 = ovf3 ? (sum3[32] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum3[31:0];

    // ------------------------------------------------------------
    // Sequential control — pure register updates, zero arithmetic
    // ------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            weight[0] <= 8'sd0;
            weight[1] <= 8'sd0;
            weight[2] <= 8'sd0;
            weight[3] <= 8'sd0;

            acc[0] <= 32'sd0;
            acc[1] <= 32'sd0;
            acc[2] <= 32'sd0;
            acc[3] <= 32'sd0;

            overflow_flag <= 1'b0;
        end else if (ena && valid) begin
            case (command)

                CMD_LOAD_W: begin
                    weight[lane_sel] <= $signed(ui_in);
                end

                CMD_MAC_ONE: begin
                    case (lane_sel)
                        2'd0: begin acc[0] <= next_acc0; if (ovf0) overflow_flag <= 1'b1; end
                        2'd1: begin acc[1] <= next_acc1; if (ovf1) overflow_flag <= 1'b1; end
                        2'd2: begin acc[2] <= next_acc2; if (ovf2) overflow_flag <= 1'b1; end
                        2'd3: begin acc[3] <= next_acc3; if (ovf3) overflow_flag <= 1'b1; end
                    endcase
                end

                CMD_MAC_ALL: begin
                    acc[0] <= next_acc0;
                    acc[1] <= next_acc1;
                    acc[2] <= next_acc2;
                    acc[3] <= next_acc3;
                    if (ovf0 || ovf1 || ovf2 || ovf3) overflow_flag <= 1'b1;
                end

                CMD_CLR_ONE: begin
                    acc[lane_sel] <= 32'sd0;
                    // sticky overflow flag intentionally NOT cleared here
                end

                CMD_CLR_ALL: begin
                    acc[0] <= 32'sd0;
                    acc[1] <= 32'sd0;
                    acc[2] <= 32'sd0;
                    acc[3] <= 32'sd0;
                    overflow_flag <= 1'b0;
                end

                CMD_NOP: begin
                    // no state change
                end

                default: begin
                    // reserved/invalid command: no state change
                end

            endcase
        end
    end

endmodule

`default_nettype wire
