import Foundation
import WebEngineAppKit

extension Extensions {
    static func nativeConnection(program: URL, origin: String) -> any WebNativeConnection {
        EngineComposition.nativeConnection(program: program, origin: origin)
    }
}
