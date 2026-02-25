const std = @import("std");
const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("sys/shm.h");
    @cInclude("X11/extensions/XShm.h");
    @cInclude("freetype2/ft2build.h");
    @cInclude("freetype2/freetype/freetype.h");
});
const app = @import("app.zig");

const BYTES_PER_PIXEL = 4;
const XImage = c.XImage;

/// Call the destroy function through the XImage function-pointer table.
/// XDestroyImage is a macro in C — Zig's @cImport can't resolve it cleanly.
fn xDestroyImage(img: *XImage) void {
    if (img.f.destroy_image) |destroy_fn| {
        _ = destroy_fn(img);
    }
}

/// A single SHM-backed (or malloc-backed) pixel buffer.
const ShmBuffer = struct {
    ximage: *XImage,
    shm_info: c.XShmSegmentInfo,
    memory: [*]u8,
    pitch: i32,
    using_shm: bool,

    /// Initialize in-place. Must NOT be returned by value — XShmCreateImage
    /// stores a pointer to shm_info, so moving the struct invalidates it.
    fn init(self: *ShmBuffer, display: *c.Display, visual: *c.Visual, depth: c_int, w: i32, h: i32) void {
        self.using_shm = false;
        self.shm_info = std.mem.zeroes(c.XShmSegmentInfo);

        // Try MIT-SHM first for zero-copy blitting
        const shm_image: ?*XImage = c.XShmCreateImage(
            display,
            visual,
            @intCast(depth),
            c.ZPixmap,
            null,
            &self.shm_info,
            @intCast(w),
            @intCast(h),
        );

        if (shm_image) |img| {
            const size: usize = @intCast(img.bytes_per_line * img.height);
            const shm_id = c.shmget(c.IPC_PRIVATE, size, c.IPC_CREAT | 0o777);
            if (shm_id != -1) {
                const shm_addr = c.shmat(shm_id, null, 0);
                if (shm_addr != @as(*anyopaque, @ptrFromInt(@as(usize, std.math.maxInt(usize))))) {
                    self.shm_info.shmid = shm_id;
                    self.shm_info.shmaddr = @ptrCast(shm_addr);
                    img.data = @ptrCast(shm_addr);
                    self.shm_info.readOnly = 0;

                    if (c.XShmAttach(display, &self.shm_info) != 0) {
                        _ = c.XSync(display, 0);

                        self.ximage = img;
                        self.memory = @ptrCast(shm_addr);
                        self.pitch = img.bytes_per_line;
                        self.using_shm = true;
                        _ = c.shmctl(shm_id, c.IPC_RMID, null);
                        return;
                    }
                }
                _ = c.shmctl(shm_id, c.IPC_RMID, null);
            }
            xDestroyImage(img);
        }

        // Fallback: plain XImage with malloc'd buffer
        const alloc_size = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * BYTES_PER_PIXEL;
        const raw = std.c.malloc(alloc_size) orelse @panic("out of memory for backbuffer");
        const raw_ptr: [*]u8 = @ptrCast(raw);

        const fallback_image: ?*XImage = c.XCreateImage(
            display,
            visual,
            @intCast(depth),
            c.ZPixmap,
            0,
            @ptrCast(raw),
            @intCast(w),
            @intCast(h),
            32,
            0,
        );

        self.ximage = fallback_image orelse @panic("XCreateImage failed");
        self.memory = raw_ptr;
        self.pitch = self.ximage.bytes_per_line;
    }

    fn destroy(self: *ShmBuffer, display: *c.Display) void {
        if (self.using_shm) {
            _ = c.XShmDetach(display, &self.shm_info);
            _ = c.shmdt(self.shm_info.shmaddr);
        }
        xDestroyImage(self.ximage);
    }
};

