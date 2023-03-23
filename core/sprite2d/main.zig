const std = @import("std");
const mach = @import("mach");
const gpu = mach.gpu;
const zm = @import("zmath");
const zigimg = @import("zigimg");
// const Vertex = @import("cube_mesh.zig").Vertex;
// const vertices = @import("cube_mesh.zig").vertices;
const assets = @import("assets");

pub const App = @This();

pub const Vertex = extern struct {
    pos: @Vector(4, f32),
    uv: @Vector(2, f32),
};
const UniformBufferObject = struct {
    mat: zm.Mat,
};
const Sprite = struct {
    const Self = @This();

    fn init(pos_x: f32, pos_y: f32, width: f32, height: f32, world_x: f32, world_y: f32) Self {
        var self: Self = .{
            .pos_x = pos_x,
            .pos_y = pos_y,
            .width = width,
            .height = height,
            .world_x = world_x,
            .world_y = world_y,
        };

        return self;
    }

    pos_x: f32,
    pos_y: f32,
    width: f32,
    height: f32,
    world_x: f32,
    world_y: f32,

    fn updateWorldX(self: *Self, newValue: f32) void {
        self.world_x += newValue / 12;
    }

    fn getVertices(self: *Self, sheet: SpriteSheet) []Vertex {
        return &[_]Vertex{
            // Vertex 0 - bottom-left
            .{ .pos = .{ self.world_x + 0.0, 0.0, self.world_y + 0.0, 1.0 }, .uv = .{ self.pos_x / sheet.width, (self.pos_y + self.height) / sheet.height } },
            // Vertex 1 - top-left
            .{ .pos = .{ self.world_x + 0.0, 0.0, (self.world_y + self.height), 1.0 }, .uv = .{ self.pos_x / sheet.width, self.pos_y / sheet.height } },
            // Vertex 2 - bottom-right
            .{ .pos = .{ (self.world_x + self.width), 0.0, self.world_y + 0.0, 1.0 }, .uv = .{ (self.pos_x + self.width) / sheet.width, (self.pos_y + self.height) / sheet.height } },
            // Vertex 3 - bottom-right
            .{ .pos = .{ (self.world_x + self.width), 0.0, self.world_y + 0.0, 1.0 }, .uv = .{ (self.pos_x + self.width) / sheet.width, (self.pos_y + self.height) / sheet.height } },
            // Vertex 4 - top-left
            .{ .pos = .{ self.world_x + 0.0, 0.0, (self.world_y + self.height), 1.0 }, .uv = .{ self.pos_x / sheet.width, self.pos_y / sheet.height } },
            // Vertex 5 - top-right
            .{ .pos = .{ (self.world_x + self.width), 0.0, (self.world_y + self.height), 1.0 }, .uv = .{ (self.pos_x + self.width) / sheet.width, self.pos_y / sheet.height } },
        };
    }
};
const SpriteSheet = struct {
    width: f32,
    height: f32,
};
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

core: mach.Core,
timer: mach.Timer,
fps_timer: mach.Timer,
window_title_timer: mach.Timer,
pipeline: *gpu.RenderPipeline,
queue: *gpu.Queue,
vertex_buffer: *gpu.Buffer,
uniform_buffer: *gpu.Buffer,
bind_group: *gpu.BindGroup,
depth_texture: *gpu.Texture,
depth_texture_view: *gpu.TextureView,
sprite: Sprite,
sprite_two: Sprite,
sheet: SpriteSheet,
vertices: [12]Vertex,

