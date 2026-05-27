import Foundation

/// Interned event names.
public enum EventName {
    public static let screenView        = "screen_view"
    public static let tap               = "tap"
    public static let apiCall           = "api_call"
    public static let crash             = "crash"
    public static let connectivity      = "connectivity_change"
    public static let deepLink          = "deep_link"
    public static let appForeground     = "app_foreground"
    public static let appBackground     = "app_background"
    public static let sessionStart      = "session_start"
    public static let sessionEnd        = "session_end"
    public static let sessionTag        = "session_tag"
    public static let memoryWarning     = "memory_warning"
    public static let battery           = "battery_change"
    public static let thermal           = "thermal_change"
    public static let permissionChange  = "permission_change"
    public static let permissionSnapshot = "permission_snapshot"
    public static let push              = "push"
    public static let deviceSnapshot    = "device_snapshot"
    public static let sdkInternal       = "sdk_internal"
    public static let webView           = "web_view"
    public static let backgroundTask    = "background_task"
    public static let preferenceChange  = "preference_change"
}
