const std = @import("std");
const types = @import("types.zig");
const c = @import("c_imports.zig");
const ft = c.ft;

pub fn buildLayoutTree(node: *const types.Node, allocator: std.mem.Allocator) ?*types.LayoutBox {
    const non_visual = [_][]const u8{ "head", "style", "script", "title", "meta", "link" };
    const block = [_][]const u8{
        "html","body","div", "p","h1","h2","h3","h4","h5","h6", "ul", "ol", "li", "section", "article",
        "header","footer","main", "nav", "form", "table","blockquote", "pre", "hr",
    };

    var layout_box: ?*types.LayoutBox = null;
    const dimensions: types.Dimensions = .{
        .content = .{ .width = 0, .height = 0, .x = 0, .y = 0 },
        .border = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
        .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
        .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
    };

    switch (node.*) {
        .Element => |el| {
            // TODO: the way we name this, plus the negation below seems like it might be confusing. revisist. - rcrichlow - 3/2/26
            const is_non_visual = for (non_visual) |v| {
                if (std.mem.eql(u8, el.tag_name, v)) break true;
            } else false;

            if (is_non_visual) {
                return null;
            }

            layout_box = allocator.create(types.LayoutBox) catch |err| {
                std.debug.print("error allocating layout box memory: {any}\n", .{err});
                return layout_box;
            };

            const children = std.ArrayList(*types.LayoutBox).initCapacity(allocator, 4) catch |err| {
                std.debug.print("error allocating layout box children: {any}\n", .{err});
                return layout_box;
            };

            layout_box.?.* = types.LayoutBox{
                .box_type = .Inline,
                .node = node.*,
                .dimensions = dimensions,
                .children = children,
                .fragments = null,
            };

            // TODO: handle mixed content for block boxes with inline and block children - rcrichlow - 3/2/26
            //std.debug.print("handling {s}\n", .{el.tag_name});

            layout_box.?.box_type = for (block) |b| {
                if (std.mem.eql(u8, el.tag_name, b)) break .Block;
            } else .Inline;

            std.debug.print("tag: {s}, box_type: {any}\n", .{ el.tag_name, layout_box.?.box_type });

            for (el.children.items) |child| {
                const built_child = buildLayoutTree(&child, allocator);
                if (built_child != null) {
                    layout_box.?.children.append(allocator, built_child.?) catch |err| {
                        std.debug.print("error adding layout box: {any}\n", .{err});
                    };
                }
            }
        },
        .Text => |txt| {
            // trim whitespace-only text nodes
            if (std.mem.trim(u8, txt.content, " \t\n\r").len == 0) {
                return null;
            }

            layout_box = allocator.create(types.LayoutBox) catch |err| {
                std.debug.print("error allocating layout box memory: {any}\n", .{err});
                return layout_box;
            };

            layout_box.?.* = types.LayoutBox{
                .box_type = .Inline,
                .node = node.*,
                .dimensions = dimensions,
                .fragments = null,
                .children = std.ArrayList(*types.LayoutBox).initCapacity(allocator, 0) catch |err| {
                    std.debug.print("error allocating text layout box children: {any}\n", .{err});
                    return layout_box;
                },
            };

            return layout_box;
        },
    }

    // check if we need anonymous blocks
    if (layout_box != null and layout_box.?.box_type == .Block and layout_box.?.children.items.len > 0) {
        var block_types_found: [2]bool = .{ false, false }; // inline,block
        for (layout_box.?.children.items) |box| {
            if (box.box_type == .Inline and block_types_found[0] == false) {
                block_types_found[0] = true;
            }

            if (box.box_type == .Block and block_types_found[1] == false) {
                block_types_found[1] = true;
            }

            if (block_types_found[0] == true and block_types_found[1] == true) {
                break;
            }
        }

        if (block_types_found[0] and block_types_found[1]) {
            var new_children = std.ArrayList(*types.LayoutBox).initCapacity(allocator, 4) catch |err| {
                std.debug.print("error allocating layout box children: {any}\n", .{err});
                return layout_box;
            };

            var current_anon: ?*types.LayoutBox = null;
            for (layout_box.?.children.items) |box| {
                if (box.box_type == .Block) {
                    // finalize any in-progress anonymous block
                    if (current_anon) |anon| {
                        new_children.append(allocator, anon) catch |err| {
                            std.debug.print("error adding layout box: {any}\n", .{err});
                        };
                        current_anon = null;
                    }
                    // block children go directly into new_children
                    new_children.append(allocator, box) catch |err| {
                        std.debug.print("error adding layout box: {any}\n", .{err});
                    };
                } else {
                    // create anonymous block if we don't have one
                    if (current_anon == null) {
                        current_anon = allocator.create(types.LayoutBox) catch |err| {
                            std.debug.print("error allocating layout box memory: {any}\n", .{err});
                            return layout_box;
                        };
                        current_anon.?.* = types.LayoutBox{
                            .box_type = .Anonymous,
                            .node = null,
                            .fragments = null,
                            .dimensions = .{
                                .content = .{ .width = 0, .height = 0, .x = 0, .y = 0 },
                                .border = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
                                .margin = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
                                .padding = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 },
                            },
                            .children = std.ArrayList(*types.LayoutBox).initCapacity(allocator, 4) catch |err| {
                                std.debug.print("error allocating layout box children: {any}\n", .{err});
                                return layout_box;
                            },
                        };
                    }
                    current_anon.?.children.append(allocator, box) catch |err| {
                        std.debug.print("error adding layout box: {any}\n", .{err});
                    };
                }
            }

            // finalize trailing anonymous block
            if (current_anon) |anon| {
                new_children.append(allocator, anon) catch |err| {
                    std.debug.print("error adding layout box: {any}\n", .{err});
                };
            }

            layout_box.?.children = new_children;
        }
    }

    return layout_box;
}

