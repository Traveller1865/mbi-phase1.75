// ios/MBI/MBI/Views/HorizonMomentumView.swift
// MBI Phase 2 — Horizon · Momentum Page
//
// ⚠️ RETIRED — Horizon Redesign Sprint
// HorizonMomentumView has been removed from the page array.
// Components migrated:
//   - MomentumState enum       → Models.swift
//   - AllostaticMomentumBar    → HorizonTrajectoryView.swift
//   - PathwayMomentumRow       → HorizonTrajectoryView.swift
//   - CompoundingEffectNote    → SystemRelationshipCard in HorizonTrajectoryView.swift
//
// File retained to avoid Xcode target membership errors.
// Do not add this view to any page array.

import SwiftUI

// Stub retained for compilation — no longer rendered.
struct HorizonMomentumView: View {
    let assessment: HorizonAssessment

    var body: some View {
        EmptyView()
    }
}
