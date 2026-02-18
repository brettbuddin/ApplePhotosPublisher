/// Convenience extensions for working with Photos local identifiers.
extension String {
    /// The UUID portion of a Photos local identifier, stripping any `/L0/001` suffix.
    var uuidPrefix: String {
        components(separatedBy: "/").first ?? self
    }
}
