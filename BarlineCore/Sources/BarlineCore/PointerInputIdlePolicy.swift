/// Separates held pointer-modifying chords from persistent keyboard-device
/// flags before a menu bar transaction begins.
public enum PointerInputIdlePolicy {
    public static func hasActivePointerModifier(
        flagsRawValue: UInt,
        blockingMaskRawValue: UInt
    ) -> Bool {
        flagsRawValue & blockingMaskRawValue != 0
    }
}
