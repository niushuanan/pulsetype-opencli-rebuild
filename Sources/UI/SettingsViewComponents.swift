import AppKit
import SwiftUI

struct HomeMetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(PulseUI.Typography.captionStrong)
                .pulseTertiaryText()
            Text(value)
                .font(PulseUI.Typography.value)
                .pulsePrimaryText()
            Text(subtitle)
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

            if let secondaryText = secondaryText {
                Text(secondaryText)
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if entry.mode == .agent,
               let evidenceText = entry.agentEvidenceSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !evidenceText.isEmpty {
                Text("证据：\(evidenceText)")
                    .font(PulseUI.Typography.caption)
                    .pulseTertiaryText()
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Text(entry.appName)
                    .font(PulseUI.Typography.monospacedMeta)
                    .pulseTertiaryText()
                Spacer()
                Button(primaryCopyTitle) {
                    onCopyPrimary()
                }
                .controlCenterSecondaryActionButton()
                .disabled(primaryCopyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(rawCopyTitle) {
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
        if entry.mode == .agent,
           entry.status != .success,
           let failure = entry.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !failure.isEmpty {
            return failure
        }

        let output = entry.outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty {
            return output
        }
        let input = entry.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty {
            return entry.mode == .agent ? "已收到 Agent 指令，正在等待执行结果。" : input
        }
        return entry.errorMessage ?? "暂无文本"
    }

    private var secondaryText: String? {
        let input = entry.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.mode == .agent {
            guard !input.isEmpty else {
                return nil
            }
            return "命令：\(input)"
        }

        guard let outputText = entry.outputText,
              outputText.trimmingCharacters(in: .whitespacesAndNewlines) != input,
              !input.isEmpty
        else {
            return nil
        }
        return input
    }

    private var primaryCopyTitle: String {
        entry.mode == .agent ? "复制结果" : "复制结果"
    }

    private var primaryCopyText: String {
        entry.outputText ?? entry.errorMessage ?? entry.inputText
    }

    private var rawCopyTitle: String {
        entry.mode == .agent ? "复制命令" : "复制原文"
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
