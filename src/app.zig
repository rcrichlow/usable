const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");
const c = @import("c_imports.zig");
const ft = c.ft;

pub fn init(memory: *types.AppMemory) !void {
    std.debug.print("Initializing FreeType...\n", .{});

    var library: ft.FT_Library = undefined;
    var face: ft.FT_Face = undefined;

    if (ft.FT_Init_FreeType(&library) != 0) {
        std.debug.print("Failed to initialize FreeType\n", .{});
        return error.FreeTypeInitFailed;
    }

    memory.ft_library = library;

    const font_path = switch (@import("builtin").target.os.tag) {
        .windows => "C:\\Windows\\Fonts\\arial.ttf",
        else => "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    };
    std.debug.print("Loading font: {s}\n", .{font_path});

    if (ft.FT_New_Face(memory.ft_library.?, font_path, 0, &face) != 0) {
        std.debug.print("Failed to load font ft_face\n", .{});
        return error.FontLoadFailed;
    }

    memory.ft_face = face;

    if (ft.FT_Library_SetLcdFilter(memory.ft_library.?, ft.FT_LCD_FILTER_DEFAULT) != 0) {
        std.debug.print("Failed to set LCD filter\n", .{});
        return error.LcdFilterFailed;
    }

    if (ft.FT_Set_Char_Size(memory.ft_face.?, 0, 16 * 64, 0, 0) != 0) {
        std.debug.print("Failed to set char size\n", .{});
        return error.FontSizeFailed;
    }

    std.debug.print("family name: {s}\n", .{memory.ft_face.?.*.family_name});

    memory.ft_is_initialized = true;
}

/// Start navigating to a URL. Sets state to Loading and begins the fetch.
/// The actual fetch happens synchronously for now - will make async later.
pub fn navigate(memory: *types.AppMemory, buffer: *types.OffscreenBuffer, url: []const u8) void {
    // Reset arena to free all previous allocations
    _ = memory.arena.reset(.retain_capacity);

    std.debug.print("navigating to: {s}\n", .{url});
    const url_copy = memory.arena.allocator().dupe(u8, url) catch {
        memory.browser_state = .Error;
        memory.error_message = memory.arena.allocator().dupe(u8, "Out of memory") catch &.{};
        return;
    };

    memory.current_url = url_copy;
    memory.browser_state = .Loading;
    memory.error_message = &.{};

    const response_body = fetchUrl(&memory.arena, url) catch |err| {
        memory.browser_state = .Error;
        memory.error_message = memory.arena.allocator().dupe(u8, "Failed to fetch URL") catch &.{};
        std.debug.print("Fetch error: {any}\n", .{err});
        return;
    };

    memory.response_body = response_body;
    var DOM = dom.DOM.init(memory.arena.allocator());
    DOM.parse(response_body) catch |err| {
        std.debug.print("Parse error: {any}\n", .{err});
        return;
    };

    memory.dom_tree = DOM.root;
    memory.layout_tree = layout.buildLayoutTree(&memory.dom_tree.?, memory.arena.allocator());

    // TODO: don't initialize like this. probably want to set up the main window differently - rcrichlow - 3/3/26
    var window_dimensions = std.mem.zeroes(types.Dimensions);
    window_dimensions.content.width = @floatFromInt(buffer.width);
    window_dimensions.content.height = @floatFromInt(buffer.height);

    std.debug.print("buffer width: {d}\n", .{buffer.width});
    std.debug.print("window width: {d}\n", .{window_dimensions.content.width});
    layout.layout(memory, memory.layout_tree.?, window_dimensions, 40);
    //std.debug.print("layout_tree: {any}\n", .{memory.layout_tree});
    memory.browser_state = .Loaded;
}

fn paint(memory: *types.AppMemory, buffer: *types.OffscreenBuffer, box: *types.LayoutBox) void {
    if (box.node) |node| {
        switch (node) {
            .Element => {
                if (box.children) |children| {
                    for (children.items) |child| paint(memory, buffer, child);
                }
            },
            .Text => |tx| {
                if (tx.content.len > 0) {
                    //const x = box.dimensions.content.x;
                    //const y = box.dimensions.content.y;
                    // trim text before drawing to avoid rendering whitespace-only text nodes
                    // TODO: ideally we would trim the text during layout and not create boxes for 
                    // whitespace-only text nodes at all, but this is a quick fix for now - rcrichlow - 3/19/26
                    //drawText(memory, buffer, std.mem.trim(u8, tx.content, " \t\n\r"), @intFromFloat(x), @intFromFloat(y));

                    // not going to trim here for now since we're going to normalize whitespace during 
                    // layout and not create boxes for whitespace-only text nodes
                    //drawText(memory, buffer, tx.content, @intFromFloat(x), @intFromFloat(y));
                    
                    if (box.fragments) |fragments| {
                        for (fragments.items) |fragment| {
                            drawText(memory, buffer, fragment.content, @intFromFloat(fragment.x), @intFromFloat(fragment.y));
                        }
                    }
                }
            },
        }
    } else {
        // Anonymous box — no node, just paint children
        if (box.children) |children| {
            for (children.items) |child| paint(memory, buffer, child);
        }
    }
}

/// Draw text at the given position using the loaded font.
/// The y parameter represents the top of the text line, not the baseline.
fn drawText(memory: *types.AppMemory, buffer: *types.OffscreenBuffer, text: []const u8, x: i32, y: i32) void {
    const face = memory.ft_face.?;
    const slot: ft.FT_GlyphSlot = face.*.glyph;
    const ascender: i32 = @intCast(face.*.size.*.metrics.ascender >> 6);
    var draw_x = x;
    const baseline_y = y + ascender;
    for (text) |char| {
        const char_index = ft.FT_Get_Char_Index(memory.ft_face.?, char);
        if (ft.FT_Load_Glyph(memory.ft_face.?, char_index, ft.FT_LOAD_DEFAULT) != 0) {
            continue;
        }

        if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_LCD) != 0) {
            continue;
        }

        buffer.drawFTBitmap(&slot.*.bitmap, draw_x + slot.*.bitmap_left, baseline_y - slot.*.bitmap_top, memory.text_color);
        draw_x += @intCast(slot.*.advance.x >> 6);
    }
}

/// Render the current browser state to the buffer
fn render(memory: *types.AppMemory, buffer: *types.OffscreenBuffer) void {
    buffer.clear(memory.background_color);

    switch (memory.browser_state) {
        .Idle => {
            // Draw URL bar or instructions
            drawText(memory, buffer, "Press F5 to load example.com", 10, 10);
        },
        .Loading => {
            drawText(memory, buffer, "Loading...", 10, 30);
        },
        .Loaded => {
            // temporary address bar
            drawText(memory, buffer, memory.current_url, 10, 10);

            // the actual DOM layout tree
            paint(memory, buffer, memory.layout_tree.?);
        },
        .Error => {
            drawText(memory, buffer, "Error:", 10, 30);
            drawText(memory, buffer, memory.error_message, 10, 60);
        },
    }
}

pub fn updateAndRender(memory: *types.AppMemory, buffer: *types.OffscreenBuffer) void {
    if (memory.ft_is_initialized == false) {
        _ = init(memory) catch |err| {
            std.debug.print("FreeType initialization error: {any}\n", .{err});
            return;
        };

        memory.browser_state = .Idle;
    }

    render(memory, buffer);
}

fn fetchUrl(arena: *std.heap.ArenaAllocator, url: []const u8) ![]u8 {
    const http_allocator = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = http_allocator };
    defer client.deinit();

    const allocator = arena.allocator();
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
    std.debug.print("Body: {s}\n", .{body});

    return body;
}
