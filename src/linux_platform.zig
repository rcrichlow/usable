const std = @import("std");
const c = @cImport({
    @cInclude("X11/Xlib.h");
});
const app = @import("app.zig");

pub fn main() !void {
    const display = c.XOpenDisplay(null);
    if (display == null) {
        std.debug.print("Failed to open X display\n", .{});
        return;
    }
    defer _ = c.XCloseDisplay(display);

    const screen = c.XDefaultScreen(display);
    const root_window = c.XRootWindow(display, screen);
    const visual = c.XDefaultVisual(display, screen);
    const depth = c.XDefaultDepth(display, screen);

    var attrs: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    attrs.background_pixel = 0xffffff; // white background
    attrs.event_mask = c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask | c.KeyReleaseMask;

    const window = c.XCreateWindow(
        display,
        root_window,
        0, 0, 800, 600,
        0,
        depth,
        c.InputOutput,
        visual,
        c.CWBackPixel | c.CWEventMask,
        &attrs,
    );

    defer _ = c.XDestroyWindow(display, window);

    _ = c.XStoreName(display, window, "Usable Browser");
    _ = c.XMapWindow(display, window);

    var running = true;
    while (running) {
        var event: c.XEvent = std.mem.zeroes(c.XEvent);
        _ = c.XNextEvent(display, &event);

        switch (event.type) {
            c.Expose => {
                // Redraw the window if needed
            },
            c.KeyPress => {
                const keycode = event.xkey.keycode;
                std.debug.print("Key pressed: {d}\n", .{keycode});
                if (keycode == 36) { // Enter key
                    app.start() catch |err| {
                        std.debug.print("Application error: {any}\n", .{err});
                    };

                }
                if (keycode == 9) { // Escape key
                    running = false;
                }
            },
            c.ConfigureNotify => {
                const width = event.xconfigure.width;
                const height = event.xconfigure.height;
                std.debug.print("Window resized: {d}x{d}\n", .{width, height});
            },
            else => {},
        }
    }

}