/// Double-buffered backbuffer. The game writes into buffers[back] while the
/// X server reads from buffers[front]. After blitting, front and back swap.
const X11Backbuffer = struct {
    buffers: [2]ShmBuffer,
    front: u1,
    back: u1,
    width: i32,
    height: i32,
    display: *c.Display,
    visual: *c.Visual,
    depth: c_int,

    fn init(self: *X11Backbuffer, display: *c.Display, visual: *c.Visual, depth: c_int, w: i32, h: i32) void {
        self.display = display;
        self.visual = visual;
        self.depth = depth;
        self.width = w;
        self.height = h;
        self.front = 0;
        self.back = 1;
        self.buffers[0].init(display, visual, depth, w, h);
        self.buffers[1].init(display, visual, depth, w, h);
    }

    fn getRenderBuffer(self: *X11Backbuffer) struct { memory: [*]u8, pitch: i32 } {
        return .{
            .memory = self.buffers[self.back].memory,
            .pitch = self.buffers[self.back].pitch,
        };
    }

    fn blitAndSwap(self: *X11Backbuffer, window: c.Window, gc: c.GC) void {
        const buf = &self.buffers[self.back];
        if (buf.using_shm) {
            _ = c.XShmPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
                0,
            );
        } else {
            _ = c.XPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
            );
        }

        const tmp = self.front;
        self.front = self.back;
        self.back = tmp;
    }

    /// Blit the front buffer (for Expose repaints without swapping).
    fn blitFront(self: *X11Backbuffer, window: c.Window, gc: c.GC) void {
        const buf = &self.buffers[self.front];
        if (buf.using_shm) {
            _ = c.XShmPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
                0,
            );
        } else {
            _ = c.XPutImage(
                self.display,
                window,
                gc,
                buf.ximage,
                0,
                0,
                0,
                0,
                @intCast(self.width),
                @intCast(self.height),
            );
        }
    }

    fn destroy(self: *X11Backbuffer) void {
        self.buffers[0].destroy(self.display);
        self.buffers[1].destroy(self.display);
    }

    /// Recreate both buffers at a new size. No-op if dimensions haven't changed.
    fn resize(self: *X11Backbuffer, new_w: i32, new_h: i32) void {
        if (new_w == self.width and new_h == self.height) return;
        if (new_w <= 0 or new_h <= 0) return;

        self.destroy();
        self.init(self.display, self.visual, self.depth, new_w, new_h);
    }
};

pub fn main() !void {
    const display = c.XOpenDisplay(null) orelse {
        std.debug.print("Failed to open X display\n", .{});
        return;
    };
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
        0,
        0,
        800,
        600,
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

    const gc = c.XCreateGC(display, window, 0, null);
    defer _ = c.XFreeGC(display, gc);

    // Get URL from command line args, fallback to example.com
    var initial_url: []const u8 = "http://example.com";
    if (std.process.argsAlloc(std.heap.page_allocator)) |args| {
        defer std.process.argsFree(std.heap.page_allocator, args);
        if (args.len > 1) {
            initial_url = args[1];
        }
    } else |_| {
        std.debug.print("Failed to parse args, using default URL\n", .{});
    }

    var backbuffer: X11Backbuffer = undefined;
    backbuffer.init(display, visual, depth, 800, 600);
    defer backbuffer.destroy();

    const persistent_storage_size = 32 * 1024 * 1024;
    const transient_storage_size = 64 * 1024 * 1024;
    const total_size = persistent_storage_size + transient_storage_size;
    const memory_block = std.heap.page_allocator.alloc(u8, total_size) catch @panic("out of memory for app memory");
    defer std.heap.page_allocator.free(memory_block);
    const all_bytes = memory_block[0..total_size];

    const persistent = all_bytes[0..persistent_storage_size];
    const transient = all_bytes[persistent_storage_size..];

    var fixed_buffer = std.heap.FixedBufferAllocator.init(persistent);
    const arena = std.heap.ArenaAllocator.init(fixed_buffer.allocator());

    var app_memory: app.AppMemory = .{
        .ft_library = undefined,
        .ft_face = undefined,
        .ft_is_initialized = false,
        .browser_state = .Idle,
        .current_url = &.{},
        .response_body = &.{},
        .error_message = &.{},
        .dom_tree = undefined,
        .background_color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, // white
        .text_color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .arena = arena,
        .persistent_storage = persistent,
        .transient_storage = transient,
    };

    if (backbuffer.buffers[0].using_shm) {
        std.debug.print("Platform: using MIT-SHM double-buffered backbuffer\n", .{});
    } else {
        std.debug.print("Platform: using XPutImage fallback for backbuffer\n", .{});
    }

    var running = true;
    while (running) {
        while (c.XPending(display) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(display, &event);

            switch (event.type) {
                c.Expose => {
                    backbuffer.blitFront(window, gc);
                },
                c.KeyPress => {
                    const keycode = event.xkey.keycode;
                    std.debug.print("Key pressed: {d}\n", .{keycode});
                    if (keycode == 71) { // F5 key
                        app.navigate(&app_memory, initial_url);
                    }
                    if (keycode == 9) { // Escape key
                        running = false;
                    }
                },
                c.ConfigureNotify => {
                    const width = event.xconfigure.width;
                    const height = event.xconfigure.height;
                    std.debug.print("Window resized: {d}x{d}\n", .{ width, height });
                    backbuffer.resize(width, height);
                },
                else => {},
            }
        }

        const render = backbuffer.getRenderBuffer();
        var buffer = app.OffscreenBuffer{
            .memory = render.memory,
            .width = backbuffer.width,
            .height = backbuffer.height,
            .pitch = render.pitch,
            .bytes_per_pixel = BYTES_PER_PIXEL,
        };

        app.updateAndRender(&app_memory, &buffer);
        backbuffer.blitAndSwap(window, gc);
        _ = c.XFlush(display);
    }
}
