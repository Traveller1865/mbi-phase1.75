// ios/MBI/MBI/Views/AuthView.swift
// MBI Phase 1.5 — Chronos Auth Screen
// Epic 2 Sprint 1: confirm password field, trust signal, terms links, SSO removed
// Phase 2 Sprint 4: Sign In with Apple added (both sign-up and sign-in modes)

import SwiftUI
import AuthenticationServices
import CryptoKit

// ─────────────────────────────────────────
// DESIGN TOKENS
// ─────────────────────────────────────────

struct ChronosTheme {
    static let ink       = Color(red: 0.04,  green: 0.04,  blue: 0.06)
    static let surface   = Color(red: 0.08,  green: 0.08,  blue: 0.11)
    static let panel     = Color(red: 0.10,  green: 0.10,  blue: 0.16)
    static let gold      = Color(red: 0.722, green: 0.580, blue: 0.416)
    static let goldLight = Color(red: 0.831, green: 0.671, blue: 0.510)
    static let goldDim   = Color(red: 0.722, green: 0.580, blue: 0.416).opacity(0.15)
    static let text      = Color(red: 0.965, green: 0.953, blue: 0.933)
    static let muted     = Color(red: 0.965, green: 0.953, blue: 0.933).opacity(0.5)
    static let faint     = Color(red: 0.965, green: 0.953, blue: 0.933).opacity(0.18)
    static let border    = Color.white.opacity(0.07)
}

// MARK: - Font Extension
// Cormorant Garamond + Jost — both are variable fonts (wght axis).
// Bundled files: CormorantGaramond-VariableFont_wght.ttf (PostScript: "CormorantGaramond-Light")
//                CormorantGaramond-Italic-VariableFont_wght.ttf (PostScript: "CormorantGaramond-LightItalic")
//                Jost-VariableFont_wght.ttf (PostScript: "Jost-Regular")
//
// Cormorant: display face, used at light weight throughout — single PostScript name covers all calls.
// Jost: UI face, used at multiple weights — UIFont + CoreText wght axis gives genuine variation.

import CoreText

extension Font {

    // MARK: Cormorant Garamond
    // Variable font — drives wght axis via CoreText, same pattern as Jost.
    // Valid wght range for this file: 300–700.
    static func cormorant(size: CGFloat, weight: Font.Weight = .light) -> Font {
        Font(UIFont.cormorantVariable(size: size, weight: weight))
    }

    static func cormorantItalic(size: CGFloat) -> Font {
        .custom("CormorantGaramond-LightItalic", size: size)
    }

    // MARK: Jost
    // Variable font — drives wght axis via CoreText for genuine weight variation.
    static func jost(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(UIFont.jostVariable(size: size, weight: weight))
    }
}

extension UIFont {
    /// Cormorant Garamond variable font, wght axis 300–700.
    static func cormorantVariable(size: CGFloat, weight: Font.Weight) -> UIFont {
        let wghtValue: CGFloat
        switch weight {
        case .ultraLight, .thin, .light: wghtValue = 300
        case .medium:                    wghtValue = 500
        case .semibold:                  wghtValue = 600
        case .bold, .heavy, .black:      wghtValue = 700
        default:                         wghtValue = 400  // .regular
        }
        let descriptor = UIFontDescriptor(name: "CormorantGaramond-Light", size: size)
            .addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                    [2003265652: wghtValue]   // 'wght' axis tag (0x77676874)
            ])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// Loads Jost at any weight by setting the OpenType wght axis (tag 0x77676874 = 2003265652).
    static func jostVariable(size: CGFloat, weight: Font.Weight) -> UIFont {
        let wghtValue: CGFloat
        switch weight {
        case .ultraLight:  wghtValue = 100
        case .thin:        wghtValue = 200
        case .light:       wghtValue = 300
        case .medium:      wghtValue = 500
        case .semibold:    wghtValue = 600
        case .bold:        wghtValue = 700
        case .heavy:       wghtValue = 800
        case .black:       wghtValue = 900
        default:           wghtValue = 400  // .regular
        }
        let descriptor = UIFontDescriptor(name: "Jost-Regular", size: size)
            .addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String):
                    [2003265652: wghtValue]   // 'wght' axis tag
            ])
        return UIFont(descriptor: descriptor, size: size)
    }
}

// ─────────────────────────────────────────
// AUTH VIEW
// Sign-up: email + password + confirm + trust signal + terms
// Sign-in: email + password only (no confirm field)
// No SSO buttons — deferred to Phase 2
// ─────────────────────────────────────────

