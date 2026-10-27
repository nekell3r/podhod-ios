import SwiftUI

struct CloudAccountView: View {
    @Bindable var auth: CloudAuthentication
    @Environment(\.openURL) private var openURL

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
                Button("Привязать Telegram к аккаунту") {
                    Task { if let url = await auth.accountManagementURL() { openURL(url) } }
                }.font(.subheadline.weight(.semibold)).disabled(auth.isBusy)
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
    }
}
