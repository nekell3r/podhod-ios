import SwiftUI

struct CloudAccountView: View {
    @Bindable var auth: CloudAuthentication

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
                Button("Отключить аккаунт", role: .destructive) {
                    Task { await auth.signOut() }
                }.font(.subheadline.weight(.semibold)).disabled(auth.isBusy)
            } else {
                Button {
                    Task { await auth.signIn() }
                } label: { Label("Войти в аккаунт", systemImage: "person.crop.circle") }
                    .buttonStyle(PrimaryButton()).disabled(auth.isBusy)
            }
            Text("Вход откроется в системном браузере. Выход из аккаунта не удаляет записи тренировок с этого iPhone.")
                .font(.caption).foregroundStyle(Color.gymMuted).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading).modifier(GymCard())
    }
}
