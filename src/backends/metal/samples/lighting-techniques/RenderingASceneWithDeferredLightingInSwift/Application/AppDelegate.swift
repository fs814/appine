/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
Cross-platform app delegate
*/

#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

#if os(iOS) || os(tvOS)

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    /// Returns a configuration for UIKit when it creates a new scene.
    ///
    /// - Parameters:
    ///   - application: The app's `UIApplication` singleton.
    ///   - connectingSceneSession: A session instance that contains configuration data
    ///   from the app's `Info.plist` file, if applicable.
    ///   - options: The system-specific options that configure the scene.
    ///
    /// UIKit calls this method when it's creating a new session and applies the configuration
    /// it returns.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration",
                                   sessionRole: connectingSceneSession.role)
    }

    /// Notifies the app when UIKit discards scene sessions.
    /// - Parameters:
    ///   - application: The app's `UIApplication` singleton.
    ///   - sceneSessions: A set of sessions that UIKit is discarding.
    ///
    /// UIKit calls this method when a person discards a scene session,
    /// or after launch if they discard the scene while the app isn't running.
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Release any resources specific to any scene in the `sceneSessions` set.
    }
}

#elseif os(macOS)

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBOutlet var window: NSWindow!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
    }

    func applicationWillTerminate(_ aNotification: Notification) {
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

#endif