pub fn init(app: *App) !void {
    const allocator = gpa.allocator();
    try app.core.init(allocator, .{});

    entity_position = zm.f32x4(0, 0, 0, 0);

    app.sprite = Sprite.init(0.0, 0.0, 64.0, 96.0, 0.0, 0.0);
    app.sprite_two = Sprite.init(64.0, 0.0, 64.0, 96.0, 128.0, 128.0);
    app.sheet = SpriteSheet{ .width = 384.0, .height = 96.0 };
    var i: usize = 0;
    for (app.sprite.getVertices(app.sheet)) |element| {
        app.vertices[i] = element;
        i += 1;
    }
    for (app.sprite_two.getVertices(app.sheet)) |element| {
        app.vertices[i] = element;
        i += 1;
    }

    const shader_module = app.core.device().createShaderModuleWGSL("simple-shader.wgsl", @embedFile("simple-shader.wgsl"));

    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout.init(.{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &vertex_attributes,
    });

    const blend = gpu.BlendState{
        .color = .{
            .operation = .add,
            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
        },
        .alpha = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .zero,
        },
    };
    const color_target = gpu.ColorTargetState{
        .format = app.core.descriptor().format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMaskFlags.all,
    };
    const fragment = gpu.FragmentState.init(.{
        .module = shader_module,
        .entry_point = "frag_main",
        .targets = &.{color_target},
    });

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        // Enable depth testing so that the fragment closest to the camera
        // is rendered in front.
        .depth_stencil = &.{
            .format = .depth24_plus,
            .depth_write_enabled = true,
            .depth_compare = .less,
        },
        .vertex = gpu.VertexState.init(.{
            .module = shader_module,
            .entry_point = "vertex_main",
            .buffers = &.{vertex_buffer_layout},
        }),
        .primitive = .{
            // Backface culling since the cube is solid piece of geometry.
            // Faces pointing away from the camera will be occluded by faces
            // pointing toward the camera.
            .cull_mode = .back,
        },
    };
    const pipeline = app.core.device().createRenderPipeline(&pipeline_descriptor);

    // const vertex_buffer = app.core.device().createBuffer(&.{
    //     .usage = .{ .vertex = true },
    //     .size = @sizeOf(Vertex) * vertices.len,
    //     .mapped_at_creation = true,
    // });
    // var vertex_mapped = vertex_buffer.getMappedRange(Vertex, 0, vertices.len);
    // std.mem.copy(Vertex, vertex_mapped.?, vertices[0..]);
    // vertex_buffer.unmap();
    const vertex_buffer = app.core.device().createBuffer(&.{
        .usage = .{ .vertex = true },
        // .size = @sizeOf(Vertex) * vertices.len,
        .size = 1152,
        .mapped_at_creation = true,
    });
    var sprite_mapped = vertex_buffer.getMappedRange(Vertex, 0, app.vertices.len);
    std.mem.copy(Vertex, sprite_mapped.?, app.vertices[0..]);
    vertex_buffer.unmap();

    // Create a sampler with linear filtering for smooth interpolation.
    const sampler = app.core.device().createSampler(&.{
        .mag_filter = .linear,
        .min_filter = .linear,
    });
    const queue = app.core.device().getQueue();
    // var img = try zigimg.Image.fromMemory(allocator, assets.gotta_go_fast_image);
    // defer img.deinit();
    var img = try zigimg.Image.fromMemory(allocator, assets.example_spritesheet_image);
    defer img.deinit();
    const img_size = gpu.Extent3D{ .width = @intCast(u32, img.width), .height = @intCast(u32, img.height) };
    const cube_texture = app.core.device().createTexture(&.{
        .size = img_size,
        .format = .rgba8_unorm,
        .usage = .{
            .texture_binding = true,
            .copy_dst = true,
            .render_attachment = true,
        },
    });
    const data_layout = gpu.Texture.DataLayout{
        .bytes_per_row = @intCast(u32, img.width * 4),
        .rows_per_image = @intCast(u32, img.height),
    };
    switch (img.pixels) {
        .rgba32 => |pixels| queue.writeTexture(&.{ .texture = cube_texture }, &data_layout, &img_size, pixels),
        .rgb24 => |pixels| {
            const data = try rgb24ToRgba32(allocator, pixels);
            defer data.deinit(allocator);
            queue.writeTexture(&.{ .texture = cube_texture }, &data_layout, &img_size, data.rgba32);
        },
        else => @panic("unsupported image color format"),
    }

    const uniform_buffer = app.core.device().createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(UniformBufferObject),
        .mapped_at_creation = false,
    });

    const bind_group = app.core.device().createBindGroup(
        &gpu.BindGroup.Descriptor.init(.{
            .layout = pipeline.getBindGroupLayout(0),
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(UniformBufferObject)),
                gpu.BindGroup.Entry.sampler(1, sampler),
                gpu.BindGroup.Entry.textureView(2, cube_texture.createView(&gpu.TextureView.Descriptor{})),
            },
        }),
    );

    const depth_texture = app.core.device().createTexture(&gpu.Texture.Descriptor{
        .size = gpu.Extent3D{
            .width = app.core.descriptor().width,
            .height = app.core.descriptor().height,
        },
        .format = .depth24_plus,
        .usage = .{
            .render_attachment = true,
            .texture_binding = true,
        },
    });

    const depth_texture_view = depth_texture.createView(&gpu.TextureView.Descriptor{
        .format = .depth24_plus,
        .dimension = .dimension_2d,
        .array_layer_count = 1,
        .mip_level_count = 1,
    });

    app.timer = try mach.Timer.start();
    app.fps_timer = try mach.Timer.start();
    app.window_title_timer = try mach.Timer.start();
    app.pipeline = pipeline;
    app.queue = queue;
    app.vertex_buffer = vertex_buffer;
    app.uniform_buffer = uniform_buffer;
    app.bind_group = bind_group;
    app.depth_texture = depth_texture;
    app.depth_texture_view = depth_texture_view;

    shader_module.release();
}

pub fn deinit(app: *App) void {
    defer _ = gpa.deinit();
    defer app.core.deinit();

    app.vertex_buffer.release();
    app.uniform_buffer.release();
    app.bind_group.release();
    app.depth_texture.release();
    app.depth_texture_view.release();
}
var entity_position = zm.f32x4(0, 0, 0, 0);
var direction = zm.f32x4(0, 0, 0, 0);

