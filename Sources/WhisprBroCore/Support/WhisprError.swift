import Foundation

public enum WhisprError: Error, LocalizedError {
    case eventTapCreationFailed
    case audioConverterUnavailable
    case modelsNotFound(URL)
    case audioFileUnreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .eventTapCreationFailed:
            return "Could not create the global hotkey event tap. Grant Input Monitoring in System Settings → Privacy & Security."
        case .audioConverterUnavailable:
            return "Could not create an audio converter for the current input device format."
        case .modelsNotFound(let url):
            return "ASR models not found at \(url.path). Run scripts/fetch-models.sh once to install them."
        case .audioFileUnreadable(let url):
            return "Could not read audio file at \(url.path)."
        }
    }
}
