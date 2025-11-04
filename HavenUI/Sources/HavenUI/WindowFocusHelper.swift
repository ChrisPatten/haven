import SwiftUI
import AppKit

/// Helper view that ensures the window receives focus when it appears
/// Uses standard macOS window management APIs instead of manually setting window levels
/// This follows Apple's recommended practices for menu bar apps
struct WindowFocusHelper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        
        // Try to configure window immediately if it exists
        DispatchQueue.main.async {
            if let window = view.window {
                configureWindow(window)
            }
        }
        
        // Also observe when the view is added to a window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = view.window {
                configureWindow(window)
            }
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Reconfigure if window changes
        DispatchQueue.main.async {
            if let window = nsView.window {
                configureWindow(window)
            }
        }
    }
    
    private func configureWindow(_ window: NSWindow) {
        // Activate the app first - this brings the app to foreground
        // This is the standard way to bring a menu bar app's window to front
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        // Use standard window management - make it key and bring to front
        // makeKeyAndOrderFront is the recommended method per Apple docs
        // It makes the window key (receives keyboard input) and brings it to front
        window.makeKeyAndOrderFront(nil)
        
        // Make the window main (brings it to front in the app's window stack)
        // This ensures it's above other windows in the same app
        // Note: Only call makeMain() if the window can become main (sheets cannot)
        if window.canBecomeMain {
            window.makeMain()
        }
        
        // Order front regardless of other apps (helps when terminal has focus)
        // This is safe to use for sheets/dialogs that need to appear above other apps
        window.orderFrontRegardless()
    }
}