// generate fragments from text. tokenize words on whitespace.
// TODO: there is probably a more efficient way to do this, eg. ranges or a tokenzer or something - rcrichlow 3/23/26
fn parseWords(text: []const u8, allocator: std.mem.Allocator) []const []const u8 {
    var words = std.ArrayList([]const u8).initCapacity(allocator, 4) catch |err| {
        std.debug.print("error allocating words: {any}\n", .{err});
        return &[_][]const u8{};
    };

    var i: usize = 0;
    while (i < text.len) {
        const char = text[i];
        if (char == ' ' or char == '\n' or char == '\r' or char == '\t') {
            i += 1;
            continue;
        }

        const word_start = i;
        while (i < text.len and text[i] != ' ' and text[i] != '\n' and text[i] != '\r' and text[i] != '\t') {
            i += 1;
        }

        const word_end = i;
        if (word_end > word_start) {
            const word = text[word_start..word_end];

            words.append(allocator, word) catch |err| {
                std.debug.print("error adding word: {any}\n", .{err});
                return &[_][]const u8{};
            };
        }
    }

    return words.toOwnedSlice(allocator) catch |err| {
        std.debug.print("error converting words to owned slice: {any}\n", .{err});
        return &[_][]const u8{};
    };
}

pub fn layout(memory: *types.AppMemory, layout_box: *types.LayoutBox, containing_block: types.Dimensions, y_offset: f32) void {
    switch (layout_box.*.box_type) {
        .Block => {
            const horizontal_margins = layout_box.dimensions.margin.left + layout_box.dimensions.margin.right;
            const horizontal_padding = layout_box.dimensions.padding.left + layout_box.dimensions.padding.right;
            const horizontal_borders = layout_box.dimensions.border.left + layout_box.dimensions.border.right;
            layout_box.dimensions.content.width = containing_block.content.width - horizontal_borders -
                horizontal_margins - horizontal_padding;
            layout_box.dimensions.content.x = containing_block.content.x + layout_box.dimensions.margin.left +
                layout_box.dimensions.padding.left + layout_box.dimensions.border.left;
            layout_box.dimensions.content.y = containing_block.content.y + y_offset + layout_box.dimensions.margin.top;
                std.debug.print("layout_box content width: {d}\n", .{layout_box.dimensions.content.width});

            var child_y_offset: f32 = 0;
            for (layout_box.children.items) |child| {
                layout(memory, child, layout_box.dimensions, child_y_offset);
                child_y_offset += child.dimensions.marginBox().height;
            }

            layout_box.dimensions.content.height = child_y_offset;
        },
        .Inline => {
            if (layout_box.node.? == .Text) {
                const txt = layout_box.node.?.Text;
                const words = parseWords(txt.content, memory.arena.allocator());
                if (words.len == 0) {
                    return;
                }

                layout_box.fragments = std.ArrayList(types.TextFragment).initCapacity(memory.arena.allocator(), words.len) catch |err| {
                    std.debug.print("error allocating fragments: {any}\n", .{err});
                    return;
                };

                std.debug.print("content: '{s}'\n", .{txt.content});
                var cursor_x: f32 = containing_block.content.x;
                var line_y: f32 = containing_block.content.y;
                var line_height: f32 = 0;
                var widest_line: f32 = 0;
                var height: f32 = 0;

                layout_box.dimensions.content.x = cursor_x;
                layout_box.dimensions.content.y = line_y;
                std.debug.print("containing block dims: {any}\n", .{containing_block.content});
                for (words) |word| {
                    var fragment: types.TextFragment = undefined;

                    const dims = measureText(memory.ft_face, word);
                    if (cursor_x + dims.width > containing_block.content.width) {
                        cursor_x = containing_block.content.x;
                        line_y += line_height;
                        height += line_height;
                        line_height = dims.height;
                    } else {
                        line_height = @max(line_height, dims.height);
                        if (cursor_x != containing_block.content.x) {
                            cursor_x += measureText(memory.ft_face, " ").width;
                        }
                    }

                    fragment = .{
                        .content = word,
                        .x = cursor_x,
                        .y = line_y,
                        .width = dims.width,
                        .ascent = dims.ascent,
                        .descent = dims.descent,
                    };

                    cursor_x += dims.width;
                    widest_line = @max(widest_line, cursor_x);

                    std.debug.print("word: '{s}'\n", .{word});
                    std.debug.print("fragment: '{any}'\n", .{fragment});

                    layout_box.fragments.?.append(memory.arena.allocator(), fragment) catch |err| {
                        std.debug.print("error adding fragment: {any}\n", .{err});
                    };
                }

                //const box = measureText(memory.ft_face, layout_box.node.?.Text.content);
                //std.debug.print("box dimensions: {any}\n", .{box});

                layout_box.dimensions.content.height = height + line_height;
                layout_box.dimensions.content.width = widest_line;
            } else {
                layout_box.dimensions.content.x = containing_block.content.x;
                layout_box.dimensions.content.y = containing_block.content.y + y_offset;
                layout_box.dimensions.content.width = containing_block.content.width;
                std.debug.print("layout_box content width: {d}\n", .{layout_box.dimensions.content.width});

                var child_y_offset: f32 = 0;
                for (layout_box.children.items) |child| {
                    layout(memory, child, layout_box.dimensions, child_y_offset);
                    child_y_offset += child.dimensions.marginBox().height;
                }
                layout_box.dimensions.content.height = child_y_offset;
            }
        },
        .Anonymous => {
            // Anonymous blocks lay out the same as regular blocks
            const horizontal_margins = layout_box.dimensions.margin.left + layout_box.dimensions.margin.right;
            const horizontal_padding = layout_box.dimensions.padding.left + layout_box.dimensions.padding.right;
            const horizontal_borders = layout_box.dimensions.border.left + layout_box.dimensions.border.right;
            layout_box.dimensions.content.width = containing_block.content.width - horizontal_borders - horizontal_margins - horizontal_padding;
            layout_box.dimensions.content.x = containing_block.content.x + layout_box.dimensions.margin.left +
                layout_box.dimensions.padding.left + layout_box.dimensions.border.left;
            layout_box.dimensions.content.y = containing_block.content.y + y_offset + layout_box.dimensions.margin.top;
                std.debug.print("layout_box content width: {d}\n", .{layout_box.dimensions.content.width});

            var child_y_offset: f32 = 0;
            for (layout_box.children.items) |child| {
                std.debug.print("child type: {any}\n", .{child.box_type});
                layout(memory, child, layout_box.dimensions, child_y_offset);
                child_y_offset += child.dimensions.marginBox().height;
            }

            layout_box.dimensions.content.height = child_y_offset;
        },
    }
}

