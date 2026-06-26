// ios/MBI/Services/HealthKitManager.swift
// MBI Phase 1 — HealthKit Integration
// Version: 1.1 | H-01: Tier 1 metric expansion
// Authorization and reads managed here only. Raw payload sent to ingestion layer.

import Foundation
import HealthKit

class HealthKitManager: ObservableObject, @unchecked Sendable {
    static let shared = HealthKitManager()
    private let store = HKHealthStore()
    
    // 7 original primary metrics + 3 Tier 1 + distance (supporting) + Fix 6d third-party
    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .heartRateVariabilitySDNN,
            .restingHeartRate,
            .respiratoryRate,
            .stepCount,
            .appleExerciseTime,
            .distanceWalkingRunning,
            // H-01: Tier 1
            .oxygenSaturation,
            .basalEnergyBurned,
            .appleStandTime,         // used to derive stand hours
            // Fix 6d: Third-party device supplementary metrics
            .bloodPressureSystolic,
            .bloodPressureDiastolic,
            .bodyMass,
            .bodyFatPercentage,
        ]
        for id in quantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        // Stand hour count — category type, not quantity
        if let standHour = HKObjectType.categoryType(forIdentifier: .appleStandHour) {
            types.insert(standHour)
        }
        return types
    }()
    
    // ─────────────────────────────────────────
    // AUTHORIZATION
    // ─────────────────────────────────────────
    
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitError.notAvailable
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }
    
    func authorizationStatus() -> Bool {
        guard let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return false }
        return store.authorizationStatus(for: hrv) == .sharingAuthorized
    }

    /// DIAGNOSTIC 1: Returns whether HealthKit data is available on this device.
    func isHealthDataAvailable() -> Bool {
        return HKHealthStore.isHealthDataAvailable()
    }

    /// DIAGNOSTIC 5: Returns the raw Int value of the authorization status for step count.
    /// 0 = notDetermined, 1 = sharingDenied, 2 = sharingAuthorized
    func authorizationStatusForSteps() -> Int {
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return -1 }
        return store.authorizationStatus(for: stepsType).rawValue
    }
    
    // ─────────────────────────────────────────
    // 7-DAY HISTORY BOOTSTRAP
    // ─────────────────────────────────────────
    
    func readSevenDayHistory() async throws -> [RawDayMetrics] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var results: [RawDayMetrics] = []
        
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let metrics = try await readDay(date: day)
            results.append(metrics)
        }
        
        return results.reversed()
    }
    
    // ─────────────────────────────────────────
    // FULL HISTORY READ — onboarding bootstrap
    // ─────────────────────────────────────────
    
    func readFullHistory(maxDays: Int = 90) async throws -> [RawDayMetrics] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var results: [RawDayMetrics] = []
        var consecutiveEmpty = 0
        
        for offset in 1...maxDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            guard let metrics = try? await readDay(date: day) else {
                consecutiveEmpty += 1
                if consecutiveEmpty >= 5 && results.count >= 7 { break }
                continue
            }
            
            let hasAnyData = metrics.hrv_ms != nil
                || metrics.resting_hr_bpm != nil
                || metrics.respiratory_rate_rpm != nil
                || metrics.sleep_duration_hrs != nil
                || metrics.steps != nil
            
            if hasAnyData {
                results.append(metrics)
                consecutiveEmpty = 0
            } else {
                consecutiveEmpty += 1
                if consecutiveEmpty >= 5 && results.count >= 7 { break }
            }
        }
        
        return results.reversed()
    }
    
    // ─────────────────────────────────────────
    // PRIOR DAY READ (daily sync)
    // ─────────────────────────────────────────
    
    func readYesterday() async throws -> RawDayMetrics {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            throw HealthKitError.readFailed("Could not compute yesterday")
        }
        return try await readDay(date: yesterday)
    }
    
    // ─────────────────────────────────────────
    // READ ONE CALENDAR DAY
    // ─────────────────────────────────────────
    
    func readDay(date: Date) async throws -> RawDayMetrics {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw HealthKitError.readFailed("Date range computation failed")
        }
        
        async let hrv        = readHRV(start: start, end: end)
        async let rhr        = readRestingHeartRate(start: start, end: end)
        async let rr         = readRespiratoryRate(start: start, end: end)
        async let sleep      = readSleep(start: start, end: end)
        async let steps      = readSteps(start: start, end: end)
        async let activeMin  = readActiveMinutes(start: start, end: end)
        async let distance   = readDistance(start: start, end: end)
        // H-01: Tier 1
        async let spo2       = readSpO2(start: start, end: end)
        async let restingEng = readRestingEnergy(start: start, end: end)
        async let standHrs   = readStandHours(start: start, end: end)
        // Fix 6d: Third-party device supplementary metrics
        async let bpSystolic  = readBloodPressureSystolic(start: start, end: end)
        async let bpDiastolic = readBloodPressureDiastolic(start: start, end: end)
        async let weight      = readWeightLbs(start: start, end: end)
        async let bodyFat     = readBodyFatPct(start: start, end: end)

        let (hrvVal, rhrVal, rrVal, sleepData, stepsVal, activeMinVal, distanceVal,
             spo2Val, restingEngVal, standHrsVal,
             bpSysVal, bpDiasVal, weightVal, bodyFatVal) =
            try await (hrv, rhr, rr, sleep, steps, activeMin, distance,
                       spo2, restingEng, standHrs,
                       bpSystolic, bpDiastolic, weight, bodyFat)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        return RawDayMetrics(
            date: formatter.string(from: date),
            hrv_ms: hrvVal,
            resting_hr_bpm: rhrVal,
            respiratory_rate_rpm: rrVal,
            sleep_duration_hrs: sleepData?.duration,
            sleep_continuity_pct: sleepData?.efficiency,
            steps: stepsVal,
            active_minutes: activeMinVal,
            distance_km: distanceVal,
            spo2_pct: spo2Val,
            resting_energy: restingEngVal,
            stand_hours: standHrsVal,
            blood_pressure_systolic: bpSysVal,
            blood_pressure_diastolic: bpDiasVal,
            weight_lbs: weightVal,
            body_fat_pct: bodyFatVal
        )
    }
    
    // ─────────────────────────────────────────
    // INDIVIDUAL METRIC READS — existing
    // ─────────────────────────────────────────
    
    // FIX 6b — Apple Watch source filter applied to all wearable metrics.
    // HRV, RHR, respiratory rate, SpO2, active minutes, and stand hours only
    // accept data from Apple Watch (com.apple.health* bundle prefix).
    // Steps are unfiltered — both iPhone and Apple Watch counts are valid and summed.

    private func readHRV(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else { return nil }
        // BUG FIX (Phase 2): Use average across all SDNN samples in the day.
        // Source filter: Apple Watch only — Oura writes HRV to HealthKit but in
        // a different format; the Watch SDNN series is the canonical source here.
        return try await readAverageQuantity(type: type, start: start, end: end,
                                             unit: HKUnit.secondUnit(with: .milli),
                                             requireAppleWatch: true,
                                             metricName: "hrv_ms")
    }

    private func readRestingHeartRate(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else { return nil }
        return try await readLatestQuantity(type: type, start: start, end: end,
                                            unit: HKUnit.count().unitDivided(by: .minute()),
                                            requireAppleWatch: true,
                                            metricName: "resting_hr_bpm")
    }

    private func readRespiratoryRate(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) else { return nil }
        return try await readAverageQuantity(type: type, start: start, end: end,
                                             unit: HKUnit.count().unitDivided(by: .minute()),
                                             requireAppleWatch: true,
                                             metricName: "respiratory_rate_rpm")
    }

    private func readSteps(start: Date, end: Date) async throws -> Int? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return nil }
        // Steps: no source filter — both Apple Watch and iPhone are valid step counters.
        // HKStatisticsQuery sums across all sources, which is the correct behaviour.
        guard let val = try await readSumQuantity(type: type, start: start, end: end, unit: .count()) else { return nil }
        return Int(val)
    }

    private func readActiveMinutes(start: Date, end: Date) async throws -> Int? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) else { return nil }
        // appleExerciseTime is Watch-only by definition (Apple computes it on-device).
        guard let val = try await readSumQuantity(type: type, start: start, end: end, unit: .minute()) else { return nil }
        return Int(val)
    }

    private func readDistance(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return nil }
        guard let val = try await readSumQuantity(type: type, start: start, end: end, unit: .meterUnit(with: .kilo)) else { return nil }
        return val
    }
    
    // FIX 6b — Sleep source filter + interval deduplication.
    // Apple Watch source filter applied: only process samples from com.apple.health*.
    // Interval deduplication: overlapping sleep stage segments are merged before
    // summing asleep/awake seconds. This prevents double-counting when the Watch
    // writes multiple overlapping segments (observed on watchOS 10+ with nap detection).
    private func readSleep(start: Date, end: Date) async throws -> SleepData? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error = error { continuation.resume(throwing: error); return }

                guard let allSamples = samples as? [HKCategorySample], !allSamples.isEmpty else {
                    continuation.resume(returning: nil); return
                }

                // FIX 6b: Filter to Apple Watch source only
                let watchSamples = allSamples.filter { sample in
                    let sourceType = HealthKitSourceRegistry.classify(sample.sourceRevision.source)
                    if case .unknown(let bundleId) = sourceType {
                        print("[HealthKit] Unknown source: \(bundleId) for metric sleep_duration_hrs")
                    }
                    if case .appleWatch = sourceType { return true }
                    return false
                }

                // Fall through to all samples if no Watch samples found (graceful degradation)
                let samples = watchSamples.isEmpty ? allSamples : watchSamples

                // BUG FIX (Phase 2): Handle modern watchOS 9+ multi-stage sleep data.
                //
                // Legacy (pre-watchOS 9): Apple Watch writes .inBed + .asleep (value=1).
                // Modern (watchOS 9+):    Apple Watch writes granular stages — .asleepCore (4),
                //   .asleepDeep (5), .asleepREM (6), .asleepUnspecified (3), and .awake (2).
                //   Critically, modern watches do NOT write .inBed, so the old code produced
                //   inBedSeconds=0, totalBed=asleepSeconds, and efficiency=100% always.
                //   Worse, .awake fell into the else-branch, inflating asleepSeconds by all
                //   awake-in-sleep time (confirmed +63 min on Apr 26 export cross-reference).
                //
                // Fix: classify explicitly on value:
                //   .inBed  (0) → inBedSeconds      (legacy only, keep for efficiency fallback)
                //   .awake  (2) → awakeSeconds       (explicitly exclude from sleep duration)
                //   default     → asleepSeconds      (covers 1=asleep, 3=unspecified, 4=Core,
                //                                     5=Deep, 6=REM — all actual sleep stages)
                //
                // Efficiency:
                //   Modern: asleep / (asleep + awake)   [total sleep opportunity = time in bed]
                //   Legacy: asleep / inBed               [traditional sleep efficiency formula]

                // FIX 6b: Separate asleep and awake samples for interval deduplication
                let asleepSamples = samples.filter { s in
                    s.value != HKCategoryValueSleepAnalysis.inBed.rawValue &&
                    s.value != HKCategoryValueSleepAnalysis.awake.rawValue
                }
                let awakeSamples = samples.filter { s in
                    s.value == HKCategoryValueSleepAnalysis.awake.rawValue
                }
                let inBedSamples = samples.filter { s in
                    s.value == HKCategoryValueSleepAnalysis.inBed.rawValue
                }

                // Merge overlapping intervals before summing
                let asleepSeconds = Self.sumMergedIntervals(asleepSamples)
                let awakeSeconds  = Self.sumMergedIntervals(awakeSamples)
                let inBedSeconds  = Self.sumMergedIntervals(inBedSamples)

                // Efficiency formula selection:
                //   Modern: have explicit awake data → asleep/(asleep+awake)
                //   Legacy: only inBed wrapper → asleep/inBed
                //   Edge:   no stage detail at all → nil
                let efficiency: Double?
                let modernWindow = asleepSeconds + awakeSeconds
                if modernWindow > 0 {
                    // Modern path — awake is measured so ratio is accurate
                    efficiency = (asleepSeconds / modernWindow) * 100.0
                } else if inBedSeconds > 0 && asleepSeconds > 0 {
                    // Legacy path — .inBed is the outer wrapper
                    efficiency = (asleepSeconds / inBedSeconds) * 100.0
                } else {
                    efficiency = nil
                }

                let durationHrs = asleepSeconds / 3600.0
                if durationHrs < 0.5 { continuation.resume(returning: nil); return }

                continuation.resume(returning: SleepData(duration: durationHrs, efficiency: efficiency))
            }
            store.execute(query)
        }
    }

    // FIX 6b: Interval deduplication helper.
    // Sorts samples by startDate, then merges overlapping intervals.
    // Returns the total duration of the merged (non-overlapping) intervals in seconds.
    private static func sumMergedIntervals(_ samples: [HKCategorySample]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted { $0.startDate < $1.startDate }
        var total: TimeInterval = 0
        var currentStart = sorted[0].startDate
        var currentEnd   = sorted[0].endDate

        for sample in sorted.dropFirst() {
            if sample.startDate < currentEnd {
                // Overlapping — extend the merged interval if needed
                if sample.endDate > currentEnd { currentEnd = sample.endDate }
            } else {
                // Non-overlapping — commit the current interval and start a new one
                total += currentEnd.timeIntervalSince(currentStart)
                currentStart = sample.startDate
                currentEnd   = sample.endDate
            }
        }
        total += currentEnd.timeIntervalSince(currentStart)
        return total
    }
    
    // ─────────────────────────────────────────
    // INDIVIDUAL METRIC READS — H-01 Tier 1
    // ─────────────────────────────────────────

    // SpO2 — average of Apple Watch readings in the window
    // HKUnit: percent() maps to 0.0–1.0 in HealthKit; multiply by 100
    // Source filter: Apple Watch only (Oura also writes SpO2 to HealthKit; Watch is authoritative)
    private func readSpO2(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else { return nil }
        guard let val = try await readAverageQuantity(type: type, start: start, end: end,
                                                      unit: .percent(),
                                                      requireAppleWatch: true,
                                                      metricName: "spo2_pct") else { return nil }
        // HealthKit returns SpO2 as 0.0–1.0 fraction; convert to percentage
        return val * 100.0
    }
    
    // ─────────────────────────────────────────
    // Fix 6d — THIRD-PARTY DEVICE READS (iHealth, VeSync)
    // Blood pressure from iHealth devices (com.ihealth*); weight/body fat from VeSync (com.etekcity*/vesync*)
    // Uses the latest reading in the day window from the relevant source.
    // Falls back to any source if the target source has no data.
    // ─────────────────────────────────────────

    private func readBloodPressureSystolic(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic) else { return nil }
        return try await readLatestQuantity(type: type, start: start, end: end,
                                            unit: HKUnit.millimeterOfMercury(),
                                            requireAppleWatch: false,
                                            metricName: "blood_pressure_systolic")
    }

    private func readBloodPressureDiastolic(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic) else { return nil }
        return try await readLatestQuantity(type: type, start: start, end: end,
                                            unit: HKUnit.millimeterOfMercury(),
                                            requireAppleWatch: false,
                                            metricName: "blood_pressure_diastolic")
    }

    private func readWeightLbs(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else { return nil }
        guard let kg = try await readLatestQuantity(type: type, start: start, end: end,
                                                    unit: .gramUnit(with: .kilo),
                                                    requireAppleWatch: false,
                                                    metricName: "weight_lbs") else { return nil }
        return kg * 2.20462  // Convert kg → lbs
    }

    private func readBodyFatPct(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage) else { return nil }
        guard let fraction = try await readLatestQuantity(type: type, start: start, end: end,
                                                          unit: .percent(),
                                                          requireAppleWatch: false,
                                                          metricName: "body_fat_pct") else { return nil }
        return fraction * 100.0  // HealthKit stores body fat as 0.0–1.0 fraction
    }

    // Resting Energy (Basal Energy Burned) — daily sum, kcal
    private func readRestingEnergy(start: Date, end: Date) async throws -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) else { return nil }
        return try await readSumQuantity(type: type, start: start, end: end, unit: .kilocalorie())
    }
    
    // Stand Hours — count of HKCategoryValueAppleStandHour.stood samples
    // Each stood sample = 1 hour where the user stood for at least 1 minute
    // Source filter: Apple Watch only (stand hours is a Watch-exclusive metric)
    private func readStandHours(start: Date, end: Date) async throws -> Double? {
        guard let standType = HKObjectType.categoryType(forIdentifier: .appleStandHour) else { return nil }

        return try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKSampleQuery(
                sampleType: standType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let allSamples = samples as? [HKCategorySample] else {
                    continuation.resume(returning: nil); return
                }
                // FIX 6b: Apple Watch source filter
                let watchSamples = allSamples.filter { sample in
                    let sourceType = HealthKitSourceRegistry.classify(sample.sourceRevision.source)
                    if case .unknown(let bundleId) = sourceType {
                        print("[HealthKit] Unknown source: \(bundleId) for metric stand_hours")
                    }
                    if case .appleWatch = sourceType { return true }
                    return false
                }
                let useSamples = watchSamples.isEmpty ? allSamples : watchSamples
                // Count samples where value == stood (1), not idle (0)
                let stoodCount = useSamples.filter {
                    $0.value == HKCategoryValueAppleStandHour.stood.rawValue
                }.count
                // Return nil if no data at all (watch not worn), not 0
                continuation.resume(returning: useSamples.isEmpty ? nil : Double(stoodCount))
            }
            store.execute(query)
        }
    }
    
    // ─────────────────────────────────────────
    // HK QUERY HELPERS
    // ─────────────────────────────────────────
    
    // FIX 6b: Added requireWearable and metricName parameters.
    // When requireWearable=true, only Apple Watch and Oura ring sources are accepted.
    // Oura is included because it exports clinically-equivalent HRV, sleep, respiratory
    // rate, and SpO2 data via HealthKit — its data counts as a wearable signal.
    // If filtering produces an empty set, we fall back to the full sample set (graceful degradation).
    // Unknown sources are logged via print for FIX 6c compliance.
    private func isWearableSource(_ source: HKSource, metricName: String) -> Bool {
        let sourceType = HealthKitSourceRegistry.classify(source)
        switch sourceType {
        case .appleWatch, .oura: return true
        case .unknown(let bundleId):
            if !metricName.isEmpty {
                print("[HealthKit] Unknown source: \(bundleId) for metric \(metricName)")
            }
            return false
        default: return false
        }
    }

    private func readLatestQuantity(type: HKQuantityType, start: Date, end: Date, unit: HKUnit,
                                    requireAppleWatch: Bool = false, metricName: String = "") async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [self] _, samples, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let allSamples = samples as? [HKQuantitySample], !allSamples.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                let useSamples: [HKQuantitySample]
                if requireAppleWatch {
                    let wearableOnly = allSamples.filter { self.isWearableSource($0.sourceRevision.source, metricName: metricName) }
                    useSamples = wearableOnly.isEmpty ? allSamples : wearableOnly
                } else {
                    // Log unknown sources even when filter is not applied
                    for sample in allSamples {
                        _ = self.isWearableSource(sample.sourceRevision.source, metricName: metricName)
                    }
                    useSamples = allSamples
                }
                let val = useSamples.first?.quantity.doubleValue(for: unit)
                continuation.resume(returning: val)
            }
            store.execute(query)
        }
    }

    private func readAverageQuantity(type: HKQuantityType, start: Date, end: Date, unit: HKUnit,
                                     requireAppleWatch: Bool = false, metricName: String = "") async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [self] _, samples, error in
                if let error = error { continuation.resume(throwing: error); return }
                guard let allSamples = samples as? [HKQuantitySample], !allSamples.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                let useSamples: [HKQuantitySample]
                if requireAppleWatch {
                    let wearableOnly = allSamples.filter { self.isWearableSource($0.sourceRevision.source, metricName: metricName) }
                    useSamples = wearableOnly.isEmpty ? allSamples : wearableOnly
                } else {
                    // Log unknown sources even when filter is not applied
                    for sample in allSamples {
                        _ = self.isWearableSource(sample.sourceRevision.source, metricName: metricName)
                    }
                    useSamples = allSamples
                }
                let vals = useSamples.map { $0.quantity.doubleValue(for: unit) }
                continuation.resume(returning: vals.reduce(0, +) / Double(vals.count))
            }
            store.execute(query)
        }
    }
    
    private func readSumQuantity(type: HKQuantityType, start: Date, end: Date, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, error in
                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == "com.apple.healthkit" && nsError.code == 11 {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
    
    // ─────────────────────────────────────────
    // SUPPORTING TYPES
    // ─────────────────────────────────────────
    
    struct RawDayMetrics {
        let date: String
        let hrv_ms: Double?
        let resting_hr_bpm: Double?
        let respiratory_rate_rpm: Double?
        let sleep_duration_hrs: Double?
        let sleep_continuity_pct: Double?
        let steps: Int?
        let active_minutes: Int?
        let distance_km: Double?
        // H-01: Tier 1
        let spo2_pct: Double?
        let resting_energy: Double?
        let stand_hours: Double?
        // Fix 6d: Third-party device supplementary metrics
        let blood_pressure_systolic: Double?
        let blood_pressure_diastolic: Double?
        let weight_lbs: Double?
        let body_fat_pct: Double?

        init(date: String, hrv_ms: Double? = nil, resting_hr_bpm: Double? = nil,
             respiratory_rate_rpm: Double? = nil, sleep_duration_hrs: Double? = nil,
             sleep_continuity_pct: Double? = nil, steps: Int? = nil, active_minutes: Int? = nil,
             distance_km: Double? = nil, spo2_pct: Double? = nil, resting_energy: Double? = nil,
             stand_hours: Double? = nil, blood_pressure_systolic: Double? = nil,
             blood_pressure_diastolic: Double? = nil, weight_lbs: Double? = nil,
             body_fat_pct: Double? = nil) {
            self.date = date
            self.hrv_ms = hrv_ms
            self.resting_hr_bpm = resting_hr_bpm
            self.respiratory_rate_rpm = respiratory_rate_rpm
            self.sleep_duration_hrs = sleep_duration_hrs
            self.sleep_continuity_pct = sleep_continuity_pct
            self.steps = steps
            self.active_minutes = active_minutes
            self.distance_km = distance_km
            self.spo2_pct = spo2_pct
            self.resting_energy = resting_energy
            self.stand_hours = stand_hours
            self.blood_pressure_systolic = blood_pressure_systolic
            self.blood_pressure_diastolic = blood_pressure_diastolic
            self.weight_lbs = weight_lbs
            self.body_fat_pct = body_fat_pct
        }

        func toPayloadDict(userId: String) -> [String: Any] {
            var metrics: [String: Any] = [:]
            if let v = hrv_ms { metrics["hrv_ms"] = v }
            if let v = resting_hr_bpm { metrics["resting_hr_bpm"] = v }
            if let v = respiratory_rate_rpm { metrics["respiratory_rate_rpm"] = v }
            if let v = sleep_duration_hrs { metrics["sleep_duration_hrs"] = v }
            if let v = sleep_continuity_pct { metrics["sleep_continuity_pct"] = v }
            if let v = steps { metrics["steps"] = v }
            if let v = active_minutes { metrics["active_minutes"] = v }
            if let v = distance_km { metrics["distance_km"] = v }
            // H-01: Tier 1
            if let v = spo2_pct { metrics["spo2_pct"] = v }
            if let v = resting_energy { metrics["resting_energy"] = v }
            if let v = stand_hours { metrics["stand_hours"] = v }
            // Fix 6d: Third-party supplementary
            if let v = blood_pressure_systolic { metrics["blood_pressure_systolic"] = v }
            if let v = blood_pressure_diastolic { metrics["blood_pressure_diastolic"] = v }
            if let v = weight_lbs { metrics["weight_lbs"] = v }
            if let v = body_fat_pct { metrics["body_fat_pct"] = v }
            return ["userId": userId, "date": date, "metrics": metrics]
        }
    }
    
    struct SleepData {
        let duration: Double
        let efficiency: Double?
    }
    
    enum HealthKitError: Error, LocalizedError {
        case notAvailable
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAvailable: return "HealthKit is not available on this device."
            case .readFailed(let msg): return "HealthKit read failed: \(msg)"
            }
        }
    }
}

