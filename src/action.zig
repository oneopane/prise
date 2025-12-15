//! Built-in actions for keybind system.
//!
//! Actions can be either:
//! - Built-in: Maps to an Action enum value, executed by Lua command system
//! - Custom: A Lua function reference, executed directly
//!
//! Built-in action names use snake_case and map to the commands table in tiling.lua.

const std = @import("std");

/// Built-in actions that can be bound to keys.
/// Each action corresponds to a command in the Lua commands table.
pub const Action = enum {
    // Splitting
    split_horizontal,
    split_vertical,
    split_auto,

    // Focus movement
    focus_left,
    focus_right,
    focus_up,
    focus_down,

    // Pane management
    close_pane,
    toggle_zoom,

    // Tab management
    new_tab,
    close_tab,
    rename_tab,
    next_tab,
    previous_tab,

    // Tab selection (1-10)
    tab_1,
    tab_2,
    tab_3,
    tab_4,
    tab_5,
    tab_6,
    tab_7,
    tab_8,
    tab_9,
    tab_10,

    // Resize
    resize_left,
    resize_right,
    resize_up,
    resize_down,

    // Session
    detach_session,
    rename_session,
    quit,

    // UI
    command_palette,

    /// Convert action to its canonical string name.
    pub fn toString(self: Action) []const u8 {
        return @tagName(self);
    }

    /// Parse an action from a string name.
    pub fn fromString(name: []const u8) ?Action {
        return std.meta.stringToEnum(Action, name);
    }

    /// Get the display name for the command palette.
    pub fn displayName(self: Action) []const u8 {
        return switch (self) {
            .split_horizontal => "Split Horizontal",
            .split_vertical => "Split Vertical",
            .split_auto => "Split Auto",
            .focus_left => "Focus Left",
            .focus_right => "Focus Right",
            .focus_up => "Focus Up",
            .focus_down => "Focus Down",
            .close_pane => "Close Pane",
            .toggle_zoom => "Toggle Zoom",
            .new_tab => "New Tab",
            .close_tab => "Close Tab",
            .rename_tab => "Rename Tab",
            .next_tab => "Next Tab",
            .previous_tab => "Previous Tab",
            .tab_1 => "Tab 1",
            .tab_2 => "Tab 2",
            .tab_3 => "Tab 3",
            .tab_4 => "Tab 4",
            .tab_5 => "Tab 5",
            .tab_6 => "Tab 6",
            .tab_7 => "Tab 7",
            .tab_8 => "Tab 8",
            .tab_9 => "Tab 9",
            .tab_10 => "Tab 10",
            .resize_left => "Resize Left",
            .resize_right => "Resize Right",
            .resize_up => "Resize Up",
            .resize_down => "Resize Down",
            .detach_session => "Detach Session",
            .rename_session => "Rename Session",
            .quit => "Quit",
            .command_palette => "Command Palette",
        };
    }
};

test "action string roundtrip" {
    const action = Action.split_horizontal;
    const name = action.toString();
    const parsed = Action.fromString(name);
    try std.testing.expectEqual(action, parsed.?);
}

test "action from string" {
    try std.testing.expectEqual(Action.focus_left, Action.fromString("focus_left").?);
    try std.testing.expectEqual(Action.command_palette, Action.fromString("command_palette").?);
    try std.testing.expect(Action.fromString("invalid_action") == null);
}

test "action display names" {
    try std.testing.expectEqualStrings("Split Horizontal", Action.split_horizontal.displayName());
    try std.testing.expectEqualStrings("Command Palette", Action.command_palette.displayName());
}
