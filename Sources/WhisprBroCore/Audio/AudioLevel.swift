import Foundation

/// Perceptual mapping from a linear RMS block level to a 0…1 display level.
///
/// Raw speech RMS at typical mic gain lives around 0.005–0.05, so any linear
/// scale renders a nearly flat waveform. Mapping through dB and normalizing
/// against a floor/ceiling spreads conversational dynamics across the full
/// range: −55dB (room noise, gated to 0) … −15dB (loud speech, full scale).
public enum AudioLevel {
    public static let floorDB: Float = -55
    public static let ceilingDB: Float = -15

    public static func perceptual(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
    }
}
