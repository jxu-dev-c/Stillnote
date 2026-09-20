import Foundation

/// Shared constants and model catalog for the mlx-MOSS-Transcribe-Diarize Swift package.
public enum MossDefaults {
    /// Matches the Python package Chinese default prompt.
    public static let prompt = """
    请将音频转写为文本，每一段需以起始时间戳和说话人编号\
    （[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，\
    并在段末标注结束时间戳，以清晰标明该段语音范围。
    """

    /// Recommended default Hugging Face repo (8-bit text backbone).
    public static let recommendedModel = ModelVariant.int8.repositoryID

    /// Original OpenMOSS upstream checkpoint (full precision, not MLX-quantized).
    public static let upstreamModel = "OpenMOSS-Team/MOSS-Transcribe-Diarize"
}

/// Published MLX checkpoints for this project.
public enum ModelVariant: String, CaseIterable, Sendable, Identifiable {
    case fullPrecision = "fp"
    case int8 = "8bit"
    case int4 = "4bit"

    public var id: String { rawValue }

    public var repositoryID: String {
        switch self {
        case .fullPrecision:
            return "vanch007/mlx-MOSS-Transcribe-Diarize"
        case .int8:
            return "vanch007/mlx-MOSS-Transcribe-Diarize-8bit"
        case .int4:
            return "vanch007/mlx-MOSS-Transcribe-Diarize-4bit"
        }
    }

    public var displayName: String {
        switch self {
        case .fullPrecision: return "Full Precision (FP)"
        case .int8: return "8-bit (recommended)"
        case .int4: return "4-bit"
        }
    }

    public var detail: String {
        switch self {
        case .fullPrecision:
            return "Full precision MLX checkpoint (~1.8G)."
        case .int8:
            return "Text backbone 8-bit; audio encoder/adaptor stay full precision (~1.2G)."
        case .int4:
            return "Text backbone 4-bit; audio encoder/adaptor stay full precision (~931M)."
        }
    }
}
