import Foundation

/// Loads test fixtures copied into the test bundle (see Package.swift resources).
/// The `.copy("Fixtures")` rule preserves the directory, so everything lives
/// under `<bundle>/Fixtures/…`.
enum Fixtures {
    static func url(_ relativePath: String) -> URL {
        guard let root = Bundle.module.resourceURL else {
            fatalError("test bundle has no resourceURL")
        }
        let url = root.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fatalError("fixture not found in test bundle: Fixtures/\(relativePath)")
        }
        return url
    }

    static func data(_ relativePath: String) -> Data {
        (try? Data(contentsOf: url(relativePath))) ?? Data()
    }

    static func string(_ relativePath: String) -> String {
        String(data: data(relativePath), encoding: .utf8) ?? ""
    }
}