struct AuthView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var email           = ""
    @State private var password        = ""
    @State private var confirmPassword = ""
    @State private var isSignUp        = true    // default to sign-up for new installs
    @State private var isLoading       = false
    @State private var errorMessage: String?
    @State private var appeared        = false

    // Terms/Privacy sheet
    @State private var showTerms       = false
    @State private var showPrivacy     = false

    // Inline field errors
    @State private var emailError: String?
    @State private var passwordError: String?
    @State private var confirmError: String?

    // Sign In with Apple
    @State private var currentNonce: String?

    var canSubmit: Bool {
        if isSignUp {
            return !email.isEmpty && !password.isEmpty && !confirmPassword.isEmpty
        } else {
            return !email.isEmpty && !password.isEmpty
        }
    }

    var body: some View {
        ZStack {
            ChronosTheme.ink.ignoresSafeArea()

            RadialGradient(
                colors: [ChronosTheme.gold.opacity(0.06), .clear],
                center: .center, startRadius: 0, endRadius: 320
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer().frame(height: 52)

                    // ── Logo ──
                    VStack(spacing: 0) {
                        ChronosLogoMark()
                            .frame(width: 80, height: 80)
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : 16)
                            .animation(.easeOut(duration: 0.8).delay(0.1), value: appeared)

                        VStack(spacing: 6) {
                            Text("CHRONOS")
                                .font(.cormorant(size: 44))
                                .foregroundColor(ChronosTheme.text)
                                .tracking(10)

                            Text("BY MYND & BODI INSTITUTE")
                                .font(.jost(size: 9, weight: .light))
                                .foregroundColor(ChronosTheme.gold)
                                .tracking(4)

                            Rectangle()
                                .fill(LinearGradient(
                                    colors: [.clear, ChronosTheme.gold, .clear],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: 120, height: 1)
                                .padding(.top, 10)

                            Text("Know your body. Own your health.")
                                .font(.cormorantItalic(size: 15))
                                .foregroundColor(ChronosTheme.muted)
                                .padding(.top, 8)
                        }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)
                        .animation(.easeOut(duration: 0.8).delay(0.3), value: appeared)
                    }
                    .padding(.bottom, 44)

                    // ── Screen headline ──
                    Text(isSignUp ? "Create your account." : "Welcome back.")
                        .font(.cormorant(size: 26, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 20)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.6).delay(0.4), value: appeared)

                    // ── Form fields ──
                    VStack(spacing: 0) {
                        // Email
                        VStack(alignment: .leading, spacing: 4) {
                            ChronosTextField(
                                placeholder: "Email address",
                                text: $email,
                                keyboardType: .emailAddress
                            )
                            if let err = emailError {
                                Text(err)
                                    .font(.jost(size: 11, weight: .light))
                                    .foregroundColor(Color(red: 0.9, green: 0.65, blue: 0.2))
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.bottom, 12)

                        // Password
                        VStack(alignment: .leading, spacing: 4) {
                            ChronosSecureField(
                                placeholder: "Password",
                                text: $password
                            )
                            if let err = passwordError {
                                Text(err)
                                    .font(.jost(size: 11, weight: .light))
                                    .foregroundColor(Color(red: 0.9, green: 0.65, blue: 0.2))
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.bottom, 12)

                        // Confirm password — sign-up only
                        if isSignUp {
                            VStack(alignment: .leading, spacing: 4) {
                                ChronosSecureField(
                                    placeholder: "Confirm password",
                                    text: $confirmPassword
                                )
                                if let err = confirmError {
                                    Text(err)
                                        .font(.jost(size: 11, weight: .light))
                                        .foregroundColor(Color(red: 0.9, green: 0.65, blue: 0.2))
                                        .padding(.horizontal, 4)
                                }
                            }
                            .padding(.bottom, 12)

                            // Trust signal
                            Text("We don't sell your data. Delete your account anytime.")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 16)
                        }
                    }
                    .padding(.horizontal, 32)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.5), value: appeared)

                    // ── Global error ──
                    if let error = errorMessage {
                        Text(error)
                            .font(.jost(size: 12, weight: .light))
                            .foregroundColor(.red.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 8)
                    }

                    // ── CTA block ──
                    VStack(spacing: 16) {
                        // Primary button
                        Button(action: submit) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(ChronosTheme.text)
                                    .frame(height: 52)

                                if isLoading {
                                    ProgressView().tint(ChronosTheme.ink)
                                } else {
                                    Text(isSignUp ? "Create Account" : "Sign In")
                                        .font(.jost(size: 14, weight: .medium))
                                        .foregroundColor(ChronosTheme.ink)
                                        .tracking(2)
                                        .textCase(.uppercase)
                                }
                            }
                        }
                        .disabled(isLoading || !canSubmit)
                        .opacity(!canSubmit ? 0.45 : 1)

                        // ── or divider ──
                        HStack(spacing: 12) {
                            Rectangle().fill(ChronosTheme.border).frame(height: 1)
                            Text("or")
                                .font(.jost(size: 11, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                                .fixedSize()
                            Rectangle().fill(ChronosTheme.border).frame(height: 1)
                        }

                        // ── Sign in with Apple ──
                        SignInWithAppleButton(
                            isSignUp ? .signUp : .signIn
                        ) { request in
                            let nonce = randomNonceString()
                            currentNonce = nonce
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = sha256(nonce)
                        } onCompletion: { result in
                            switch result {
                            case .success(let auth):
                                guard
                                    let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                                    let tokenData  = credential.identityToken,
                                    let idToken    = String(data: tokenData, encoding: .utf8)
                                else { return }
                                Task { await handleAppleSignIn(idToken: idToken) }
                            case .failure:
                                break  // user cancelled — no error shown
                            }
                        }
                        .signInWithAppleButtonStyle(.white)
                        .frame(height: 52)
                        .cornerRadius(12)
                        .disabled(isLoading)

                        // Terms line — sign-up only
                        if isSignUp {
                            HStack(spacing: 4) {
                                Text("By continuing, you agree to our")
                                    .font(.jost(size: 11, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                                Button(action: { showTerms = true }) {
                                    Text("Terms of Service")
                                        .font(.jost(size: 11, weight: .light))
                                        .foregroundColor(ChronosTheme.muted)
                                        .underline()
                                }
                                Text("and")
                                    .font(.jost(size: 11, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                                Button(action: { showPrivacy = true }) {
                                    Text("Privacy Policy")
                                        .font(.jost(size: 11, weight: .light))
                                        .foregroundColor(ChronosTheme.muted)
                                        .underline()
                                }
                                Text(".")
                                    .font(.jost(size: 11, weight: .light))
                                    .foregroundColor(ChronosTheme.faint)
                            }
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        // Toggle sign-up / sign-in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isSignUp.toggle()
                            }
                            clearErrors()
                        }) {
                            Text(isSignUp
                                 ? "Already have an account? Sign in"
                                 : "New here? Create account")
                                .font(.jost(size: 13, weight: .light))
                                .foregroundColor(ChronosTheme.muted)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 12)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.6), value: appeared)

                    Spacer().frame(height: 52)

                    // Footer
                    Text("Chronos · MBI · Confidential")
                        .font(.jost(size: 9, weight: .light))
                        .foregroundColor(ChronosTheme.faint)
                        .tracking(2)
                        .padding(.bottom, 32)
                        .opacity(appeared ? 1 : 0)
                        .animation(.easeOut(duration: 0.6).delay(0.8), value: appeared)
                }
            }
        }
        .onAppear { appeared = true }
        // Terms sheet — in-app native viewer (no external URL required)
        .sheet(isPresented: $showTerms) {
            PolicyView(document: .termsOfService)
        }
        // Privacy sheet — in-app native viewer
        .sheet(isPresented: $showPrivacy) {
            PolicyView(document: .privacyPolicy)
        }
    }

    // ── Validation & submit ──

    private func clearErrors() {
        emailError    = nil
        passwordError = nil
        confirmError  = nil
        errorMessage  = nil
        confirmPassword = ""
    }

    private func validate() -> Bool {
        var valid = true
        emailError    = nil
        passwordError = nil
        confirmError  = nil

        // Email format
        if !email.contains("@") || !email.contains(".") {
            emailError = "Invalid email format."
            valid = false
        }

        // Password length
        if password.count < 8 {
            passwordError = "Password must be at least 8 characters."
            valid = false
        }

        // Confirm match — sign-up only
        if isSignUp && password != confirmPassword {
            confirmError = "Passwords do not match."
            valid = false
        }

        return valid
    }

    private func submit() {
        errorMessage = nil
        guard validate() else { return }

        isLoading = true
        Task {
            do {
                if isSignUp {
                    _ = try await supabase.signUp(email: email, password: password)
                } else {
                    _ = try await supabase.signIn(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    // MARK: - Sign In with Apple

    private func handleAppleSignIn(idToken: String) async {
        errorMessage = nil
        isLoading    = true
        do {
            _ = try await supabase.signInWithApple(idToken: idToken, nonce: currentNonce)
        } catch {
            errorMessage = "Apple sign in failed. Please try again."
        }
        isLoading    = false
        currentNonce = nil
    }

    /// Generates a cryptographically random nonce string.
    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        return randomBytes.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA256 hash of a string — sent to Apple as the nonce, verified by Supabase.
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed    = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// ─────────────────────────────────────────
// SAFARI SHEET — in-app browser for Terms / Privacy
// ─────────────────────────────────────────

import SafariServices

struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.preferredControlTintColor = UIColor(
            red: 0.722, green: 0.580, blue: 0.416, alpha: 1.0
        )
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// ─────────────────────────────────────────
// CHRONOS LOGO MARK
// ─────────────────────────────────────────

struct ChronosLogoMark: View {
    @State private var arcProgress: CGFloat = 0
    @State private var rotating = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(ChronosTheme.gold.opacity(0.15), lineWidth: 1)
                .frame(width: 80, height: 80)

            Circle()
                .trim(from: 0, to: arcProgress * 0.75)
                .stroke(
                    LinearGradient(
                        colors: [ChronosTheme.gold.opacity(0.3), ChronosTheme.goldLight],
                        startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .frame(width: 80, height: 80)
                .rotationEffect(.degrees(-90))

            Circle()
                .stroke(ChronosTheme.gold.opacity(0.08), lineWidth: 1)
                .frame(width: 52, height: 52)

            Circle()
                .fill(ChronosTheme.gold.opacity(0.9))
                .frame(width: 5, height: 5)

            Rectangle()
                .fill(ChronosTheme.gold.opacity(0.9))
                .frame(width: 1.5, height: 20)
                .offset(y: -10)
                .rotationEffect(.degrees(rotating ? 360 : 0))
                .animation(.linear(duration: 60).repeatForever(autoreverses: false), value: rotating)

            Rectangle()
                .fill(ChronosTheme.gold.opacity(0.4))
                .frame(width: 1, height: 12)
                .offset(y: -8)
                .rotationEffect(.degrees(rotating ? 360 * 12 : 0))
                .animation(.linear(duration: 60).repeatForever(autoreverses: false), value: rotating)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).delay(0.2)) { arcProgress = 1 }
            rotating = true
        }
    }
}

// ─────────────────────────────────────────
// CHRONOS TEXT FIELD
// ─────────────────────────────────────────

struct ChronosTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var isSecure: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.06, green: 0.06, blue: 0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(ChronosTheme.border, lineWidth: 1)
                )
                .frame(height: 52)

            if isSecure {
                SecureField("", text: $text)
                    .placeholder(when: text.isEmpty) {
                        Text(placeholder)
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                    .padding(.horizontal, 16)
                    .autocorrectionDisabled()
            } else {
                TextField("", text: $text)
                    .placeholder(when: text.isEmpty) {
                        Text(placeholder)
                            .font(.jost(size: 13, weight: .light))
                            .foregroundColor(ChronosTheme.faint)
                    }
                    .font(.jost(size: 13, weight: .light))
                    .foregroundColor(ChronosTheme.text)
                    .keyboardType(keyboardType)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
            }
        }
    }
}

