# Mynd & Bodi Institute — Phase 1 MVP

**Status:** Active Build | **Target:** iOS Native Closed Cohort (2–5 users)

## Stack
- iOS: Swift + SwiftUI (iOS 17+)
- Backend: Supabase (Postgres + Edge Functions + Auth)
- Scoring Engine: TypeScript domain package (`/packages/domain`)
- Narrative: Claude API (`claude-sonnet-4-20250514`)

## Repo Structure
```
/ios/              — SwiftUI app, HealthKit, navigation, UI only
/backend/          — Supabase config, migrations, Edge Functions
/packages/domain/  — Portable TypeScript scoring engine
```

## Local Setup

### Backend
```bash
cd backend
npm install -g supabase
supabase init
supabase start
supabase db push
```

### Domain Package
```bash
cd packages/domain
npm install
npm test
```

### iOS
Open `/ios/MBI.xcodeproj` in Xcode 15+. Set your Supabase URL and anon key in `Config.swift`. Build to device via Xcode direct install.

## Sprint Status
| Sprint | Focus | Status |
|--------|-------|--------|
| 1 | Foundation | ✅ Complete |
| 2 | Ingestion Layer | ✅ Complete |
| 3 | Domain Layer | ✅ Complete |
| 4 | Scoring Pipeline | ✅ Complete |
| 5 | Narrative Layer | ✅ Complete |
| 6 | iOS Dashboard | ✅ Complete |
| 7 | Fail States + Admin | ✅ Complete |
| 8 | Founder Validation Run | 🔲 Not Started |
