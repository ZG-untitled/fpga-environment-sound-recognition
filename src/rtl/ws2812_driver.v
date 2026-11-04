//=============================================================================
// ws2812_driver.v  --  WS2812 / WS2812B (NeoPixel) LED strip driver
//-----------------------------------------------------------------------------
// Target : 正点原子 启明星 ZYNQ-7020 (XC7Z020-1CLG400C)
// Tool   : Vivado
// Author : 丙 (PS / 整机负责人)
// Date   : 2026-09-22
//-----------------------------------------------------------------------------
// 时序规格 (WS2812B, 单线归零码 GRB 24bit):
//   T0H = 0.30us ~ 0.40us   (典型 0.35us)  -> 逻辑 0 高电平
//   T0L = 0.80us ~ 1.00us                  -> 逻辑 0 低电平
//   T1H = 0.65us ~ 0.95us   (典型 0.70us)  -> 逻辑 1 高电平
//   T1L = 0.30us ~ 0.60us                  -> 逻辑 1 低电平
//   RESET > 280us (低电平)
//
// 本模块参数化设计: 只调 CLK_FREQ_HZ 一个参数, 位时序自动重算。
// 推荐 CLK_FREQ_HZ = 50_000_000 (50MHz) 时:
//   T0H = 17 clk (340ns)   T0L = 42 clk (840ns)
//   T1H = 35 clk (700ns)   T1L = 25 clk (500ns)
//   RESET = 15000 clk (300us)
// 若你的板子 PL 时钟是 100MHz, 把 CLK_FREQ_HZ 改成 100_000_000 即可。
//
// 上电首灯不亮的处理:
//   复位后本模块会先发送 1 帧全 0 数据, 把灯带内部寄存器清零, 然后才输出正常内容。
//   同时 dout 在 IDLE 态恒为 0, 保证 DIN 空闲时是确定低电平。
//   配合 XDC 里"不加上下拉/不设 SLEW", 可避免首灯不亮或上电随机亮色。
//-----------------------------------------------------------------------------
// 用法 (见顶层 ws2812_top.v):
//   1) led_data[0]      -> 第 1 颗灯的 24bit GRB 值
//   2) led_data[i]      -> 第 i+1 颗灯
//   3) start 给一个单周期脉冲 -> 启动一次刷新
//   4) busy=1 表示正在刷新, 期间不要改 led_data
//=============================================================================