// ─────────────────────────────────────────
// CHRONOS SECURE FIELD — with show/hide toggle
// PDR Screen 3.1: password fields have show/hide toggle
// ─────────────────────────────────────────

struct ChronosSecureField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isVisible = false

    var body: some View {
        ZStack(alignment: .trailing) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(red: 0.06, green: 0.06, blue: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(ChronosTheme.border, lineWidth: 1)
                    )
                    .frame(height: 52)

                if isVisible {
                    TextField("", text: $text)
                        .placeholder(when: text.isEmpty) {
                            Text(placeholder)
                                .font(.jost(size: 13, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                        }
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 16)
                        .padding(.trailing, 44)
                } else {
                    SecureField("", text: $text)
                        .placeholder(when: text.isEmpty) {
                            Text(placeholder)
                                .font(.jost(size: 13, weight: .light))
                                .foregroundColor(ChronosTheme.faint)
                        }
                        .font(.jost(size: 13, weight: .light))
                        .foregroundColor(ChronosTheme.text)
                        .padding(.horizontal, 16)
                        .padding(.trailing, 44)
                }
            }

            // Show/hide toggle
            Button(action: { isVisible.toggle() }) {
                Image(systemName: isVisible ? "eye.slash" : "eye")
                    .font(.system(size: 13, weight: .ultraLight))
                    .foregroundColor(ChronosTheme.faint)
            }
            .padding(.trailing, 16)
        }
    }
}

// ─────────────────────────────────────────
// SOCIAL AUTH BUTTON — kept for legacy refs
// Not rendered in Phase 1 (SSO deferred)
// ─────────────────────────────────────────

struct SocialAuthButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .light))
                Text(label)
                    .font(.jost(size: 13, weight: .light))
                    .tracking(0.5)
            }
            .foregroundColor(ChronosTheme.muted)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(ChronosTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(ChronosTheme.border, lineWidth: 1)
                    )
            )
        }
    }
}

// ─────────────────────────────────────────
// PLACEHOLDER HELPER
// ─────────────────────────────────────────

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: .leading) {
            if shouldShow { placeholder() }
            self
        }
    }
}

// ─────────────────────────────────────────
// LEGACY — MBITextField kept for other views
// ─────────────────────────────────────────

struct MBITextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default
    var isSecure: Bool = false

    var body: some View {
        ChronosTextField(
            placeholder: placeholder,
            text: $text,
            keyboardType: keyboardType,
            isSecure: isSecure
        )
    }
}
