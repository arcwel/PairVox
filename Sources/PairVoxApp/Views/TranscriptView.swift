// SPDX-License-Identifier: Apache-2.0

import PairVoxCore
import SwiftUI

struct TranscriptView: View {
    let entries: [TranscriptEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        Text("Say something like “What does this project do?” or “Let's brainstorm the auth redesign.”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(entries) { entry in
                        EntryView(entry: entry)
                            .id(entry.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: entries.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: entries.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct EntryView: View {
    let entry: TranscriptEntry
    @State private var showSpoken = false

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                MarkdownBlocksView(markdown: entry.text)
                HStack(spacing: 10) {
                    if entry.status == .streaming {
                        ProgressView().controlSize(.mini)
                    }
                    if entry.status == .interrupted {
                        Label("Interrupted", systemImage: "stop.circle").foregroundStyle(.orange)
                    }
                    if !entry.spoken.isEmpty {
                        Button {
                            showSpoken.toggle()
                        } label: {
                            Label("Spoken: \(entry.spoken.count)", systemImage: "speaker.wave.2")
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showSpoken) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(entry.spoken.enumerated()), id: \.offset) { _, s in Text("“\(s)”") }
                                }
                                .padding()
                            }
                            .frame(width: 380, height: 260)
                        }
                    }
                    ForEach(Array(entry.skipped.enumerated()), id: \.offset) { _, s in
                        Label(s.summary, systemImage: s.kind == .code ? "chevron.left.forwardslash.chevron.right" : "tablecells")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(entry.text, systemImage: "wrench.and.screwdriver")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        case .system:
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Renders markdown prose with code fences as monospaced blocks.
struct MarkdownBlocksView: View {
    let markdown: String

    private enum Block: Hashable {
        case prose(String)
        case code(language: String, body: String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var prose: [String] = []
        var code: [String] = []
        var language = ""
        var inFence = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    result.append(.code(language: language, body: code.joined(separator: "\n")))
                    code = []
                } else {
                    if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                    language = String(trimmed.dropFirst(3))
                }
                inFence.toggle()
            } else if inFence {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inFence { result.append(.code(language: language, body: code.joined(separator: "\n"))) }
        if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let text):
                    Text(Self.attributed(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let lang, let body):
                    VStack(alignment: .leading, spacing: 4) {
                        if !lang.isEmpty {
                            Text(lang).font(.caption2).foregroundStyle(.secondary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(body)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
