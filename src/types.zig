const std = @import("std");
const c = @import("c_imports.zig");
const ft = c.ft;

pub const BrowserState = enum {
    Idle,
    Loading,
    Loaded,
    Error,
};

pub const Node = union(enum) {
    Element: *ElementNode,
    Text: *TextNode,
};

pub const EdgeSizes = struct {
    top: f32,
    right: f32,
    bottom: f32,
    left: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    height: f32,
    width: f32,
};

pub const Dimensions = struct {
    content: Rect,
    border: EdgeSizes,
    padding: EdgeSizes,
    margin: EdgeSizes,

    pub fn paddingBox(self: Dimensions) Rect {
        const height = self.padding.top + self.padding.bottom + self.content.height;
        const width = self.padding.right + self.padding.left + self.content.width;
        const x = self.content.x - self.padding.left;
        const y = self.content.y - self.padding.top;
        return .{ .height = height, .width = width, .x = x, .y = y };
    }

    pub fn borderBox(self: Dimensions) Rect {
        const pb = self.paddingBox();
        const height = self.border.top + self.border.bottom + pb.height;
        const width = self.border.right + self.border.left + pb.width;
        const x = pb.x - self.border.left;
        const y = pb.y - self.border.top;
        return .{ .height = height, .width = width, .x = x, .y = y };
    }

    pub fn marginBox(self: Dimensions) Rect {
        const bb = self.borderBox();
        const height = self.margin.top + self.margin.bottom + bb.height;
        const width = self.margin.right + self.margin.left + bb.width;
        const x = bb.x - self.margin.left;
        const y = bb.y - self.margin.top;
        return .{ .height = height, .width = width, .x = x, .y = y };
    }
};

pub const BoxType = enum {
    Block,
    Inline,
    Anonymous, // elements that aren't rendered
};

pub const TextFragment = struct {
    content: []const u8, // slice into original text (no copy)
    x: f32, // position relative to containing block
    y: f32,
    width: f32,
    ascent: f32,
    descent: f32,
};

pub const LayoutBox = struct {
    node: ?Node,
    children: ?std.ArrayList(*LayoutBox),
    dimensions: Dimensions,
    box_type: BoxType,
    fragments: ?std.ArrayList(TextFragment), // only for text nodes
};

pub const ElementNode = struct {
    tag_name: []const u8,
    raw_attributes: []const u8,
    children: std.ArrayList(Node),
};

pub const TextNode = struct {
    content: []const u8,
};

// TODO: revisit this. this is likely not the ideal approach to managing
// memory/state for the app, but it's a start. we can iterate on this as we go
pub const AppMemory = struct {
    ft_library: ft.FT_Library,
    ft_face: ft.FT_Face,
    ft_is_initialized: bool,
    ft_init_failed: bool, // set permanently on first init failure; suppresses retry

    // Browser state
    browser_state: BrowserState,
    current_url: []u8,
    response_body: []u8,
    error_message: []u8,
    dom_tree: ?Node,
    layout_tree: ?*LayoutBox,

    // Render settings (will be handled by CSS, and probably some other struct in the future)
    background_color: Color,
    text_color: Color,

    // Arena allocator for page content
    arena: std.heap.ArenaAllocator,

    // a chunk of memory for things that should persist
    // across frames (e.g. page content, cached glyph bitmaps, etc)
    persistent_storage: []u8,
    transient_storage: []u8,
};

/// BGRA8 pixel layout matching X11 ZPixmap 32-bit visual (little-endian).
pub const Color = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 0xFF };
    }
};

