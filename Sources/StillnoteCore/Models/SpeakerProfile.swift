import Foundation

public struct SpeakerProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var email: String
    public var phone: String

    public init(id: String = UUID().uuidString, name: String, email: String = "", phone: String = "") {
        self.id = id
        self.name = name
        self.email = email
        self.phone = phone
    }

    public func validated() throws -> SpeakerProfile {
        var result = self
        result.name = try Validation.speakerName(name)
        result.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        result.phone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.email.isEmpty,
           result.email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil {
            throw ValidationError("Enter a valid email address or leave it blank.")
        }
        return result
    }
}
