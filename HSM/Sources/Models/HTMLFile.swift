import SwiftUI
import UniformTypeIdentifiers

/// Wraps an HTML Data payload so it can be shared via ShareLink as an .html file.
struct HTMLFile: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .html) { file in
            file.data
        }
    }
}

/// Wraps a JSON Data payload so it can be shared via ShareLink as a named .json file.
struct JSONFile: Transferable {
    let data: Data
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { file in
            file.data
        }
    }
}