const speed = 2.0 * 100.0; // pixels per second
pub fn update(app: *App) !bool {
    var iter = app.core.pollEvents();
    while (iter.next()) |event| {
        switch (event) {
            .key_press => |ev| {
                switch (ev.key) {
                    .space => return true,
                    .left => direction[0] += 1,
                    .right => direction[0] -= 1,
                    .up => direction[2] += 1,
                    .down => direction[2] -= 1,
                    else => {},
                }
            },
            .key_release => |ev| {
                switch (ev.key) {
                    .left => direction[0] -= 1,
                    .right => direction[0] += 1,
                    .up => direction[2] -= 1,
                    .down => direction[2] += 1,
                    else => {},
                }
            },
            .framebuffer_resize => |ev| {
                // If window is resized, recreate depth buffer otherwise we cannot use it.
                app.depth_texture.release();

                app.depth_texture = app.core.device().createTexture(&gpu.Texture.Descriptor{
                    .size = gpu.Extent3D{
                        .width = ev.width,
                        .height = ev.height,
                    },
                    .format = .depth24_plus,
                    .usage = .{
                        .render_attachment = true,
                        .texture_binding = true,
                    },
                });

                app.depth_texture_view.release();
                app.depth_texture_view = app.depth_texture.createView(&gpu.TextureView.Descriptor{
                    .format = .depth24_plus,
                    .dimension = .dimension_2d,
                    .array_layer_count = 1,
                    .mip_level_count = 1,
                });
            },
            .close => return true,
            else => {},
        }
    }

    const delta_time = app.fps_timer.lap();
    entity_position += direction * zm.splat(@Vector(4, f32), speed) * zm.splat(@Vector(4, f32), delta_time);

    const back_buffer_view = app.core.swapChain().getCurrentTextureView();
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .clear_value = .{ .r = 0.5, .g = 0.5, .b = 0.5, .a = 0.0 },
        .load_op = .clear,
        .store_op = .store,
    };

    const encoder = app.core.device().createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassDescriptor.init(.{
        .color_attachments = &.{color_attachment},
        .depth_stencil_attachment = &.{
            .view = app.depth_texture_view,
            .depth_clear_value = 1.0,
            .depth_load_op = .clear,
            .depth_store_op = .store,
        },
    });

    {
        const model = zm.translation(entity_position[0], entity_position[1], entity_position[2]);
        app.sprite_two.updateWorldX(entity_position[0]);
        var i: usize = 0;
        for (app.sprite.getVertices(app.sheet)) |element| {
            app.vertices[i] = element;
            i += 1;
        }
        for (app.sprite_two.getVertices(app.sheet)) |element| {
            app.vertices[i] = element;
            i += 1;
        }
        const vertex_buffer = app.core.device().createBuffer(&.{
            .usage = .{ .vertex = true },
            // .size = @sizeOf(Vertex) * vertices.len,
            .size = 1152,
            .mapped_at_creation = true,
        });
        var sprite_mapped = vertex_buffer.getMappedRange(Vertex, 0, app.vertices.len);
        std.mem.copy(Vertex, sprite_mapped.?, app.vertices[0..]);
        vertex_buffer.unmap();
        app.vertex_buffer = vertex_buffer;
        const view = zm.lookAtRh(
            zm.f32x4(0, 1000, 0, 1),
            zm.f32x4(0, 0, 0, 1),
            zm.f32x4(0, 0, 1, 0),
        );

        // One pixel in our scene will equal one window pixel (i.e. be roughly the same size
        // irrespective of whether the user has a Retina/HDPI display.)
        const proj = zm.orthographicRh(
            @intToFloat(f32, app.core.size().width),
            @intToFloat(f32, app.core.size().height),
            0.1,
            1000,
        );
        const mvp = zm.mul(zm.mul(model, view), proj);
        const ubo = UniformBufferObject{
            .mat = zm.transpose(mvp),
        };
        encoder.writeBuffer(app.uniform_buffer, 0, &[_]UniformBufferObject{ubo});
    }

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setPipeline(app.pipeline);
    pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(Vertex) * app.vertices.len);
    pass.setBindGroup(0, app.bind_group, &.{});
    pass.draw(12, 1, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    app.queue.submit(&[_]*gpu.CommandBuffer{command});
    command.release();
    app.core.swapChain().present();
    back_buffer_view.release();

    if (app.window_title_timer.read() >= 1.0) {
        app.window_title_timer.reset();
        var buf: [32]u8 = undefined;
        const title = try std.fmt.bufPrintZ(&buf, "Sprite2D [ FPS: {d} ]", .{@floor(1 / delta_time)});
        app.core.setTitle(title);
    }

    return false;
}

fn rgb24ToRgba32(allocator: std.mem.Allocator, in: []zigimg.color.Rgb24) !zigimg.color.PixelStorage {
    const out = try zigimg.color.PixelStorage.init(allocator, .rgba32, in.len);
    var i: usize = 0;
    while (i < in.len) : (i += 1) {
        out.rgba32[i] = zigimg.color.Rgba32{ .r = in[i].r, .g = in[i].g, .b = in[i].b, .a = 255 };
    }
    return out;
}
