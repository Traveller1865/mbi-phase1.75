// ios/MBI/MBI/Services/DoctorReportService.swift
// MBI Phase 2 — Sprint 9 · Doctor Report PDF Generator
//
// Generates a wellness-framed PDF summary from Chronos biometric data.
// Intended for users who want to share patterns with a healthcare provider.
//
// Legal framework:
//   - No clinical language: no "diagnosis", "treatment", "disease", "medical record"
//   - No "physician" — always "licensed healthcare professional"
//   - Legal disclaimer section required on every page
//   - Wellness-tracking framing per HorizonEscalateView Legal Framework §4.1–4.2
//
// Output: Data (PDF bytes) — share via UIActivityViewController.
// Runs on MainActor to safely call UIKit drawing APIs.

import UIKit

@MainActor
final class DoctorReportService {
    static let shared = DoctorReportService()
    private init() {}

    // ── Public API ────────────────────────────────────────────────────────

    func generate(
        user: MBIUser,
        score: DailyScore,
        assessment: HorizonAssessment,
        reportDate: Date = Date()
    ) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let margin: CGFloat = 48
        let contentWidth: CGFloat = pageRect.width - margin * 2

        return renderer.pdfData { ctx in
            ctx.beginPage()
            var pen = Pen(x: margin, y: 40, contentWidth: contentWidth, margin: margin)

            drawHeader(&pen, user: user, date: reportDate)
            drawHRule(pen.ctx, pen: pen)
            pen.y += 14

            drawScoreSection(&pen, score: score)
            drawHRule(pen.ctx, pen: pen)
            pen.y += 14

            drawDomainSection(&pen, score: score)
            drawHRule(pen.ctx, pen: pen)
            pen.y += 14

            drawHorizonSection(&pen, assessment: assessment)

            // Start new page for disclaimer if near the bottom
            if pen.y > 640 {
                ctx.beginPage()
                pen.y = 40
            }
            drawHRule(pen.ctx, pen: pen)
            pen.y += 14
            drawDisclaimer(&pen, date: reportDate)
            drawFooter(pen.ctx, pageRect: pageRect, date: reportDate)
        }
    }

    // ── Pen (mutable drawing cursor) ──────────────────────────────────────

    // Avoids threading CGContext through every call — uses the current renderer context.
    private struct Pen {
        var x: CGFloat
        var y: CGFloat
        let contentWidth: CGFloat
        let margin: CGFloat

        var ctx: CGContext { UIGraphicsGetCurrentContext()! }
        var maxX: CGFloat { x + contentWidth }

        mutating func advanceY(_ delta: CGFloat) { y += delta }
    }

    // ── Header ────────────────────────────────────────────────────────────

    private func drawHeader(_ pen: inout Pen, user: MBIUser, date: Date) {
        // App logo-style title
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 19, weight: .thin),
            .foregroundColor: UIColor(white: 0.10, alpha: 1),
            .kern: 3.0 as AnyObject,
        ]
        drawText("CHRONOS WELLNESS SUMMARY", attrs: titleAttrs, pen: &pen)
        pen.y += 6

        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor(white: 0.45, alpha: 1),
        ]
        let df = DateFormatter()
        df.dateStyle = .long
        drawText("Generated \(df.string(from: date))", attrs: subAttrs, pen: &pen)
        pen.y += 2
        let name = user.displayName ?? user.email
        drawText("Prepared for: \(name)", attrs: subAttrs, pen: &pen)
        pen.y += 10
    }

    // ── Score Section ─────────────────────────────────────────────────────

    private func drawScoreSection(_ pen: inout Pen, score: DailyScore) {
        drawSectionLabel("CURRENT STATUS", pen: &pen)
        pen.y += 4

        let scoreVal = Int(score.chronosScore.rounded())
        let scoreAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .ultraLight),
            .foregroundColor: UIColor(white: 0.10, alpha: 1),
        ]
        drawText("Score:  \(scoreVal) / 100", attrs: scoreAttrs, pen: &pen)
        pen.y += 4

        let bandAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor(white: 0.35, alpha: 1),
        ]
        drawText("\(score.scoreBand.rawValue)  ·  \(score.scoreBand.description)", attrs: bandAttrs, pen: &pen)
        pen.y += 10
    }

    // ── Domain Section ────────────────────────────────────────────────────

    private func drawDomainSection(_ pen: inout Pen, score: DailyScore) {
        drawSectionLabel("DOMAIN OVERVIEW", pen: &pen)
        pen.y += 6

        let domains: [(String, Double?)] = [
            ("D1  Autonomic Regulation",  score.d1Autonomic),
            ("D2  Sleep Quality",         score.d2Sleep),
            ("D3  Activity",              score.d3Activity),
            ("D4  Inferred Stress",       score.d4Stress),
            ("D5  Allostatic Load",       score.d5Allostatic),
        ]

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor(white: 0.28, alpha: 1),
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor(white: 0.12, alpha: 1),
        ]
        let naAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor(white: 0.60, alpha: 1),
        ]

        for (label, value) in domains {
            // Draw label
            NSAttributedString(string: label, attributes: labelAttrs)
                .draw(at: CGPoint(x: pen.x, y: pen.y))

            // Draw value right-aligned
            let valStr: NSAttributedString
            if let v = value {
                valStr = NSAttributedString(string: "\(Int(v.rounded())) / 100", attributes: valueAttrs)
            } else {
                valStr = NSAttributedString(string: "—", attributes: naAttrs)
            }
            let valWidth = valStr.size().width
            valStr.draw(at: CGPoint(x: pen.maxX - valWidth, y: pen.y))

            // Subtle dot leader
            pen.ctx.saveGState()
            pen.ctx.setStrokeColor(UIColor(white: 0.88, alpha: 1).cgColor)
            pen.ctx.setLineWidth(0.5)
            pen.ctx.setLineDash(phase: 0, lengths: [2, 4])
            let labelWidth = NSAttributedString(string: label, attributes: labelAttrs).size().width
            pen.ctx.move(to: CGPoint(x: pen.x + labelWidth + 8, y: pen.y + 8))
            pen.ctx.addLine(to: CGPoint(x: pen.maxX - valWidth - 8, y: pen.y + 8))
            pen.ctx.strokePath()
            pen.ctx.restoreGState()

            pen.y += 20
        }

        pen.y += 4
    }

    // ── Horizon Section ───────────────────────────────────────────────────

    private func drawHorizonSection(_ pen: inout Pen, assessment: HorizonAssessment) {
        drawSectionLabel("HORIZON PATTERN RECOGNITION", pen: &pen)
        pen.y += 6

        let signals = [assessment.autonomic, assessment.sleep, assessment.metabolic]
            .compactMap { $0 }
            .filter { $0.isActive }

        if signals.isEmpty {
            let noAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor(white: 0.50, alpha: 1),
            ]
            drawText("No active patterns detected.", attrs: noAttrs, pen: &pen)
            pen.y += 6
        } else {
            for signal in signals {
                drawSignalRow(&pen, signal: signal)
                pen.y += 4
            }
        }

        pen.y += 4
    }

    private func drawSignalRow(_ pen: inout Pen, signal: HorizonSignal) {
        let pathwayName: String
        switch signal.pathway {
        case "autonomic": pathwayName = "AUTONOMIC"
        case "sleep":     pathwayName = "SLEEP"
        default:          pathwayName = "METABOLIC"
        }

        let wellnessLabel = conditionClassLabel(signal.conditionClass)

        // Thin left accent bar
        pen.ctx.saveGState()
        pen.ctx.setFillColor(UIColor(red: 0.88, green: 0.65, blue: 0.22, alpha: 0.55).cgColor)
        pen.ctx.fill(CGRect(x: pen.x, y: pen.y, width: 3, height: 36))
        pen.ctx.restoreGState()

        let pathwayAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: UIColor(white: 0.18, alpha: 1),
            .kern: 1.5 as AnyObject,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .light),
            .foregroundColor: UIColor(white: 0.15, alpha: 1),
        ]
        let detailAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor(white: 0.50, alpha: 1),
        ]

        let indentX = pen.x + 12
        NSAttributedString(string: pathwayName, attributes: pathwayAttrs)
            .draw(at: CGPoint(x: indentX, y: pen.y))
        pen.y += 14
        NSAttributedString(string: wellnessLabel, attributes: labelAttrs)
            .draw(at: CGPoint(x: indentX, y: pen.y))
        pen.y += 14

        let confidencePct = Int(signal.confidenceGate * 100)
        let detail = "Duration: \(signal.daysInPattern) days   ·   Signal confidence: \(confidencePct)%"
        NSAttributedString(string: detail, attributes: detailAttrs)
            .draw(at: CGPoint(x: indentX, y: pen.y))
        pen.y += 16
    }

    // ── Disclaimer ────────────────────────────────────────────────────────

    private func drawDisclaimer(_ pen: inout Pen, date: Date) {
        drawSectionLabel("ABOUT THIS DOCUMENT", pen: &pen)
        pen.y += 8

        let df = DateFormatter()
        df.dateStyle = .long

        let paragraphs: [String] = [
            "This document was generated by the Chronos wellness tracking application on \(df.string(from: date)). It reflects patterns in biometric measurements collected via Apple HealthKit during the preceding period.",
            "This is not a medical record, clinical assessment, diagnosis, or treatment recommendation. The measurements described are wellness tracking indicators only. Scores and patterns do not indicate the presence or absence of any medical condition or disease.",
            "Any health concerns should be discussed with a licensed healthcare professional. In case of a medical emergency, contact emergency services immediately. Nothing in this document should delay, replace, or substitute professional medical evaluation.",
        ]

        let paraAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor(white: 0.45, alpha: 1),
        ]

        let paraRect = CGRect(x: pen.x, y: 0, width: pen.contentWidth, height: 1000)

        for para in paragraphs {
            let str = NSAttributedString(string: para, attributes: paraAttrs)
            let height = str.boundingRect(with: paraRect.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
            str.draw(in: CGRect(x: pen.x, y: pen.y, width: pen.contentWidth, height: height + 4))
            pen.y += height + 12
        }
    }

    // ── Footer ────────────────────────────────────────────────────────────

    private func drawFooter(_ ctx: CGContext, pageRect: CGRect, date: Date) {
        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .light),
            .foregroundColor: UIColor(white: 0.70, alpha: 1),
            .kern: 1.0 as AnyObject,
        ]
        let footerStr = NSAttributedString(
            string: "CHRONOS  ·  Mynd & Bodi Institute  ·  Wellness Tracking Only  ·  Not a Medical Document",
            attributes: footerAttrs
        )
        let strSize = footerStr.size()
        footerStr.draw(at: CGPoint(x: (pageRect.width - strSize.width) / 2, y: pageRect.height - 30))
    }

    // ── Drawing Helpers ───────────────────────────────────────────────────

    private func drawSectionLabel(_ text: String, pen: inout Pen) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: UIColor(white: 0.55, alpha: 1),
            .kern: 2.5 as AnyObject,
        ]
        NSAttributedString(string: text, attributes: attrs).draw(at: CGPoint(x: pen.x, y: pen.y))
        pen.y += 14
    }

    private func drawText(_ text: String, attrs: [NSAttributedString.Key: Any], pen: inout Pen) {
        let str = NSAttributedString(string: text, attributes: attrs)
        let height = str.boundingRect(
            with: CGSize(width: pen.contentWidth, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height
        str.draw(in: CGRect(x: pen.x, y: pen.y, width: pen.contentWidth, height: height + 2))
        pen.y += height + 4
    }

    @discardableResult
    private func drawHRule(_ ctx: CGContext, pen: Pen) -> CGFloat {
        ctx.saveGState()
        ctx.setStrokeColor(UIColor(white: 0.84, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: pen.x, y: pen.y))
        ctx.addLine(to: CGPoint(x: pen.maxX, y: pen.y))
        ctx.strokePath()
        ctx.restoreGState()
        return pen.y + 1
    }

    // ── Condition Class Labels ─────────────────────────────────────────────

    private func conditionClassLabel(_ conditionClass: String?) -> String {
        switch conditionClass ?? "" {
        case "autonomic_stress_load":           return "Autonomic System Under Pressure"
        case "sleep_architecture_disruption":   return "Sleep Architecture Under Pressure"
        case "metabolic_inactivity_load":       return "Metabolic Recovery Window"
        case "combined_autonomic_sleep":        return "Recovery Capacity Under Pressure"
        case "combined_metabolic_sleep":        return "Restorative Load Accumulating"
        case "full_system_load":                return "Systemic Resilience Under Pressure"
        case "autonomic_dysfunction_early":     return "Autonomic Load Accumulating"
        case "sleep_fragmentation_early":       return "Sleep Architecture Under Pressure"
        case "metabolic_risk_inferred":         return "Metabolic Stress Building"
        default:                                return "Pattern Detected"
        }
    }
}