`timescale 1ns / 1ps

module ws2812_driver #(
    // ---- 系统时钟频率 (Hz), 必须和实际 PL 时钟一致 ----
    parameter integer CLK_FREQ_HZ = 50_000_000,
    // ---- 灯珠数量 ----
    parameter integer LED_NUM     = 30,
    // ---- 灯光亮度上限 (0~255), 用于整体限流/降亮, 防止 5V 电流不够 ----
    parameter integer BRIGHT_MAX  = 64
)(
    input  wire                   clk,
    input  wire                   rst_n,      // 低有效复位

    // ---- 控制接口 ----
    input  wire                   start,      // 单周期脉冲, 启动一次刷新
    output reg                    busy,       // 1 = 正在刷新

    // ---- 灯珠数据 (GRB, 24bit, led_data[23:16]=G, [15:8]=R, [7:0]=B) ----
    input  wire [LED_NUM*24-1:0]  led_data,

    // ---- 物理输出 ----
    output reg                    dout        // 接灯带黄线 (不串电阻, 不加上下拉)
);

    //=================================================================
    //  位时序参数计算 (自动, 不要手改)
    //=================================================================
    //-----------------------------------------------------------------
    //  ★注意: 这里必须"先除后乘"。
    //     原写法 (CLK_FREQ_HZ * 85) / 100000000 在 50MHz 时没问题,
    //     但 CLK_FREQ_HZ = 100_000_000 时中间积 100e6*85 = 8.5e9 已超出
    //     32bit 有符号整数上限 (2.147e9), 结果回绕成负数 -> 位时序全错。
    //     改成先除以 1e6 再乘, 中间值最大只有几万, 50/100/150/200MHz 都安全。
    //-----------------------------------------------------------------
    localparam integer T0H = (CLK_FREQ_HZ / 1_000_000) * 35  / 100; // 0.35us
    localparam integer T0L = (CLK_FREQ_HZ / 1_000_000) * 85  / 100; // 0.85us
    localparam integer T1H = (CLK_FREQ_HZ / 1_000_000) * 70  / 100; // 0.70us
    localparam integer T1L = (CLK_FREQ_HZ / 1_000_000) * 50  / 100; // 0.50us
    localparam integer TRST= (CLK_FREQ_HZ / 1_000_000) * 300;       // 300us

    localparam integer LED_CNT_W = (LED_NUM <= 1) ? 1 : $clog2(LED_NUM);
    localparam integer BIT_W     = $clog2(LED_NUM * 24);

    //=================================================================
    //  状态机
    //=================================================================
    localparam S_IDLE  = 3'd0,
               S_LOAD  = 3'd1,
               S_BITH  = 3'd2,
               S_BITL  = 3'd3,
               S_RESET = 3'd4;

    reg [2:0]             state;
    reg [BIT_W-1:0]       bit_idx;      // 当前发到第几位 (0 .. LED_NUM*24-1)
    reg [15:0]            tick;         // 位内计时
    reg [23:0]            shift;        // 当前正在发送的 24bit
    reg [LED_CNT_W-1:0]   led_idx;      // 当前灯序号
    reg [15:0]            rst_cnt;      // 复位低电平计时

    //=================================================================
    //  上电清屏: 复位后先发 1 帧全 0, 把灯带内部寄存器归零。
    //  这一步能避免"首灯不亮 / 上电随机亮色"的问题。
    //=================================================================
    reg boot_done;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) boot_done <= 1'b0;
        else if (state == S_RESET && rst_cnt == TRST - 1) boot_done <= 1'b1;
    end

    // 亮度缩放后的数据 (组合)
    //   boot 阶段强制输出全 0
    wire [23:0] cur_led = boot_done ? led_data[(led_idx+1)*24-1 -: 24] : 24'h000000;

    // 亮度缩放: val * BRIGHT_MAX / 255
    // ★ maxv 必须声明为"无符号位向量", 不能用 integer:
    //   integer 是有符号 32bit, 而 val 是无符号 8bit, 两者相乘会触发
    //   [Synth 37-81] [ASSIGN-2] mixed signed and unsigned types 警告。
    //   改 [15:0] 后两边都是无符号, 警告消失。
    //   宽度复核: val 最大 255, maxv 最大 255 -> 乘积 65025 < 65535, 16bit 不会溢出。
    function [7:0] scale8;
        input [7:0]  val;
        input [15:0] maxv;
        begin
            scale8 = (val * maxv) / 16'd255;   // 255 也写成无符号常量, 避免再混入有符号数
        end
    endfunction

    wire [7:0] g_s = scale8(cur_led[23:16], BRIGHT_MAX);
    wire [7:0] r_s = scale8(cur_led[15:8],  BRIGHT_MAX);
    wire [7:0] b_s = scale8(cur_led[7:0],   BRIGHT_MAX);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            dout    <= 1'b0;
            busy    <= 1'b0;
            bit_idx <= 0;
            tick    <= 0;
            shift   <= 0;
            led_idx <= 0;
            rst_cnt <= 0;
        end else begin
            case (state)
            //---------------------------------------------------------
            S_IDLE: begin
                dout    <= 1'b0;
                busy    <= 1'b0;
                bit_idx <= 0;
                led_idx <= 0;
                tick    <= 0;
                rst_cnt <= 0;
                if (start) begin
                    busy  <= 1'b1;
                    state <= S_LOAD;
                end
            end
            //---------------------------------------------------------
            // 装载当前灯的 GRB
            S_LOAD: begin
                shift   <= {g_s, r_s, b_s};   // 高位先发 (G7..G0 R7..R0 B7..B0)
                tick    <= 0;
                state   <= S_BITH;
            end
            //---------------------------------------------------------
            // 发送 bit 的高电平段
            S_BITH: begin
                dout <= 1'b1;
                if (shift[23]) begin
                    // 逻辑 1
                    if (tick >= T1H - 1) begin tick <= 0; state <= S_BITL; end
                    else                 tick <= tick + 1'b1;
                end else begin
                    // 逻辑 0
                    if (tick >= T0H - 1) begin tick <= 0; state <= S_BITL; end
                    else                 tick <= tick + 1'b1;
                end
            end
            //---------------------------------------------------------
            // 发送 bit 的低电平段, 并移位
            S_BITL: begin
                dout <= 1'b0;
                if (shift[23]) begin
                    if (tick >= T1L - 1) begin
                        tick  <= 0;
                        shift <= {shift[22:0], 1'b0};
                        if (bit_idx == 23) begin
                            // 这颗 24bit 发完
                            bit_idx <= 0;
                            if (led_idx == LED_NUM - 1) begin
                                led_idx <= 0;
                                state   <= S_RESET;   // 全部发完, 进复位
                            end else begin
                                led_idx <= led_idx + 1'b1;
                                state   <= S_LOAD;
                            end
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                            state   <= S_BITH;
                        end
                    end else tick <= tick + 1'b1;
                end else begin
                    if (tick >= T0L - 1) begin
                        tick  <= 0;
                        shift <= {shift[22:0], 1'b0};
                        if (bit_idx == 23) begin
                            bit_idx <= 0;
                            if (led_idx == LED_NUM - 1) begin
                                led_idx <= 0;
                                state   <= S_RESET;
                            end else begin
                                led_idx <= led_idx + 1'b1;
                                state   <= S_LOAD;
                            end
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                            state   <= S_BITH;
                        end
                    end else tick <= tick + 1'b1;
                end
            end
            //---------------------------------------------------------
            // RESET: 拉低 >280us, 锁存显示
            S_RESET: begin
                dout <= 1'b0;
                if (rst_cnt >= TRST - 1) begin
                    rst_cnt <= 0;
                    busy    <= 1'b0;
                    state   <= S_IDLE;
                end else begin
                    rst_cnt <= rst_cnt + 1'b1;
                end
            end
            //---------------------------------------------------------
            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
