import AppKit
import SwiftUI

struct HomeMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbolName: String
    var tintColor: Color = PulseUI.ColorTokens.glow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(title)
                    .font(PulseUI.Typography.captionStrong)
                    .pulseSecondaryText()

                Spacer(minLength: 8)

                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tintColor)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(tintColor.opacity(0.12))
                    )
            }

            Text(value)
                .font(PulseUI.Typography.value)
                .pulsePrimaryText()
            Text(subtitle)
                .font(PulseUI.Typography.caption)
                .pulseTertiaryText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 84, alignment: .topLeading)
        .padding(14)
        .controlCenterInsetPanel()
    }
}

struct HistoryRowView: View {
    let entry: SessionHistoryEntry
    let onCopyPrimary: () -> Void
    let onCopyRaw: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
                Spacer()
                Label(statusTitle, systemImage: statusSymbol)
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(statusColor)
            }

            Text(primaryText)
                .font(PulseUI.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let outputText = entry.outputText,
               outputText.trimmingCharacters(in: .whitespacesAndNewlines) != entry.inputText.trimmingCharacters(in: .whitespacesAndNewlines),
               !entry.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("ASR 原文：\(entry.inputText)")
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Text(entry.appName)
                    .font(PulseUI.Typography.monospacedMeta)
                    .pulseTertiaryText()
                if let textProcessingProvider = entry.textProcessingProvider, let textProcessingModel = entry.textProcessingModel {
                    Text("\(textProcessingProvider) · \(textProcessingModel)")
                        .font(PulseUI.Typography.monospacedMeta)
                        .pulseTertiaryText()
                }
                Spacer()
                Button("复制结果") {
                    onCopyPrimary()
                }
                .controlCenterSecondaryActionButton()
                .disabled((entry.outputText ?? entry.inputText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("复制原文") {
                    onCopyRaw()
                }
                .controlCenterSecondaryActionButton()
                .disabled(entry.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("删除", role: .destructive) {
                    onDelete()
                }
                .controlCenterSecondaryActionButton()
            }
        }
    }

    private var primaryText: String {
        let output = entry.outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty {
            return output
        }
        let input = entry.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty {
            return input
        }
        return entry.errorMessage ?? "暂无文本"
    }

    private var statusTitle: String {
        switch entry.status {
        case .success:
            return "成功"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    private var statusSymbol: String {
        switch entry.status {
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "slash.circle.fill"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .success:
            return PulseUI.ColorTokens.success
        case .failed:
            return PulseUI.ColorTokens.danger
        case .cancelled:
            return PulseUI.ColorTokens.warning
        }
    }
}

struct PulseToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(PulseUI.Typography.bodyStrong)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 14, x: 0, y: 8)
    }
}
