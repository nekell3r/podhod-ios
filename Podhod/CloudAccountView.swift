import SwiftUI

struct CloudAccountView: View {
    @Bindable var auth: CloudAuthentication
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Аккаунт", systemImage: auth.signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                .font(.system(.title2, design: .rounded).bold())
            VStack(alignment: .leading, spacing: 7) {
                Text(auth.status).font(.subheadline.weight(.semibold))
                Text(auth.serverURL.host ?? auth.serverURL.absoluteString)
                    .font(.caption).foregroundStyle(Color.gymMuted).textSelection(.enabled)
            }
            if auth.isBusy {
                HStack(spacing: 10) {
                    SwiftUI.ProgressView()
                    Text("Пожалуйста, подожди…").font(.caption).foregroundStyle(Color.gymMuted)
                }
            }
            if let error = auth.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if auth.signedIn {
                if let details = auth.accountDetails {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(details.profile.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                        if let username = details.profile.username, username != details.profile.displayName {
                            Text("Логин: \(username)").font(.caption).foregroundStyle(Color.gymMuted)
                        }
                        Label(details.telegram?.connected == true ? "Telegram подключён" : "Telegram не подключён",
                              systemImage: details.telegram?.connected == true ? "checkmark.circle.fill" : "paperplane")
                            .font(.subheadline).foregroundStyle(details.telegram?.connected == true ? Color.gymLime : .gymMuted)
                        if details.telegram?.connected == true, let username = details.telegram?.linkedUsername, !username.isEmpty {
                            Text("Аккаунт Telegram: \(username)").font(.caption).foregroundStyle(Color.gymMuted).textSelection(.enabled)
                        }
                    }
                }
                if auth.profileLoading { SwiftUI.ProgressView("Обновляем профиль…").font(.caption) }
                if let error = auth.profileError { Text(error).font(.caption).foregroundStyle(.red) }
                Button("Обновить профиль") { Task { await auth.refreshProfile() } }
                    .font(.subheadline.weight(.semibold)).disabled(auth.profileLoading)
                Button(auth.accountDetails?.telegram?.connected == true ? "Управлять привязкой Telegram" : "Привязать Telegram к аккаунту") {
                    Task { if let url = await auth.accountManagementURL() { openURL(url) } }
                }.font(.subheadline.weight(.semibold)).disabled(auth.isBusy)
                if let details = auth.accountDetails, details.telegram?.connected != true {
                    Text("В кабинете подтверди аккаунт \(details.profile.username ?? details.profile.displayName), затем открой привязку Telegram.")
                        .font(.caption).foregroundStyle(Color.gymMuted)
                }
                Button("Отключить аккаунт", role: .destructive) {
                    Task { await auth.signOut() }
                }.font(.subheadline.weight(.semibold)).disabled(auth.isBusy)
            } else {
                Button {
                    Task { await auth.signInWithTelegram() }
                } label: { Label("Войти через Telegram", systemImage: "paperplane") }
                    .buttonStyle(PrimaryButton()).disabled(auth.isBusy)
                Button("Войти по логину") { Task { await auth.signIn() } }
                    .font(.subheadline.weight(.semibold)).disabled(auth.isBusy)
                Text("Уже пользуешься «Подходом»? Войди прежним способом и привяжи Telegram в настройках аккаунта — тогда история останется в том же аккаунте.")
                    .font(.caption).foregroundStyle(Color.gymMuted).lineSpacing(3)
            }
            Text("Вход откроется в системном браузере. Выход сохраняет архив аккаунта отдельно и открывает гостевой режим. Затем можно войти в другой аккаунт.")
                .font(.caption).foregroundStyle(Color.gymMuted).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
            .task(id: auth.sessionID) { await auth.refreshProfile() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await auth.refreshProfile() } }
            }
    }
}
