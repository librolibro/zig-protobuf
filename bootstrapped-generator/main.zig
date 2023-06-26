const warn = @import("std").debug.warn;
const std = @import("std");
const pb = @import("protobuf");
const plugin = @import("google/protobuf/compiler.pb.zig");
const descriptor = @import("google/protobuf.pb.zig");
const mem = std.mem;
const FullName = @import("./FullName.zig").FullName;

const allocator = std.heap.page_allocator;

const string = []const u8;

pub fn main() !void {
    const stdin = &std.io.getStdIn();

    // Read the contents (up to 10MB)
    const buffer_size = 1024 * 1024 * 10;

    const file_buffer = try stdin.readToEndAlloc(allocator, buffer_size);
    defer allocator.free(file_buffer);

    var request: plugin.CodeGeneratorRequest = try plugin.CodeGeneratorRequest.decode(file_buffer, allocator);

    var ctx: GenerationContext = GenerationContext{ .req = request };

    try ctx.processRequest();

    const stdout = &std.io.getStdOut();
    const r = try ctx.res.encode(allocator);
    _ = try stdout.write(r);
}

const GenerationContext = struct {
    req: plugin.CodeGeneratorRequest,
    res: plugin.CodeGeneratorResponse = plugin.CodeGeneratorResponse.init(allocator),

    /// map of known packages
    known_packages: std.StringHashMap(FullName) = std.StringHashMap(FullName).init(allocator),

    /// map of "package.fully.qualified.names" to output string lists
    output_lists: std.StringHashMap(std.ArrayList([]const u8)) = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),

    const Self = @This();

    pub fn processRequest(self: *Self) !void {
        for (self.req.proto_file.items) |file| {
            const t: descriptor.FileDescriptorProto = file;

            if (t.package) |package| {
                try self.known_packages.put(package.getSlice(), FullName{ .buf = package.getSlice() });
            } else {
                self.res.@"error" = pb.ManagedString{ .Owned = .{ .str = try std.fmt.allocPrint(allocator, "ERROR Package directive missing in {?s}\n", .{file.name.?.getSlice()}), .allocator = allocator } };
                return;
            }
        }

        for (self.req.proto_file.items) |file| {
            const t: descriptor.FileDescriptorProto = file;

            const name = FullName{ .buf = t.package.?.getSlice() };

            try self.printFileDeclarations(name, file);
        }

        var it = self.output_lists.iterator();
        while (it.next()) |entry| {
            var ret = plugin.CodeGeneratorResponse.File.init(allocator);

            ret.name = pb.ManagedString.move(try self.fileNameFromPackage(entry.key_ptr.*), allocator);
            ret.content = pb.ManagedString.move(try std.mem.concat(allocator, u8, entry.value_ptr.*.items), allocator);

            try self.res.file.append(ret);
        }

        self.res.supported_features = @intFromEnum(plugin.CodeGeneratorResponse.Feature.FEATURE_PROTO3_OPTIONAL);
    }

    fn fileNameFromPackage(self: *Self, package: string) !string {
        return try std.fmt.allocPrint(allocator, "{?s}.pb.zig", .{try self.packageNameToOutputFileName(package)});
    }

    fn packageNameToOutputFileName(_: *Self, n: string) !string {
        var r: []u8 = try allocator.alloc(u8, n.len);
        for (n, 0..) |byte, i| {
            r[i] = switch (byte) {
                '.', '/', '\\' => '/',
                else => byte,
            };
        }
        return r;
    }

    fn getOutputList(self: *Self, name: FullName) !*std.ArrayList([]const u8) {
        var entry = try self.output_lists.getOrPut(name.buf);

        if (!entry.found_existing) {
            var list = std.ArrayList([]const u8).init(allocator);

            try list.append(try std.fmt.allocPrint(allocator,
                \\// Code generated by protoc-gen-zig
                \\ ///! package {s}
                \\const std = @import("std");
                \\const Allocator = std.mem.Allocator;
                \\const ArrayList = std.ArrayList;
                \\
                \\const protobuf = @import("protobuf");
                \\const ManagedString = protobuf.ManagedString;
                \\const fd = protobuf.fd;
                \\
            , .{name.buf}));

            // collect all imports from all files sharing the same package
            var importedPackages = std.StringHashMap(bool).init(allocator);

            for (self.req.proto_file.items) |file| {
                if (name.eqlString(file.package.?.getSlice())) {
                    for (file.dependency.items) |dep| {
                        for (self.req.proto_file.items) |item| {
                            if (std.mem.eql(u8, dep.getSlice(), item.name.?.getSlice())) {
                                try importedPackages.put(item.package.?.getSlice(), true);
                            }
                        }
                    }
                }
            }

            var it = importedPackages.keyIterator();
            while (it.next()) |package| {
                if (!std.mem.eql(u8, package.*, name.buf)) {
                    try list.append(try std.fmt.allocPrint(allocator, "/// import package {?s}\n", .{package.*}));
                    try list.append(try std.fmt.allocPrint(allocator, "const {!s} = @import(\"{!s}\");\n", .{ self.escapeFqn(package.*), self.resolvePath(name.buf, package.*) }));
                }
            }

            entry.value_ptr.* = list;
        }

        return entry.value_ptr;
    }

    /// resolves an import path from the file A relative to B
    fn resolvePath(self: *Self, a: string, b: string) !string {
        const aPath = std.fs.path.dirname(try self.fileNameFromPackage(a)) orelse "";
        const bPath = try self.fileNameFromPackage(b);
        return std.fs.path.relative(allocator, aPath, bPath);
    }

    pub fn printFileDeclarations(self: *Self, fqn: FullName, file: descriptor.FileDescriptorProto) !void {
        var list = try self.getOutputList(fqn);

        try self.generateEnums(list, fqn, file, file.enum_type);
        try self.generateMessages(list, fqn, file, file.message_type);
    }

    fn generateEnums(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, enums: std.ArrayList(descriptor.EnumDescriptorProto)) !void {
        _ = ctx;
        _ = file;
        _ = fqn;

        for (enums.items) |theEnum| {
            const e: descriptor.EnumDescriptorProto = theEnum;

            try list.append(try std.fmt.allocPrint(allocator, "\npub const {?s} = enum(i32) {{\n", .{e.name.?.getSlice()}));

            for (e.value.items) |elem| {
                try list.append(try std.fmt.allocPrint(allocator, "   {?s} = {},\n", .{ elem.name.?.getSlice(), elem.number orelse 0 }));
            }

            try list.append("    _,\n};\n\n");
        }
    }

    fn getFieldName(_: *Self, field: descriptor.FieldDescriptorProto) !string {
        return escapeName(field.name.?.getSlice());
    }

    fn escapeName(name: string) !string {
        if (std.zig.Token.keywords.get(name) != null)
            return try std.fmt.allocPrint(allocator, "@\"{?s}\"", .{name})
        else
            return name;
    }

    fn fieldTypeFqn(ctx: *Self, parentFqn: FullName, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto) !string {
        if (field.type_name) |typeName| {
            const fullTypeName = FullName{ .buf = typeName.getSlice()[1..] };

            if (fullTypeName.parent()) |parent| {
                if (parent.eql(parentFqn)) {
                    return fullTypeName.name().buf;
                }
                if (parent.eql(FullName{ .buf = file.package.?.getSlice() })) {
                    return fullTypeName.name().buf;
                }
            }

            var parent: ?FullName = fullTypeName.parent();
            const filePackage = FullName{ .buf = file.package.?.getSlice() };

            // iterate parents until we find a parent that matches the known_packages
            while (parent != null) {
                var it = ctx.known_packages.valueIterator();

                while (it.next()) |value| {

                    // it is in current package, return full name
                    if (filePackage.eql(parent.?)) {
                        const name = fullTypeName.buf[parent.?.buf.len + 1 ..];
                        return name;
                    }

                    // it is in different package. return fully qualified name including accessor
                    if (value.eql(parent.?)) {
                        const prop = try ctx.escapeFqn(parent.?.buf);
                        const name = fullTypeName.buf[prop.len + 1 ..];
                        return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prop, name });
                    }
                }

                parent = parent.?.parent();
            }

            std.debug.print("Unknown type: {s} from {s} in {?s}\n", .{ fullTypeName.buf, parentFqn.buf, file.package.?.getSlice() });

            return try ctx.escapeFqn(field.type_name.?.getSlice());
        }
        @panic("field has no type");
    }

    fn escapeFqn(_: *Self, n: string) !string {
        var r: []u8 = try allocator.alloc(u8, n.len);
        for (n, 0..) |byte, i| {
            r[i] = switch (byte) {
                '.', '/', '\\' => '_',
                else => byte,
            };
        }
        return r;
    }

    fn isRepeated(_: *Self, field: descriptor.FieldDescriptorProto) bool {
        if (field.label) |l| {
            return l == .LABEL_REPEATED;
        } else {
            return false;
        }
    }

    fn isScalarNumeric(t: descriptor.FieldDescriptorProto.Type) bool {
        return switch (t) {
            .TYPE_DOUBLE, .TYPE_FLOAT, .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64, .TYPE_SINT32, .TYPE_SINT64, .TYPE_FIXED32, .TYPE_FIXED64, .TYPE_SFIXED32, .TYPE_SFIXED64, .TYPE_BOOL => true,
            else => false,
        };
    }

    fn isPacked(_: *Self, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto) bool {
        const default = if (file.syntax != null and std.mem.eql(u8, file.syntax.?.getSlice(), "proto3"))
            if (field.type) |t|
                isScalarNumeric(t)
            else
                false
        else
            false;

        if (field.options) |o| {
            if (o.@"packed") |p| {
                return p;
            }
        }
        return default;
    }

    fn isOptional(_: *Self, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto) bool {
        if (file.syntax != null and std.mem.eql(u8, file.syntax.?.getSlice(), "proto3")) {
            return field.proto3_optional == true;
        }

        if (field.label) |l| {
            return l == .LABEL_OPTIONAL;
        } else {
            return false;
        }
    }

    fn getFieldType(ctx: *Self, fqn: FullName, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !string {
        var prefix: string = "";
        var postfix: string = "";
        const repeated = ctx.isRepeated(field);
        const t = field.type.?;

        if (!repeated) {
            if (!is_union) {
                // look for optional types
                switch (t) {
                    .TYPE_MESSAGE => prefix = "?",
                    else => if (ctx.isOptional(file, field)) {
                        prefix = "?";
                    },
                }
            }
        } else {
            prefix = "ArrayList(";
            postfix = ")";
        }

        const infix: string = switch (t) {
            .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_INT32 => "i32",
            .TYPE_UINT32, .TYPE_FIXED32 => "u32",
            .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64 => "i64",
            .TYPE_UINT64, .TYPE_FIXED64 => "u64",
            .TYPE_BOOL => "bool",
            .TYPE_DOUBLE => "f64",
            .TYPE_FLOAT => "f32",
            .TYPE_STRING, .TYPE_BYTES => "ManagedString",
            .TYPE_ENUM, .TYPE_MESSAGE => try ctx.fieldTypeFqn(fqn, file, field),
            else => {
                std.debug.print("Unrecognized type {}\n", .{t});
                @panic("Unrecognized type");
            },
        };

        return try std.mem.concat(allocator, u8, &.{ prefix, infix, postfix });
    }

    fn getFieldDefault(_: *Self, field: descriptor.FieldDescriptorProto) !?string {
        if (field.default_value == null) return null;
        return switch (field.type.?) {
            .TYPE_SINT32, .TYPE_SFIXED32, .TYPE_INT32, .TYPE_UINT32, .TYPE_FIXED32, .TYPE_INT64, .TYPE_SINT64, .TYPE_SFIXED64, .TYPE_UINT64, .TYPE_FIXED64, .TYPE_BOOL => field.default_value.?.getSlice(),
            .TYPE_FLOAT => if (std.mem.eql(u8, field.default_value.?.getSlice(), "inf")) "std.math.inf(f32)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "-inf")) "-std.math.inf(f32)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "nan")) "std.math.nan(f32)" else field.default_value.?.getSlice(),
            .TYPE_DOUBLE => if (std.mem.eql(u8, field.default_value.?.getSlice(), "inf")) "std.math.inf(f64)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "-inf")) "-std.math.inf(f64)" else if (std.mem.eql(u8, field.default_value.?.getSlice(), "nan")) "std.math.nan(f64)" else field.default_value.?.getSlice(),
            .TYPE_STRING, .TYPE_BYTES => try std.mem.concat(allocator, u8, &.{ "ManagedString.static(", try formatSliceEscapeImpl(field.default_value.?.getSlice()), ")" }),
            .TYPE_MESSAGE => null, // SubMessages have no default values
            .TYPE_ENUM => try std.mem.concat(allocator, u8, &.{ ".", field.default_value.?.getSlice() }),
            else => null,
        };
    }

    fn getFieldTypeDescriptor(ctx: *Self, _: FullName, file: descriptor.FileDescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !string {
        _ = is_union;
        var prefix: string = "";

        var postfix: string = "";

        if (ctx.isRepeated(field)) {
            if (ctx.isPacked(file, field)) {
                prefix = ".{ .PackedList = ";
            } else {
                prefix = ".{ .List = ";
            }
            postfix = "}";
        }

        const infix: string = switch (field.type.?) {
            .TYPE_DOUBLE, .TYPE_SFIXED64, .TYPE_FIXED64 => ".{ .FixedInt = .I64 }",
            .TYPE_FLOAT, .TYPE_SFIXED32, .TYPE_FIXED32 => ".{ .FixedInt = .I32 }",
            .TYPE_ENUM, .TYPE_UINT32, .TYPE_UINT64, .TYPE_BOOL, .TYPE_INT32, .TYPE_INT64 => ".{ .Varint = .Simple }",
            .TYPE_SINT32, .TYPE_SINT64 => ".{ .Varint = .ZigZagOptimized }",
            .TYPE_STRING, .TYPE_BYTES => ".String",
            .TYPE_MESSAGE => ".{ .SubMessage = {} }",
            else => {
                std.debug.print("Unrecognized type {}\n", .{field.type.?});
                @panic("Unrecognized type");
            },
        };

        return try std.mem.concat(allocator, u8, &.{ prefix, infix, postfix });
    }

    fn generateFieldDescriptor(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, message: descriptor.DescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !void {
        _ = message;
        var name = try ctx.getFieldName(field);
        var descStr = try ctx.getFieldTypeDescriptor(fqn, file, field, is_union);
        const format = "        .{s} = fd({?d}, {s}),\n";
        try list.append(try std.fmt.allocPrint(allocator, format, .{ name, field.number, descStr }));
    }

    fn generateFieldDeclaration(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, message: descriptor.DescriptorProto, field: descriptor.FieldDescriptorProto, is_union: bool) !void {
        _ = message;

        var type_str = try ctx.getFieldType(fqn, file, field, is_union);
        var field_name = try ctx.getFieldName(field);

        if (try ctx.getFieldDefault(field)) |default_value| {
            try list.append(try std.fmt.allocPrint(allocator, "    {s}: {s} = {s},\n", .{ field_name, type_str, default_value }));
        } else {
            try list.append(try std.fmt.allocPrint(allocator, "    {s}: {s},\n", .{ field_name, type_str }));
        }
    }

    /// this function returns the amount of options available for a given "oneof" declaration
    ///
    /// since protobuf 3.14, optional values in proto3 are wrapped in a single-element
    /// oneof to enable optional behavior in most languages. since we have optional types
    /// in zig, we can not use it for a better end-user experience and for readability
    fn amountOfElementsInOneofUnion(_: *Self, message: descriptor.DescriptorProto, oneof_index: ?i32) u32 {
        if (oneof_index == null) return 0;

        var count: u32 = 0;
        for (message.field.items) |f| {
            if (oneof_index == f.oneof_index)
                count += 1;
        }

        return count;
    }

    fn generateMessages(ctx: *Self, list: *std.ArrayList(string), fqn: FullName, file: descriptor.FileDescriptorProto, messages: std.ArrayList(descriptor.DescriptorProto)) !void {
        for (messages.items) |message| {
            const m: descriptor.DescriptorProto = message;
            const messageFqn = try fqn.append(allocator, m.name.?.getSlice());

            try list.append(try std.fmt.allocPrint(allocator, "\npub const {?s} = struct {{\n", .{m.name.?.getSlice()}));

            // append all fields that are not part of a oneof
            for (m.field.items) |f| {
                if (f.oneof_index == null or ctx.amountOfElementsInOneofUnion(m, f.oneof_index) == 1) {
                    try ctx.generateFieldDeclaration(list, messageFqn, file, m, f, false);
                }
            }

            // print all oneof fields
            for (m.oneof_decl.items, 0..) |oneof, i| {
                const union_element_count = ctx.amountOfElementsInOneofUnion(m, @intCast(i32, i));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?.getSlice();
                    try list.append(try std.fmt.allocPrint(allocator, "    {s}: ?{s}_union,\n", .{ try escapeName(oneof_name), oneof_name }));
                }
            }

            // then print the oneof declarations
            for (m.oneof_decl.items, 0..) |oneof, i| {
                // only emit unions that have more than one element
                const union_element_count = ctx.amountOfElementsInOneofUnion(m, @intCast(i32, i));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?.getSlice();

                    try list.append(try std.fmt.allocPrint(allocator,
                        \\
                        \\    pub const _{s}_case = enum {{
                        \\
                    , .{oneof_name}));

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @intCast(i32, i)) {
                            var name = try ctx.getFieldName(f);
                            try list.append(try std.fmt.allocPrint(allocator, "      {?s},\n", .{name}));
                        }
                    }

                    try list.append(try std.fmt.allocPrint(allocator,
                        \\    }};
                        \\    pub const {s}_union = union(_{s}_case) {{
                        \\
                    , .{ oneof_name, oneof_name }));

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @intCast(i32, i)) {
                            var name = try ctx.getFieldName(f);
                            var typeStr = try ctx.getFieldType(messageFqn, file, f, true);
                            try list.append(try std.fmt.allocPrint(allocator, "      {?s}: {?s},\n", .{ name, typeStr }));
                        }
                    }

                    try list.append(
                        \\    pub const _union_desc = .{
                        \\
                    );

                    for (m.field.items) |field| {
                        const f: descriptor.FieldDescriptorProto = field;
                        if (f.oneof_index orelse -1 == @intCast(i32, i)) {
                            try ctx.generateFieldDescriptor(list, messageFqn, file, m, f, true);
                        }
                    }

                    try list.append(
                        \\      };
                        \\    };
                        \\
                    );
                }
            }

            // field descriptors
            try list.append(
                \\
                \\    pub const _desc_table = .{
                \\
            );

            // first print fields
            for (m.field.items) |f| {
                if (f.oneof_index == null or ctx.amountOfElementsInOneofUnion(m, f.oneof_index) == 1) {
                    try ctx.generateFieldDescriptor(list, messageFqn, file, m, f, false);
                }
            }

            // print all oneof fields
            for (m.oneof_decl.items, 0..) |oneof, i| {
                // only emit unions that have more than one element
                const union_element_count = ctx.amountOfElementsInOneofUnion(m, @intCast(i32, i));
                if (union_element_count > 1) {
                    const oneof_name = oneof.name.?.getSlice();
                    try list.append(try std.fmt.allocPrint(allocator, "    .{s} = fd(null, .{{ .OneOf = {s}_union }}),\n", .{ oneof_name, oneof_name }));
                }
            }

            try list.append(
                \\    };
                \\
            );

            try ctx.generateEnums(list, messageFqn, file, m.enum_type);
            try ctx.generateMessages(list, messageFqn, file, m.nested_type);

            try list.append(try std.fmt.allocPrint(allocator,
                \\
                \\    pub usingnamespace protobuf.MessageMixins(@This());
                \\}};
                \\
            , .{}));
        }
    }
};

pub fn formatSliceEscapeImpl(
    str: string,
) !string {
    const charset = "0123456789ABCDEF";
    var buf: [4]u8 = undefined;

    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var writer = out.writer();

    try writer.writeByte('"');

    buf[0] = '\\';
    buf[1] = 'x';

    for (str) |c| {
        if (c == '"') {
            try writer.writeByte('\\');
            try writer.writeByte('"');
        } else if (c == '\\') {
            try writer.writeByte('\\');
            try writer.writeByte('\\');
        } else if (std.ascii.isPrint(c)) {
            try writer.writeByte(c);
        } else {
            buf[2] = charset[c >> 4];
            buf[3] = charset[c & 15];
            try writer.writeAll(&buf);
        }
    }
    try writer.writeByte('"');
    return out.toOwnedSlice();
}
