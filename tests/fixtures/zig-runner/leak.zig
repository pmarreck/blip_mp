test "intentional leak" { _ = try @import("std").testing.allocator.alloc(u8,1); }
