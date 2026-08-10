const std = @import("std");
const types = @import("types.zig");

pub const DOM = struct {
    root: ?types.Node,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DOM {
        return DOM{
            .root = null,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *DOM, html: []const u8) !void {
        var parent_stack = try std.ArrayList(*types.ElementNode).initCapacity(self.allocator, 8);
        defer parent_stack.deinit(self.allocator);

        var i: usize = 0;
        while (i < html.len) {
            const c = html[i];
            if (c == '<') {
                var tag_start = i + 1;
                var is_end_tag = false;
                var is_doctype_tag = false;

                if (tag_start < html.len and html[tag_start] == '/') {
                    tag_start += 1;
                    is_end_tag = true;
                } else if (tag_start + 2 < html.len and html[tag_start] == '!' and html[tag_start + 1] == '-' and html[tag_start + 2] == '-') {
                    var comment_closed = false;
                    // skip comment content
                    while (i < html.len) {
                        i += 1;
                        if (i + 2 < html.len and html[i] == '-' and html[i + 1] == '-' and html[i + 2] == '>') {
                            i += 3; // skip '-->'
                            comment_closed = true;
                            break;
                        }
                    }

                    if (comment_closed) continue; // skip to next iteration after closing comment
                    if (i >= html.len) break; // EOF reached without closing comment
                } else if (tag_start + 8 <= html.len and html[tag_start] == '!' and
                    std.ascii.eqlIgnoreCase(html[tag_start .. tag_start + 8], "!doctype"))
                {
                    is_doctype_tag = true;
                }

                var active_quote: ?u8 = null;
                while (true) {
                    i += 1;
                    if (i >= html.len) break;

                    const current = html[i];
                    if (active_quote) |quote| {
                        if (current == quote) active_quote = null;
                    } else if (current == '"' or current == '\'') {
                        active_quote = current;
                    } else if (current == '>') {
                        break;
                    }
                }

                if (i >= html.len) break;

                var tag_end = i;
                const is_self_closing = i > 0 and html[i - 1] == '/';
                if (is_self_closing) tag_end -= 1;

                if (tag_end < html.len and tag_start < tag_end) {
                    const full_tag = html[tag_start..tag_end];
                    const space_index = std.mem.indexOf(u8, full_tag, " ") orelse full_tag.len;
                    const tag_name = full_tag[0..space_index];
                    const raw_attributes = full_tag[space_index..];
                    std.debug.print("Tag: {s}, Attributes: {s}\n", .{tag_name, raw_attributes});

                    var parsed_attributes: ?std.StringHashMap([]const u8) = null;
                    parsed_attributes = std.StringHashMap([]const u8).init(self.allocator);
                    // use two pointers to parse attributes
                    // set both to the start, then move the first pointer until it finds a space, 
                    // then move the second pointer until it finds a non-space character, then add the attribute to the map, then repeat
                    var attr_i: usize = 0;
                    var attr_start: usize = 0;
                    while (attr_i < raw_attributes.len) {
                        @breakpoint();

                        while (attr_i < raw_attributes.len and std.ascii.eqlIgnoreCase(raw_attributes[attr_i..attr_i + 1], " ")) {
                            attr_i += 1;
                        }
                        if (attr_i >= raw_attributes.len) break;
                        attr_start = attr_i;
                        while (attr_i < raw_attributes.len and !std.ascii.eqlIgnoreCase(raw_attributes[attr_i..attr_i + 1], " ")) {
                            attr_i += 1;
                        }
                        const attr_end = attr_i;
                        const attr_name = raw_attributes[attr_start..attr_end];
                        // split attribute by '=' if it exists, and store the name and value in the map
                        // if the character after the '=' is a quote, then the value is everything 
                        // until the next quote, otherwise it is everything until the next space
                        const equal_index = std.mem.indexOf(u8, attr_name, "=") orelse attr_name.len;

                        // test value: content="width=device-width, initial-scale=1"
                        const name = attr_name[0..equal_index];
                        var value: []const u8 = "";
                        if (equal_index < attr_name.len) {
                            const value_start = equal_index + 1;
                            if (value_start < attr_name.len) {
                                if (attr_name[value_start] == '"' or attr_name[value_start] == '\'') {
                                    const quote_char = attr_name[value_start];
                                    var value_end = value_start + 1;
                                    while (value_end < attr_name.len and attr_name[value_end] != quote_char) {
                                        value_end += 1;
                                    }
                                    value = attr_name[value_start + 1..value_end];
                                } else {
                                    var value_end = value_start;
                                    while (value_end < attr_name.len and !std.ascii.eqlIgnoreCase(attr_name[value_end..value_end + 1], " ")) {
                                        value_end += 1;
                                    }
                                    value = attr_name[value_start..value_end];
                                }
                            }
                        }

                        try parsed_attributes.?.put(name, value);
                        std.debug.print("Parsed attribute: {s}:{s}\n", .{name, value});
                    }


                    if (is_end_tag) {
                        if (parent_stack.items.len > 0) {
                            // check the tag name matches the last opened tag
                            const last_opened = parent_stack.items[parent_stack.items.len - 1];
                            if (std.ascii.eqlIgnoreCase(last_opened.tag_name, tag_name)) {
                                _ = parent_stack.pop();
                            } else {
                                // Mismatched closing tag, ignore or handle as needed
                            }
                        }
                    } else if (is_doctype_tag) {
                        // skip
                    } else {
                        const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" };
                        const is_void = for (void_elements) |v| {
                            if (std.ascii.eqlIgnoreCase(tag_name, v)) break true;
                        } else false;

                        const children = try std.ArrayList(types.Node).initCapacity(self.allocator, 4);
                        const el_ptr = try self.allocator.create(types.ElementNode);
                        el_ptr.* = types.ElementNode{
                            .tag_name = tag_name,
                            .raw_attributes = raw_attributes,
                            .parsed_attributes = null,
                            .children = children,
                        };

                        // Add to current parent
                        if (parent_stack.items.len > 0) {
                            try parent_stack.items[parent_stack.items.len - 1].children.append(self.allocator, types.Node{ .Element = el_ptr });
                        }

                        // Push to stack if not void
                        if (!is_void) {
                            try parent_stack.append(self.allocator, el_ptr);
                        }

                        // Set root if first
                        if (self.root == null) {
                            self.root = types.Node{ .Element = el_ptr };
                        }
                    }
                }

                i += 1;
            } else {
                const text_start = i;
                while (i < html.len and html[i] != '<') {
                    i += 1;
                }
                const text_end = i;
                if (text_end > text_start and parent_stack.items.len > 0) {
                    const text_content = html[text_start..text_end];
                    const txt_ptr = try self.allocator.create(types.TextNode);
                    txt_ptr.* = types.TextNode{ .content = text_content };
                    try parent_stack.items[parent_stack.items.len - 1].children.append(self.allocator, types.Node{ .Text = txt_ptr });
                }
            }
        }

        //if (self.root) |root| {
        //    dump(root, 0);
        //}
    }

    // just for debugging purposes
    pub fn dump(node: types.Node, indent: usize) void {
        for (0..indent) |_| std.debug.print(" ", .{});
        switch (node) {
            .Element => |el| {
                std.debug.print("<{s}> ({d} kids)\n", .{ el.tag_name, el.children.items.len });
                for (el.children.items) |child| dump(child, indent + 1);
            },
            .Text => |tx| {
                if (tx.content.len > 0) std.debug.print("txt: {s}\n", .{tx.content});
            },
        }
    }
};
