import SwiftUI

/// A small block-level Markdown renderer. Inline styles (bold, italic, code, links)
/// come from `AttributedString(markdown:)`.
struct MarkdownPreview: View {
    let text: String

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case bullet(String)
        case task(done: Bool, text: String)
        case numbered(number: String, text: String)
        case quote(String)
        case code(String)
        case rule
        case image(alt: String, path: String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for rawLine in text.components(separatedBy: .newlines) {
            if var lines = code {
                if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(rawLine)
                    code = lines
                }
                continue
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushParagraph(); continue }
            if line.hasPrefix("```") { flushParagraph(); code = []; continue }

            if let block = lineBlock(line) {
                flushParagraph()
                blocks.append(block)
            } else {
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func lineBlock(_ line: String) -> Block? {
        // ![alt](path) on its own line
        if line.hasPrefix("!["), line.hasSuffix(")"),
           let close = line.range(of: "]("),
           close.lowerBound > line.index(line.startIndex, offsetBy: 1) {
            let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
            let path = String(line[close.upperBound..<line.index(before: line.endIndex)])
            if !path.isEmpty { return .image(alt: alt, path: path) }
        }
        if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            let rest = line.dropFirst(level)
            if level <= 6, rest.hasPrefix(" ") {
                return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
            }
        }
        for (marker, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where line.hasPrefix(marker) {
            return .task(done: done, text: String(line.dropFirst(marker.count)))
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return .bullet(String(line.dropFirst(2)))
        }
        if line.hasPrefix(">") {
            return .quote(line.dropFirst().trimmingCharacters(in: .whitespaces))
        }
        if line == "---" || line == "***" { return .rule }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return .numbered(number: String(digits), text: String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(level == 1 ? Font.title.bold() : level == 2 ? Font.title2.bold() : Font.title3.weight(.semibold))
                .padding(.top, 4)
        case let .bullet(text):
            row(marker: Text("•").foregroundStyle(.secondary), text: Text(inline(text)))
        case let .task(done, text):
            row(marker: Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(Text(done ? "Done" : "Not done")),
                text: Text(inline(text)).strikethrough(done).foregroundStyle(done ? Color.secondary : Color.primary))
        case let .numbered(number, text):
            row(marker: Text("\(number).").monospacedDigit().foregroundStyle(.secondary), text: Text(inline(text)))
        case let .quote(text):
            Text(inline(text))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3)
                }
        case let .code(text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.callout.monospaced()).padding(12)
            }
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        case .rule:
            Divider()
        case let .image(alt, path):
            AttachmentImage(alt: alt, path: path)
        case let .paragraph(text):
            Text(inline(text))
        }
    }

    private func row(marker: some View, text: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(minWidth: 18, alignment: .leading)
            text
        }
    }
}

/// An encrypted attachment, decrypted off the main thread when shown.
struct AttachmentImage: View {
    @EnvironmentObject private var model: AppModel
    let alt: String
    let path: String
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(Text(alt.isEmpty ? "Photo" : alt))
            } else if missing {
                Label("Attachment not found", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.fill.tertiary)
                    .aspectRatio(4 / 3, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .task(id: path) {
            image = await model.image(at: path)
            missing = image == nil
        }
    }
}
