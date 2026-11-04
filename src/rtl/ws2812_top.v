//=============================================================================
// ws2812_top.v  --  启明星 ZYNQ-7020 LED 灯带双状态顶层 (纯 PL, 无需 PS/串口)
//-----------------------------------------------------------------------------
// 功能: 用 PL 功能按键 KEY0 在两种工作状态之间切换 (按一下翻转一次, LED 常亮)
//
//   ┌────────────────────────────────────────────────────────────────────┐
//   │  状态 0 (上电默认)   待机 / 正常监控                                │
//   │       灯带     : 全灯绿色呼吸 (缓慢明暗, 一个周期约 2.7s)            │
//   │       板载 LED : 只亮 led[0] (H15), 其余熄灭                        │
//   │                                                                    │
//   │  状态 1              告警 / 检出危险声                              │
//   │       灯带     : 全灯红色爆闪 (约 3Hz 硬通断)                        │
//   │       板载 LED : 3 个灯跟着一起闪                                   │
//   └────────────────────────────────────────────────────────────────────┘
//
// 按键: KEY0 = L14 (PL_KEY0)。板上已有 10K 上拉, 松开=1, 按下=0。
//       本模块内部做 20ms 消抖 + 下降沿检测, 一次按下只翻转一次 (不会连跳)。
//
// 灯带: 0.5m 白底 60灯/m = 30 颗 WS2812B, 5V 供电。
//       满白满载 = 30 x 60mA = 1.8A, 远超开发板 5V 输出能力;
//       本设计 BRIGHT_MAX = 64 已把电流压到 30 x 15mA ≈ 0.45A, 开发板 5V 脚直供即可。
//       ★ 若以后把 BRIGHT_MAX 调大(>128), 必须外接 5V/3A 电源, 并和开发板共地。
//
// 硬件接线 (底板扩展口 EXT_IO, 对应原理图 04_ETH&SD&EXT.SchDoc 的 J2, Header 12X2)
//     灯带 黄线 DIN  -> J2 第 3 脚    (FPGA 管脚 F20, 板级网络 B35_L15_N)
//     灯带 黑线 GND  -> J2 第 2 脚
//     灯带 红线 +5V  -> J4 第 40 脚 (+5V)
//     ★ J2 第 1 脚是 +3.3V, 不能拿来给灯带供电。
//       本设计 30 颗灯 + BRIGHT_MAX=64 约 0.45A, 用开发板 5V 脚可以;
//       若把亮度调大, 请外接 5V/3A 电源, 并且外接电源的地必须和开发板 GND 接在一起 (共地)。
//
// ★ 电平提醒: WS2812B 的 VIH = 0.7*VDD = 3.5V (VDD=5V), FPGA 只能输出 3.3V,
//   属于临界驱动。数据线短 (<20cm) 一般能正常点亮; 若出现乱码或首灯不亮,
//   用 74HCT245 把 3.3V 抬到 5V。数据线上不要串电阻、不要加上下拉。
//=============================================================================

