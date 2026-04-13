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

    const font_path = switch (@import("builtin").target.os.tag) {
        .windows => "C:\\Windows\\Fonts\\arial.ttf",
        else => "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    };
    std.debug.print("Loading font: {s}\n", .{font_path});

    if (ft.FT_New_Face(library, font_path, 0, &face) != 0) {
        std.debug.print("Failed to load font ft_face\n", .{});
        _ = ft.FT_Done_FreeType(library);
        return error.FontLoadFailed;
    }

    if (ft.FT_Library_SetLcdFilter(library, ft.FT_LCD_FILTER_DEFAULT) != 0) {
        std.debug.print("Failed to set LCD filter\n", .{});
        _ = ft.FT_Done_Face(face);
        _ = ft.FT_Done_FreeType(library);
        return error.LcdFilterFailed;
    }

    if (ft.FT_Set_Char_Size(face, 0, 16 * 64, 0, 0) != 0) {
        std.debug.print("Failed to set char size\n", .{});
        _ = ft.FT_Done_Face(face);
        _ = ft.FT_Done_FreeType(library);
        return error.FontSizeFailed;
    }

    std.debug.print("family name: {s}\n", .{face.*.family_name});

    memory.ft_library = library;
    memory.ft_face = face;
    memory.ft_is_initialized = true;
}

fn resetPersistentState(memory: *types.AppMemory) void {
    _ = memory.persistent_arena.reset(.retain_capacity);
    memory.dom_tree = null;
    memory.response_body = &.{};
    memory.current_url = &.{};
    memory.error_message = &.{};
}

fn resetTransientState(memory: *types.AppMemory) void {
    _ = memory.transient_arena.reset(.retain_capacity);
    memory.layout_tree = null;
}

pub fn reflow(memory: *types.AppMemory, buffer: *types.OffscreenBuffer) void {
    if (memory.dom_tree == null) {
        memory.browser_state = .Error;
        memory.error_message = memory.persistent_arena.allocator().dupe(u8, "Missing DOM tree") catch &.{};
        return;
    }

    resetTransientState(memory);

    memory.layout_tree = layout.buildLayoutTree(&memory.dom_tree.?, memory.transient_arena.allocator());
    if (memory.layout_tree == null) {
        memory.browser_state = .Error;
        memory.error_message = memory.persistent_arena.allocator().dupe(u8, "Failed to build layout tree.") catch &.{};
        std.debug.print("Failed to build layout tree.\n", .{});
        return;
    }

    var window_dimensions = std.mem.zeroes(types.Dimensions);
    window_dimensions.content.width = @floatFromInt(buffer.width);
    window_dimensions.content.height = @floatFromInt(buffer.height);

    std.debug.print("buffer width: {d}\n", .{buffer.width});
    std.debug.print("window width: {d}\n", .{window_dimensions.content.width});
    layout.layout(memory, memory.layout_tree.?, window_dimensions, 40);
}

/// Start navigating to a URL. Sets state to Loading and begins the fetch.
/// The actual fetch happens synchronously for now - will make async later.
pub fn navigate(memory: *types.AppMemory, buffer: *types.OffscreenBuffer, url: []const u8) void {
    // Copy the url onto the stack before resetting the arena, so that a caller
    // passing memory.current_url (which is arena-backed) doesn't get a dangling
    // pointer after the reset.
    var url_buf: [4096]u8 = undefined;
    const safe_url = if (url.len <= url_buf.len) blk: {
        @memcpy(url_buf[0..url.len], url);
        break :blk url_buf[0..url.len];
    } else url; // url is too long to stack-copy; caller must ensure it's not arena-backed

    // Reset both page-lifetime and reflow-lifetime state before loading.
    resetPersistentState(memory);
    resetTransientState(memory);

    std.debug.print("navigating to: {s}\n", .{safe_url});
    const url_copy = memory.persistent_arena.allocator().dupe(u8, safe_url) catch {
        memory.browser_state = .Error;
        memory.error_message = memory.persistent_arena.allocator().dupe(u8, "Out of memory") catch &.{};
        return;
    };

    memory.current_url = url_copy;
    memory.browser_state = .Loading;
    memory.error_message = &.{};

    const response_body = fetchUrl(&memory.persistent_arena, safe_url) catch |err| {
        memory.browser_state = .Error;
        memory.error_message = memory.persistent_arena.allocator().dupe(u8, "Failed to fetch URL") catch &.{};
        std.debug.print("Fetch error: {any}\n", .{err});
        return;
    };

    memory.response_body = response_body;
    var DOM = dom.DOM.init(memory.persistent_arena.allocator());
    DOM.parse(response_body) catch |err| {
        memory.browser_state = .Error;
        memory.error_message = memory.persistent_arena.allocator().dupe(u8, "Parse error") catch &.{};
        std.debug.print("Parse error: {any}\n", .{err});
        return;
    };

    memory.dom_tree = DOM.root;
    if (memory.dom_tree == null) {
        // TODO: should probably handle this a bit more gracefully, but it's better than a panic - rcrichlow - 3/25/26
        memory.browser_state = .Error;
        memory.error_message = memory.persistent_arena.allocator().dupe(u8, "Failed to build DOM tree.") catch &.{};
        std.debug.print("Failed to build DOM tree.\n", .{});
        return;
    }

    reflow(memory, buffer);
    if (memory.layout_tree == null) return;

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
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        const char_index = ft.FT_Get_Char_Index(memory.ft_face.?, codepoint);
        if (ft.FT_Load_Glyph(memory.ft_face.?, char_index, ft.FT_LOAD_DEFAULT) != 0) {
            continue;
        }

        if (ft.FT_Render_Glyph(slot, ft.FT_RENDER_MODE_LCD) != 0) {
            continue;
        }

        buffer.drawFTBitmap(&slot.*.bitmap, draw_x + slot.*.bitmap_left, baseline_y - slot.*.bitmap_top, memory.text_color);
        const adv: i32 = @intCast(slot.*.advance.x >> 6);
        if (adv > 0) draw_x += adv;
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
            if (memory.layout_tree) |layout_tree| {
                paint(memory, buffer, layout_tree);
            }
        },
        .Error => {
            // TODO: gracefully handle errors instead of just dumping text to the screen - rcrichlow - 4/3/26
            drawText(memory, buffer, "Error:", 10, 30);
            drawText(memory, buffer, memory.error_message, 10, 60);
        },
    }
}

pub fn updateAndRender(memory: *types.AppMemory, buffer: *types.OffscreenBuffer) void {
    if (!memory.ft_is_initialized and !memory.ft_init_failed) {
        init(memory) catch |err| {
            std.debug.print("FreeType initialization error: {any}\n", .{err});
            memory.ft_init_failed = true;
            return;
        };

        memory.browser_state = .Idle;
    }

    if (memory.ft_init_failed) return;

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
