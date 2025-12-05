//! HTML output renderer.

const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;
const Span = parser.Span;
const Document = parser.Document;

pub const Options = struct {
    fragment: bool = false,
};

/// Render a Document to HTML format.
/// All allocations use the provided allocator (typically an arena).
pub fn render(allocator: std.mem.Allocator, doc: Document, title: []const u8, options: Options) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buffer.writer(allocator);

    if (!options.fragment) {
        try writer.print(
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <meta charset="utf-8">
            \\  <title>{s}</title>
            \\  <style>
            \\    body {{ font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }}
            \\    pre {{ background: #f5f5f5; padding: 1rem; overflow-x: auto; }}
            \\    code {{ background: #f5f5f5; padding: 0.2rem 0.4rem; }}
            \\    dt {{ font-weight: bold; margin-top: 1rem; }}
            \\    dd {{ margin-left: 2rem; }}
            \\  </style>
            \\</head>
            \\<body>
            \\
        , .{title});
    }

    for (doc.nodes) |node| {
        try renderNode(writer, node);
    }

    if (!options.fragment) {
        try writer.writeAll("</body>\n</html>\n");
    }

    return buffer.toOwnedSlice(allocator);
}

fn renderNode(writer: anytype, node: Node) !void {
    switch (node) {
        .heading => |h| {
            const tag = if (h.level == 1) "h1" else "h2";
            try writer.print("<{s}>", .{tag});
            try escapeAndWrite(writer, h.text);
            try writer.print("</{s}>\n", .{tag});
        },
        .paragraph => |spans| {
            try writer.writeAll("<p>");
            try renderSpans(writer, spans);
            try writer.writeAll("</p>\n");
        },
        .code_block => |cb| {
            if (cb.language) |lang| {
                try writer.print("<pre><code class=\"language-{s}\">", .{lang});
            } else {
                try writer.writeAll("<pre><code>");
            }
            try escapeAndWrite(writer, cb.content);
            try writer.writeAll("</code></pre>\n");
        },
        .bullet_list => |items| {
            try writer.writeAll("<ul>\n");
            for (items) |item| {
                try writer.writeAll("  <li>");
                try renderSpans(writer, item);
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>\n");
        },
        .definition => |def| {
            try writer.writeAll("<dl>\n  <dt>");
            try renderSpans(writer, def.term);
            try writer.writeAll("</dt>\n  <dd>");
            try renderSpans(writer, def.description);
            try writer.writeAll("</dd>\n</dl>\n");
        },
    }
}

fn renderSpans(writer: anytype, spans: []const Span) !void {
    for (spans) |span| {
        switch (span) {
            .text => |t| try escapeAndWrite(writer, t),
            .bold => |t| {
                try writer.writeAll("<strong>");
                try escapeAndWrite(writer, t);
                try writer.writeAll("</strong>");
            },
            .italic => |t| {
                try writer.writeAll("<em>");
                try escapeAndWrite(writer, t);
                try writer.writeAll("</em>");
            },
            .code => |t| {
                try writer.writeAll("<code>");
                try escapeAndWrite(writer, t);
                try writer.writeAll("</code>");
            },
            .link => |l| {
                try writer.writeAll("<a href=\"");
                try escapeAndWrite(writer, l.url);
                try writer.writeAll("\">");
                try escapeAndWrite(writer, l.text);
                try writer.writeAll("</a>");
            },
        }
    }
}

fn escapeAndWrite(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}