`timescale 1ns / 1ps

module ws2812_top #(
    parameter integer CLK_FREQ_HZ = 50_000_000,  // 必须与 XDC 里的时钟约束一致
    parameter integer LED_NUM     = 30,          // 灯珠数量 (0.5m x 60灯/m = 30颗)
    parameter integer BRIGHT_MAX  = 64           // 亮度上限(0~255), 保护 5V 供电
)(
    input  wire        clk,          // 50MHz 板载时钟
    input  wire        rst_n,        // PL 复位按键, 低有效
    input  wire        key,          // PL 功能按键 KEY0 (L14), 按下 = 0
    output wire        ws2812_dout,  // -> 灯带黄线 DIN
    output wire [2:0]  led           // 板载 PL LED, 低有效
);

    //=================================================================
    //  1. 按键处理 + 工作状态
    //=================================================================
    //  --- 1.1 异步输入同步 (两级触发器) ---
    reg key_s0, key_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key_s0 <= 1'b1;
            key_s1 <= 1'b1;
        end else begin
            key_s0 <= key;
            key_s1 <= key_s0;
        end
    end

    //  --- 1.2 消抖 ---
    //  只有新电平连续保持 DEB_CNT 个时钟才认为"真的变了"。
    //  ★位宽检查: DEB_CNT = 50e6/50 = 1_000_000, 需要 20bit (上限 1_048_575), 刚好够。
    localparam integer DEB_CNT = CLK_FREQ_HZ / 50;   // 20ms

    reg [19:0] deb_cnt;
    reg        key_stable;                            // 消抖后的按键电平, 1=松开

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            deb_cnt    <= 20'd0;
            key_stable <= 1'b1;
        end else if (key_s1 != key_stable) begin
            if (deb_cnt >= DEB_CNT - 1) begin
                deb_cnt    <= 20'd0;
                key_stable <= key_s1;                 // 电平稳定, 认账
            end else begin
                deb_cnt    <= deb_cnt + 1'b1;
            end
        end else begin
            deb_cnt <= 20'd0;                         // 回到稳态, 计数器清零
        end
    end

    //  --- 1.3 下降沿检测 = 一次"按下"事件 (单周期脉冲) ---
    //  ★这两行必须写在下面用到 key_press 的 always 之前。
    reg  key_stable_d;
    wire key_press;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) key_stable_d <= 1'b1;
        else        key_stable_d <= key_stable;
    end

    assign key_press = key_stable_d & (~key_stable);

    //  --- 1.4 工作状态 ---
    //  0 = 待机 (绿色呼吸)   1 = 告警 (红色爆闪)
    reg state_alarm;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         state_alarm <= 1'b0;
        else if (key_press) state_alarm <= ~state_alarm;   // 按一次翻一次
    end

    //=================================================================
    //  2. 灯效引擎 -> 生成 LED_NUM 个 24bit GRB
    //=================================================================
    //  --- 2.1 自由运行计数器 (呼吸 / 爆闪共用) ---
    reg [26:0] pwm_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pwm_cnt <= 27'd0;
        else        pwm_cnt <= pwm_cnt + 1'b1;
    end

    //  --- 2.2 呼吸包络 (三角波 0..255..0) ---
    //  pwm_cnt[26:18] 是 9bit 自由计数 (0..511), 折成三角波后取低 8 位。
    //  整个呼吸周期 = 512 * 2^18 / 50MHz ≈ 2.68s —— 这才是正常的"呼吸"节奏。
    //  (若取更低的位, 周期会变成十几毫秒, 肉眼看到的是"闪", 不是呼吸)
    wire [8:0] tri_raw = pwm_cnt[26:18];
    wire [8:0] breath9 = tri_raw[8] ? (9'd511 - tri_raw) : tri_raw;
    wire [7:0] breath  = breath9[7:0];

    //  --- 2.3 爆闪节奏 ---
    //  pwm_cnt[23:21] 每 2^21 / 50MHz = 42ms 进一格, 8 格一循环 -> 约 3Hz 通断
    wire [7:0] strobe = (pwm_cnt[23:21] < 3'd4) ? 8'hFF : 8'h00;

    //  --- 2.4 逐灯生成 ---
    reg  [LED_NUM*24-1:0] led_data;
    integer i;
    reg [7:0] er, eg, eb;      // 该灯的颜色 {R,G,B}

    always @(*) begin
        led_data = {(LED_NUM*24){1'b0}};
        for (i = 0; i < LED_NUM; i = i + 1) begin
            if (!state_alarm) begin
                // ---------------- 状态 0: 绿色呼吸 ----------------
                er = 8'h00;
                eg = breath;               // 0 -> 255 -> 0 缓慢明暗
                eb = 8'h00;
            end else begin
                // ---------------- 状态 1: 红色爆闪 ----------------
                er = strobe;               // 255 / 0 硬通断
                eg = 8'h00;
                eb = 8'h00;
            end

            // ★ WS2812B 的数据顺序是 GRB 不是 RGB, 必须 {G,R,B}
            led_data[i*24 +: 24] = {eg, er, eb};
        end
    end

    //=================================================================
    //  3. 灯带驱动实例 (40Hz 刷新, 灯带不会闪)
    //=================================================================
    reg  drv_start;
    wire drv_busy;
    reg  [20:0] refresh_cnt;

    //  ★位宽检查: CLK_FREQ_HZ/40 = 1_250_000, 需要 21bit (上限 2_097_151)。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_cnt <= 21'd0;
            drv_start   <= 1'b0;
        end else begin
            drv_start <= 1'b0;                          // 默认拉低 = 单周期脉冲
            if (refresh_cnt >= CLK_FREQ_HZ/40 - 1) begin
                refresh_cnt <= 21'd0;
                if (!drv_busy) drv_start <= 1'b1;
            end else begin
                refresh_cnt <= refresh_cnt + 1'b1;
            end
        end
    end

    ws2812_driver #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .LED_NUM     (LED_NUM),
        .BRIGHT_MAX  (BRIGHT_MAX)
    ) u_ws2812 (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (drv_start),
        .busy     (drv_busy),
        .led_data (led_data),
        .dout     (ws2812_dout)
    );

    //=================================================================
    //  4. 板载 LED 指示当前状态 (低有效)
    //=================================================================
    //  待机: 只亮 led[0]          告警: 3 个灯跟着爆闪一起亮灭
    assign led = state_alarm ? (strobe[7] ? 3'b000 : 3'b111)   // 告警: 齐闪
                             : 3'b110;                          // 待机: 只亮 led[0]

endmodule
