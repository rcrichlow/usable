const std = @import("std");

pub fn start() !void {
    fetchUrl("http://example.com") catch |err| {
        std.debug.print("Failed to fetch URL: {any}\n", .{err});
    };
}

fn fetchUrl(url: []const u8) !void {
    const allocator = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Set up a writer to capture the response body
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
