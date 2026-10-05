import SwiftUI
import StashCore

struct OnboardingView: View {
    let model: AppModel
    @State private var page = 0
    @State private var understood = false
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                TabView(selection: $page) {
                    infoPage(
                        icon: "lock.shield",
                        title: "Добро пожаловать в Stash",
                        text: "Менеджер паролей и документов, который работает полностью на вашем iPhone.",
                        tag: 0
                    )
                    infoPage(
                        icon: "wifi.slash",
                        title: "Только на этом устройстве",
                        text: "Данные хранятся только на этом iPhone и не уходят в интернет. Никакой аналитики и трекинга.",
                        tag: 1
                    )
                    VStack(spacing: 24) {
                        infoContent(
                            icon: "exclamationmark.triangle",
                            title: "Мастер-пароль нельзя восстановить",
                            text: "Если вы забудете мастер-пароль, данные пропадут безвозвратно. Мы не можем его сбросить."
                        )
                        Toggle("Я понимаю", isOn: $understood)
                            .padding(.horizontal)
                            .accessibilityHint("Подтвердите, что вы понимаете: пароль нельзя восстановить")
                    }
                    .tag(2)
                }
                .tabViewStyle(.page)
                .animation(.default, value: page)

                Button(action: advance) {
                    Text(page < 2 ? "Далее" : "Создать мастер-пароль")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(page == 2 && !understood)
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationDestination(isPresented: $showCreate) {
                CreatePasswordView(model: model)
            }
        }
    }

    private func advance() {
        if page < 2 {
            page += 1
        } else if understood {
            showCreate = true
        }
    }

    private func infoPage(icon: String, title: LocalizedStringKey, text: LocalizedStringKey, tag: Int) -> some View {
        infoContent(icon: icon, title: title, text: text).tag(tag)
    }

    private func infoContent(icon: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
}