// ─────────────────────────────────────────
// FIX 6a — HEALTHKIT SOURCE REGISTRY
// Classifies a HKSource by bundle identifier prefix.
// Used for per-metric source routing in Fix 6b.
// ─────────────────────────────────────────

enum HealthKitSourceType {
    case appleWatch
    case iPhone
    case oura
    case iHealth
    case veSyncScale
    case unknown(bundleId: String)
}

struct HealthKitSourceRegistry {
    static let appleWatchBundlePrefix = "com.apple.health"
    static let ouraBundlePrefix = "com.ouraring"
    static let iHealthBundlePrefix = "com.ihealth"
    static let veSyncBundlePrefix = "com.etekcity"
    static let veSyncAltPrefix = "vesync"

    static func classify(_ source: HKSource) -> HealthKitSourceType {
        let bid = source.bundleIdentifier.lowercased()
        if bid.contains("com.apple.health") { return .appleWatch }
        if bid.contains("com.ouraring")     { return .oura }
        if bid.contains("com.ihealth")      { return .iHealth }
        if bid.contains("com.etekcity") || bid.contains("vesync") { return .veSyncScale }
        return .unknown(bundleId: source.bundleIdentifier)
    }
}

// ─────────────────────────────────────────
// WEARABLE DATA TIER
// Determined post-backfill by counting days with HRV readings in daily_inputs.
// HRV (SDNN) is Apple Watch-only — its presence is the wearable discriminator.
// Persisted to AppStorage("wearableDataTier") so main app can gate canned content.
// ─────────────────────────────────────────

