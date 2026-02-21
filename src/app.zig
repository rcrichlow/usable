const std = @import("std");
const c = @cImport({
    @cInclude("freetype2/ft2build.h");
    @cInclude("freetype2/freetype/freetype.h");
    @cInclude("freetype2/freetype/ftlcdfil.h");
});

var global_ft_library: c.FT_Library = undefined;
var ft_face: c.FT_Face = undefined;
var ft_initialized = false;

// trying not to overthink this at the moment.
// should probably switch to an allocator-based approach at some point, 
// but for now just hardcode some fixed-size buffers.
pub const AppMemory = struct {
    ft_is_initialized: bool,

    // a chunk of memory for things that should persist 
    // across frames (e.g. font atlas, cached glyph bitmaps, etc)
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

/// Software framebuffer the platform allocates and the game draws into.
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

    /// Draw a FreeType bitmap into the buffer
    pub fn drawFTBitmap(
        self: *OffscreenBuffer,
        bitmap: *const c.FT_Bitmap,
        x: i32,
        y: i32,
        color: Color,
    ) void {
        const bm_width: i32 = @intCast(bitmap.width / 3);
        const bm_rows: i32 = @intCast(bitmap.rows);
        const bm_pitch: i32 = bitmap.pitch;

        const bm_buffer: [*]const u8 = bitmap.buffer orelse return;

        const start_x: i32 = @max(0, -x);
        const start_y: i32 = @max(0, -y);
        const end_x: i32 = @min(bm_width, self.width - x);
        const end_y: i32 = @min(bm_rows, self.height - y);

        if (start_x >= end_x or start_y >= end_y) return;

        for (@as(usize, @intCast(start_y))..@as(usize, @intCast(end_y))) |bm_row| {
            const row_i: i32 = @intCast(bm_row);
            const dest_y = y + row_i;

            const src_row_offset: i32 = if (bm_pitch > 0) row_i * bm_pitch else (bm_rows - 1 - row_i) * bm_pitch;
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
    }
};

pub fn init(memory: *AppMemory) !void {
    std.debug.print("Initializing FreeType...\n", .{});

    if (c.FT_Init_FreeType(&global_ft_library) != 0) {
        std.debug.print("Failed to initialize FreeType\n", .{});
        return error.FreeTypeInitFailed;
    }

    if (c.FT_New_Face(global_ft_library, "/usr/share/fonts/noto/NotoSans-Regular.ttf", 0, &ft_face) != 0) {
        std.debug.print("Failed to load font ft_face\n", .{});
        return error.FontLoadFailed;
    }

    if (c.FT_Library_SetLcdFilter(global_ft_library, c.FT_LCD_FILTER_DEFAULT) != 0) {
        std.debug.print("Failed to set LCD filter\n", .{});
        return error.LcdFilterFailed;
    }

    if (c.FT_Set_Char_Size(ft_face, 0, 16 * 64, 0, 0) != 0) {
        std.debug.print("Failed to set char size\n", .{});
        return error.FontSizeFailed;
    }

    std.debug.print("family name: {s}\n", .{ft_face.*.family_name});

    memory.ft_is_initialized = true;
}

pub fn start() !void {
    fetchUrl("http://example.com") catch |err| {
        std.debug.print("Failed to fetch URL: {any}\n", .{err});
    };
}

pub fn updateAndRender(memory: *AppMemory, buffer: *OffscreenBuffer) void {
    if (memory.ft_is_initialized == false) {
        _ = init(memory) catch |err| {
            std.debug.print("FreeType initialization error: {any}\n", .{err});
            return;
        };
    }

    const slot: c.FT_GlyphSlot = ft_face.*.glyph;
    var draw_x: i32 = 10;
    const text = "Hello, FreeType!";
    for (text) |char| {
        const char_index = c.FT_Get_Char_Index(ft_face, char);
        if (c.FT_Load_Glyph(ft_face, char_index, c.FT_LOAD_DEFAULT) != 0) {
            std.debug.print("Failed to load glyph for '{c}'\n", .{char});
            continue;
        }

        if (c.FT_Render_Glyph(slot, c.FT_RENDER_MODE_LCD) != 0) {
            std.debug.print("Failed to render glyph for '{c}'\n", .{char});
            continue;
        }

        buffer.drawFTBitmap(&slot.*.bitmap, draw_x + slot.*.bitmap_left, 50 - slot.*.bitmap_top, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
        draw_x += @intCast(slot.*.advance.x >> 6);
    }
}

fn fetchUrl(url: []const u8) !void {
    const allocator = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body_list: std.ArrayListUnmanaged(u8) = .empty;
    defer body_list.deinit(allocator);
    var body_writer: std.Io.Writer.Allocating = .fromArrayList(allocator, &body_list);
    defer body_writer.deinit();
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{
            .{ .name = "accept", .value = "*/*" },
        },
        .response_writer = &body_writer.writer,
    });

    std.debug.print("Status: {d}\n", .{result.status});
    const body = try body_writer.toOwnedSlice();
    defer allocator.free(body);
    std.debug.print("Body: {s}\n", .{body});
}
