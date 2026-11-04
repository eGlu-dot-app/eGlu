/// Capabilities the engine can supply. Private element data is still checked
/// on each element, since a menu can arrive without it.
public enum WebTrait: Sendable, Hashable {
    case isolatedScripts, correlatedUnusedWheelEvents, rubberBandControl
    case documentPictureInPicture, videoPictureInPicture, contextMenuElement
}