//fn generateFragment(face: ft.FT_Face, text: []const u8) types.TextFragment {
//    const dims = measureText(face, text);
//
//    return .{
//        .content = text,
//        .x = 0,
//        .y = 0,
//        .width = dims.width,
//        .ascent = dims.ascent,
//        .descent = dims.descent,
//    };
//}

const LineBox = struct {
    width: f32,
    height: f32,
    ascent: f32,
    descent: f32,
};

pub fn measureText(face: ft.FT_Face, text: []const u8) LineBox {
    const slot: ft.FT_GlyphSlot = face.*.glyph;
    var width: u32 = 0;
    var ascent: u32 = 0;
    var descent: u32 = 0;

    for (text) |char| {
        const char_index = ft.FT_Get_Char_Index(face.?, char);
        if (ft.FT_Load_Glyph(face.?, char_index, ft.FT_LOAD_DEFAULT) != 0) {
            continue;
        }

        width += @intCast(slot.*.advance.x >> 6);

        const char_ascent: u32 = @intCast(slot.*.metrics.horiBearingY >> 6);
        if (char_ascent > ascent) {
            ascent = char_ascent;
        }

        const char_height: u32 = @intCast(slot.*.metrics.height >> 6);
        const char_descent: u32 = char_height - char_ascent;
        if (char_descent > descent) {
            descent = char_descent;
        }
    }

    const height: u32 = ascent + descent;

    return .{
        .height = @floatFromInt(height),
        .width = @floatFromInt(width),
        .ascent = @floatFromInt(ascent),
        .descent = @floatFromInt(descent),
    };
}