/// Software framebuffer the platform allocates and the app draws into.
pub const OffscreenBuffer = struct {
    memory: [*]u8,
    width: i32,
    height: i32,
    pitch: i32,
    bytes_per_pixel: i32,

    pub fn clear(self: *OffscreenBuffer, color: Color) void {
        const pixel: u32 = @bitCast(color);
        const w: usize = @intCast(self.width);
        const h: usize = @intCast(self.height);
        const pitch: usize = @intCast(self.pitch);

        for (0..h) |y| {
            const row: [*]u32 = @ptrCast(@alignCast(self.memory + y * pitch));
            @memset(row[0..w], pixel);
        }
    }

    /// Draw a FreeType bitmap into the buffer.
    /// Supports LCD (FT_PIXEL_MODE_LCD), grayscale (FT_PIXEL_MODE_GRAY), and
    /// mono (FT_PIXEL_MODE_MONO) bitmaps. Any other pixel mode is ignored.
    pub fn drawFTBitmap(
        self: *OffscreenBuffer,
        bitmap: *const ft.FT_Bitmap,
        x: i32,
        y: i32,
        color: Color,
    ) void {
        const bm_buffer: [*]const u8 = bitmap.buffer orelse return;
        const bm_rows: i32 = @intCast(bitmap.rows);
        const bm_pitch: i32 = bitmap.pitch;

        switch (bitmap.pixel_mode) {
            ft.FT_PIXEL_MODE_LCD => {
                // Horizontal subpixel rendering: each pixel is 3 bytes (R,G,B coverage).
                const bm_width: i32 = @intCast(bitmap.width / 3);

                const start_x: i32 = @max(0, -x);
                const start_y: i32 = @max(0, -y);
                const end_x: i32 = @min(bm_width, self.width - x);
                const end_y: i32 = @min(bm_rows, self.height - y);
                if (start_x >= end_x or start_y >= end_y) return;

                for (@as(usize, @intCast(start_y))..@as(usize, @intCast(end_y))) |bm_row| {
                    const row_i: i32 = @intCast(bm_row);
                    const dest_y = y + row_i;
                    const src_row_offset: i32 = if (bm_pitch > 0) row_i * bm_pitch else (bm_rows - 1 - row_i) * (-bm_pitch);
                    const src_row: [*]const u8 = bm_buffer + @as(usize, @intCast(src_row_offset));
                    const dest_row: [*]Color = @ptrCast(@alignCast(self.memory + @as(usize, @intCast(dest_y * self.pitch))));

                    for (@as(usize, @intCast(start_x))..@as(usize, @intCast(end_x))) |bm_col| {
                        const dest_x = x + @as(i32, @intCast(bm_col));
                        const r_coverage: f32 = @as(f32, @floatFromInt(src_row[bm_col * 3 + 0])) / 255.0;
                        const g_coverage: f32 = @as(f32, @floatFromInt(src_row[bm_col * 3 + 1])) / 255.0;
                        const b_coverage: f32 = @as(f32, @floatFromInt(src_row[bm_col * 3 + 2])) / 255.0;
                        const dest_pixel: *Color = &dest_row[@as(usize, @intCast(dest_x))];
                        dest_pixel.r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * r_coverage + @as(f32, @floatFromInt(dest_pixel.r)) * (1.0 - r_coverage));
                        dest_pixel.g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * g_coverage + @as(f32, @floatFromInt(dest_pixel.g)) * (1.0 - g_coverage));
                        dest_pixel.b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * b_coverage + @as(f32, @floatFromInt(dest_pixel.b)) * (1.0 - b_coverage));
                    }
                }
            },
            ft.FT_PIXEL_MODE_GRAY => {
                // Single-channel grayscale: one byte per pixel.
                const bm_width: i32 = @intCast(bitmap.width);

                const start_x: i32 = @max(0, -x);
                const start_y: i32 = @max(0, -y);
                const end_x: i32 = @min(bm_width, self.width - x);
                const end_y: i32 = @min(bm_rows, self.height - y);
                if (start_x >= end_x or start_y >= end_y) return;

                for (@as(usize, @intCast(start_y))..@as(usize, @intCast(end_y))) |bm_row| {
                    const row_i: i32 = @intCast(bm_row);
                    const dest_y = y + row_i;
                    const src_row_offset: i32 = if (bm_pitch > 0) row_i * bm_pitch else (bm_rows - 1 - row_i) * (-bm_pitch);
                    const src_row: [*]const u8 = bm_buffer + @as(usize, @intCast(src_row_offset));
                    const dest_row: [*]Color = @ptrCast(@alignCast(self.memory + @as(usize, @intCast(dest_y * self.pitch))));

                    for (@as(usize, @intCast(start_x))..@as(usize, @intCast(end_x))) |bm_col| {
                        const dest_x = x + @as(i32, @intCast(bm_col));
                        const coverage: f32 = @as(f32, @floatFromInt(src_row[bm_col])) / 255.0;
                        const dest_pixel: *Color = &dest_row[@as(usize, @intCast(dest_x))];
                        dest_pixel.r = @intFromFloat(@as(f32, @floatFromInt(color.r)) * coverage + @as(f32, @floatFromInt(dest_pixel.r)) * (1.0 - coverage));
                        dest_pixel.g = @intFromFloat(@as(f32, @floatFromInt(color.g)) * coverage + @as(f32, @floatFromInt(dest_pixel.g)) * (1.0 - coverage));
                        dest_pixel.b = @intFromFloat(@as(f32, @floatFromInt(color.b)) * coverage + @as(f32, @floatFromInt(dest_pixel.b)) * (1.0 - coverage));
                    }
                }
            },
            ft.FT_PIXEL_MODE_MONO => {
                // 1-bit monochrome: 8 pixels per byte, MSB first.
                const bm_width: i32 = @intCast(bitmap.width);

                const start_x: i32 = @max(0, -x);
                const start_y: i32 = @max(0, -y);
                const end_x: i32 = @min(bm_width, self.width - x);
                const end_y: i32 = @min(bm_rows, self.height - y);
                if (start_x >= end_x or start_y >= end_y) return;

                for (@as(usize, @intCast(start_y))..@as(usize, @intCast(end_y))) |bm_row| {
                    const row_i: i32 = @intCast(bm_row);
                    const dest_y = y + row_i;
                    const src_row_offset: i32 = if (bm_pitch > 0) row_i * bm_pitch else (bm_rows - 1 - row_i) * (-bm_pitch);
                    const src_row: [*]const u8 = bm_buffer + @as(usize, @intCast(src_row_offset));
                    const dest_row: [*]Color = @ptrCast(@alignCast(self.memory + @as(usize, @intCast(dest_y * self.pitch))));

                    for (@as(usize, @intCast(start_x))..@as(usize, @intCast(end_x))) |bm_col| {
                        const dest_x = x + @as(i32, @intCast(bm_col));
                        const byte = src_row[bm_col / 8];
                        const bit: u3 = @intCast(7 - (bm_col % 8));
                        if ((byte >> bit) & 1 == 1) {
                            dest_row[@as(usize, @intCast(dest_x))] = color;
                        }
                    }
                }
            },
            else => {}, // unsupported pixel mode — skip silently
        }
    }
};
