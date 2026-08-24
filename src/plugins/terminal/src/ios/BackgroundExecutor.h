#import "Executor.h"

/// Cordova-facing plugin class registered for JS Executor calls made through
/// Executor.BackgroundExecutor (www/Executor.js). It deliberately implements
/// NOTHING: every session-creating or session-mutating selector responds with
/// a CDVPluginResult error so JavaScript cannot accidentally create real
/// guest sessions (or double sessions alongside the foreground Executor)
/// through the background path. Only moveToBackground/moveToForeground keep
/// their inherited harmless OK responses.
@interface BackgroundExecutor : Executor
@end
