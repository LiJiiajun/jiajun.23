/************************************************************************
Avalon-MM Interface VGA Text mode display

Modified for DE2-115 board

Register Map:
0x000-0x0257 : VRAM, 80x30 (2400 byte, 600 word) raster order (first column then row)
0x258        : control register

VRAM Format:
X->
[ 31  30-24][ 23  22-16][ 15  14-8 ][ 7    6-0 ]
[IV3][CODE3][IV2][CODE2][IV1][CODE1][IV0][CODE0]

IVn = Draw inverse glyph
CODEn = Glyph code from IBM codepage 437

Control Register Format:
[[31-25][24-21][20-17][16-13][ 12-9][ 8-5 ][ 4-1 ][   0    ] 
[[RSVD ][FGD_R][FGD_G][FGD_B][BKG_R][BKG_G][BKG_B][RESERVED]

VSYNC signal = bit which flips on every Vsync (time for new frame), used to synchronize software
BKG_R/G/B = Background color, flipped with foreground when IVn bit is set
FGD_R/G/B = Foreground color, flipped with background when Inv bit is set

************************************************************************/
`define VRAM_WORDS 600 //80*30 characters / 4 characters per register
`define CTRL_ADDR 12'h258 //index of control register

module vga_text_avl_interface (
	// Avalon Clock Input, note this clock is also used for VGA, so this must be 50Mhz
	// We can put a clock divider here in the future to make this IP more generalizable
	input logic CLK,
	
	// Avalon Reset Input
	input logic RESET,
	
	// Avalon-MM Slave Signals
	input  logic AVL_READ,					// Avalon-MM Read
	input  logic AVL_WRITE,					// Avalon-MM Write
	input  logic AVL_CS,					// Avalon-MM Chip Select
	input  logic [3:0] AVL_BYTE_EN,			// Avalon-MM Byte Enable
	input  logic [11:0] AVL_ADDR,			// Avalon-MM Address
	input  logic [31:0] AVL_WRITEDATA,		// Avalon-MM Write Data
	output logic [31:0] AVL_READDATA,		// Avalon-MM Read Data
	
	// Exported Conduit (mapped to VGA port - make sure you export in Platform Designer)
	output logic [3:0]  red, green, blue,	// VGA color channels (mapped to output pins in top-level)
	output logic hs, vs,					// VGA HS/VS
	output logic sync, blank, pixel_clk		// Required by DE2-115 video encoder
);
// Registers
logic [31:0] CTRL_REG_DATA;
logic [31:0] draw_vram_word;
logic[31:0] avl_vram_q;
logic[31:0] vga_vram_q;
logic vram_write;
logic avl_read_vram_q;
logic avl_read_ctrl_q;
logic[31:0] ctrl_read_q;
//put other local variables here
logic[9:0] DrawX, DrawY;
logic[9:0] DrawX_q, DrawY_q;
logic[9:0] DrawX_qq, DrawY_qq;
logic[10:0] font_addr;
logic[7:0] font_data;
logic[4:0] char_row;
logic[6:0] char_col;
logic[11:0] char_id;
logic[9:0] word_id;
logic[1:0] byte_id;
logic[1:0] byte_id_q;
logic[1:0] byte_id_qq;
logic[31:0] c_word;
logic[7:0] c_byte;
logic[6:0] g_code;
logic inv_bit;
logic g_pixel;
logic color;
logic[3:0] fg_r,fg_g,fg_b;
logic[3:0] bg_r,bg_g,bg_b;
logic visible;
logic visible_q;
logic visible_qq;

//Declare submodules..e.g. VGA controller, ROMS, etc
vga_controller vga_core(
	.Clk(CLK),
	.Reset(RESET),
	.hs(hs),
	.vs(vs),
	.pixel_clk(pixel_clk),
	.blank(blank),
	.sync(sync),
	.DrawX(DrawX),
	.DrawY(DrawY)
);

font_rom font_rom_inst(
	.addr(font_addr),
	.data(font_data)
);

