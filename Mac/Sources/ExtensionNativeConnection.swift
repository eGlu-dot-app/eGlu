import Foundation
import WebEngineAppKit
import WebKitExtensions

extension Extensions {
    private static let nativeTransport: any WebExtensionNativeTransport = WebKitExtensionNativeConnection()

    static func nativeConnection(program: URL, origin: String) -> any WebNativeConnection {
        nativeTransport.nativeConnection(program: program, origin: origin)
    }
}