enum WearableDataTier: String {
    case noWearable         = "no_wearable"          // 0 wearable days
    case sevenDay           = "seven_day"            // 1–7 wearable days
    case building           = "building"             // 8–30 wearable days
    case confidenceBuilding = "confidence_building"  // 31–89 wearable days
    case full               = "full"                 // 90+ wearable days

    /// Legacy initialiser — still used for pre-migration deployments where
    /// daily_inputs.data_tier has not yet been backfilled. Checks HRV day count
    /// as an approximation (HRV is one of the 7 wearable signals).
    static func from(hrvDays: Int) -> WearableDataTier {
        switch hrvDays {
        case 0:        return .noWearable
        case 1...7:    return .sevenDay
        case 8...30:   return .building
        case 31...89:  return .confidenceBuilding
        default:       return .full
        }
    }

    /// Section 14: Post-migration initialiser — uses data_tier = 'wearable' count
    /// from daily_inputs. More precise than HRV-only since it requires ≥4 Watch signals.
    /// Thresholds mirror from(hrvDays:) — the distribution of wearable days is similar
    /// to HRV days for Apple Watch users.
    static func from(wearableDays: Int) -> WearableDataTier {
        switch wearableDays {
        case 0:        return .noWearable
        case 1...7:    return .sevenDay
        case 8...30:   return .building
        case 31...89:  return .confidenceBuilding
        default:       return .full
        }
    }

    var displayLabel: String {
        switch self {
        case .noWearable:         return "No wearable detected"
        case .sevenDay:           return "7-day building"
        case .building:           return "Building"
        case .confidenceBuilding: return "Confidence building"
        case .full:               return "Full functionality"
        }
    }
}