assign vram_write = (!RESET) && AVL_CS && AVL_WRITE && (AVL_ADDR < `VRAM_WORDS);

lab9_2_vram vram_inst(
	.address_a(AVL_ADDR[9:0]),
	.address_b(word_id),
	.byteena_a(AVL_BYTE_EN),
	.clock(CLK),
	.data_a(AVL_WRITEDATA),
	.data_b(32'h0000_0000),
	.wren_a(vram_write),
	.wren_b(1'b0),
	.q_a(avl_vram_q),
	.q_b(vga_vram_q)
);
assign draw_vram_word = visible_qq ? vga_vram_q : 32'h0000_0000;

// Read and write from AVL interface to register block, note that READ waitstate = 1, so this should be in always_ff
always_ff @(posedge CLK) begin
	if(RESET) begin
		CTRL_REG_DATA<=32'h01FF_E000;
		ctrl_read_q<=32'h0000_0000;
		DrawX_q<=10'd0;
		DrawY_q<=10'd0;
		DrawX_qq<=10'd0;
		DrawY_qq<=10'd0;
		byte_id_q<=2'd0;
		byte_id_qq<=2'd0;
		visible_q<=1'b0;
		visible_qq<=1'b0;
	end
	else begin
		DrawX_q<=DrawX;
		DrawY_q<=DrawY;
		DrawX_qq<=DrawX_q;
		DrawY_qq<=DrawY_q;
		byte_id_q<=byte_id;
		byte_id_qq<=byte_id_q;
		visible_q<=visible;
		visible_qq<=visible_q;
		if(AVL_CS && AVL_WRITE && (AVL_ADDR==`CTRL_ADDR)) begin
			if(AVL_BYTE_EN[0]) CTRL_REG_DATA[7:0]<=AVL_WRITEDATA[7:0];
			if(AVL_BYTE_EN[1]) CTRL_REG_DATA[15:8]<=AVL_WRITEDATA[15:8];
			if(AVL_BYTE_EN[2]) CTRL_REG_DATA[23:16]<=AVL_WRITEDATA[23:16];
			if(AVL_BYTE_EN[3]) CTRL_REG_DATA[31:24]<=AVL_WRITEDATA[31:24];
		end
		avl_read_vram_q<=AVL_CS && AVL_READ && (AVL_ADDR<`VRAM_WORDS);
		avl_read_ctrl_q<=AVL_CS && AVL_READ && (AVL_ADDR==`CTRL_ADDR);
		ctrl_read_q<=CTRL_REG_DATA;
	end
end


//handle drawing (may either be combinational or sequential - or both).
always_comb begin
	if(avl_read_vram_q)
		AVL_READDATA=avl_vram_q;
	else if(avl_read_ctrl_q)
		AVL_READDATA=ctrl_read_q;
	else
		AVL_READDATA=32'h0000_0000;
end

always_comb begin
	red=4'h0;
	green=4'h0;
	blue=4'h0;
	char_row=5'd0;
	char_col=7'd0;
	char_id=12'd0;
	word_id=10'd0;
	byte_id=2'd0;
	c_word=32'd0;
	c_byte=8'd0;
	g_code=7'd0;
	inv_bit=1'b0;
	font_addr=11'd0;
	g_pixel=1'b0;
	color=1'b0;
	visible=(blank&&(DrawX<10'd640)&&(DrawY<10'd480));
	
	fg_r=CTRL_REG_DATA[24:21];
	fg_g=CTRL_REG_DATA[20:17];
	fg_b=CTRL_REG_DATA[16:13];
	bg_r=CTRL_REG_DATA[12:9];
	bg_g=CTRL_REG_DATA[8:5];
	bg_b=CTRL_REG_DATA[4:1];
	
	if(visible) begin
		char_col=DrawX[9:3];
		char_row=DrawY[8:4];
		char_id=char_row*12'd80+char_col;
		word_id=char_id[11:2];
		byte_id=char_id[1:0];
	end
	
	if(visible_q) begin
		c_word=draw_vram_word;
		
		case(byte_id_q)
			2'd0: c_byte=c_word[7:0];
			2'd1: c_byte=c_word[15:8];
			2'd2: c_byte=c_word[23:16];
			2'd3: c_byte=c_word[31:24];
			default: c_byte=8'h00;
		endcase

		inv_bit=c_byte[7];
		g_code=c_byte[6:0];
		font_addr={g_code, DrawY_q[3:0]};
		g_pixel=font_data[7-DrawX_q[2:0]];
		color=g_pixel^inv_bit;
		
		if(color) begin
			red=fg_r;
			green=fg_g;
			blue=fg_b;
		end
		else begin
			red=bg_r;
			green=bg_g;
			blue=bg_b;
		end
	end
end

endmodule
