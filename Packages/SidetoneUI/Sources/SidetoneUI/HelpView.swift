import SwiftUI

/// Ships as part of the app per SPEC "Help content shipped in-app, not
/// as a link to a GitHub wiki." Every section is stand-alone so the
/// operator can jump to the answer they need without reading the
/// whole thing. Keep this terse — dense reference, not a novel.
public struct HelpView: View {
    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section("Getting started") {
                    NavigationLink("Setting up ardopcf") { HelpTopic.ardopcfSetup.view }
                    NavigationLink("Your first QSO") { HelpTopic.firstQSO.view }
                }

                Section("Stations") {
                    NavigationLink("The station roster") { HelpTopic.roster.view }
                    NavigationLink("Pinging and link quality") { HelpTopic.ping.view }
                }

                Section("Messages & files") {
                    NavigationLink("Sending text") { HelpTopic.sendText.view }
                    NavigationLink("File attachments") { HelpTopic.attachments.view }
                }

                Section("Multi-device setup") {
                    NavigationLink("Running a Sidetone server") { HelpTopic.server.view }
                    NavigationLink("Pairing iPad or iPhone") { HelpTopic.pairing.view }
                }

                Section("Troubleshooting") {
                    NavigationLink("ardopcf won't connect") { HelpTopic.troubleArdop.view }
                    NavigationLink("Other station can't hear me") { HelpTopic.troubleRadio.view }
                }
            }
            .navigationTitle("Sidetone Help")
        }
    }
}

enum HelpTopic {
    case ardopcfSetup, firstQSO, roster, ping, sendText, attachments, server, pairing, troubleArdop, troubleRadio

    @ViewBuilder var view: some View {
        switch self {
        case .ardopcfSetup:
            HelpPage(title: "Setting up ardopcf") {
                Text("Sidetone is the graphical interface; ardopcf is the DSP and radio-facing daemon. You need to install and run ardopcf separately.")
                Text("On macOS, the easiest route is Homebrew:")
                HelpCode("brew install ardopcf")
                Text("Launch ardopcf pointed at your radio's audio device. The defaults work for most setups:")
                HelpCode("ardopcf 8515 \"YourSoundDevice\" \"YourSoundDevice\"")
                Text("Then open Sidetone, enter your callsign and grid, and point it at 127.0.0.1:8515.")
            }
        case .firstQSO:
            HelpPage(title: "Your first QSO") {
                Text("1. Tune your radio to an ARDOP frequency — 14.106 MHz USB-D is a popular call channel.")
                Text("2. Toggle Listen (Connection → Listen) to start hearing CQs.")
                Text("3. When someone calls you — or you want to call someone — use Connection → Connect to Station… (⌘K). Pick a bandwidth that fits the band conditions. 500 Hz is a reliable starting point.")
                Text("4. Type in the composer. Enter sends; Shift+Enter adds a newline. Over HF, every byte counts: keep messages short.")
            }
        case .roster:
            HelpPage(title: "The station roster") {
                Text("The sidebar shows three kinds of stations:")
                Text("• **Stations** — people you've saved. Green dot means heard recently, gold means in session with them, gray means not heard this session.")
                Text("• **Heard** — stations whose ID beacons you've received in the last hour. Swipe on iOS or use the context menu on Mac to save them.")
                Text("• **+ New…** — type a callsign manually. Useful for calling someone you know is on the air but whose ID you haven't heard.")
            }
        case .ping:
            HelpPage(title: "Pinging and link quality") {
                Text("A ping is a short, fast frame that measures whether you can make an ARQ connection. The other station answers with SNR and quality numbers that you see in the inspector pane.")
                Text("Quality under 30 means the path probably won't hold an ARQ session. 30–60 is marginal. Over 60 is a good path.")
                Text("Keyboard shortcut: ⌘⇧P.")
            }
        case .sendText:
            HelpPage(title: "Sending text") {
                Text("Type in the composer and press Return (Mac/iPad with a keyboard) or tap Send. The character counter warns you when a message will take a long time to send; short messages are more likely to get through on poor conditions.")
                Text("The transcript is saved per station, so when you reconnect tomorrow you'll have the history of your last QSO to refer to.")
            }
        case .attachments:
            HelpPage(title: "File attachments") {
                Text("The paperclip button attaches a file. Pick something small — 10 KB sends in a couple of minutes on a good link, 100 KB takes half an hour.")
                Text("Sidetone warns if the file is over 512 KB. For images, shrink before attaching.")
                Text("Attachments resume automatically if the connection drops and you reconnect.")
            }
        case .server:
            HelpPage(title: "Running a Sidetone server") {
                Text("A Sidetone server is the same Mac app running alongside a local ardopcf. It advertises itself on your network via Bonjour so iPads and iPhones can find it without IP addresses.")
                Text("Pairing is enabled from the server's menu: Connection → Enable pairing. A 6-digit code is displayed for 5 minutes.")
                Text("Each paired device gets its own persistent token, stored in that device's Keychain. You can revoke an individual device from Settings without affecting the others.")
            }
        case .pairing:
            HelpPage(title: "Pairing iPad or iPhone") {
                Text("On the Mac/Pi running Sidetone, generate a pairing code.")
                Text("On the iPad/iPhone, open Sidetone, choose 'Add Sidetone server', pick the server from the Bonjour list, and enter the code.")
                Text("The device is now paired and will reconnect automatically as long as it's on the same network.")
            }
        case .troubleArdop:
            HelpPage(title: "ardopcf won't connect") {
                Text("Check that ardopcf is actually running. From a terminal:")
                HelpCode("lsof -i:8515")
                Text("Should show ardopcf listening. If nothing's there, launch ardopcf first.")
                Text("If something else is running on 8515, change the port in Sidetone's setup — both ardopcf and Sidetone need to agree.")
            }
        case .troubleRadio:
            HelpPage(title: "Other station can't hear me") {
                Text("Watch the inspector while you transmit. PTT should go red. If it doesn't, your radio isn't keying — check CAT/VOX setup.")
                Text("If PTT fires but nobody hears you, your audio level from the computer to the radio is probably too low. ardopcf logs the audio level — check those first.")
                Text("If you're on a band with interference, try a narrower ARQ bandwidth (200 Hz) — slower, but more robust.")
            }
        }
    }
}

private struct HelpPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(maxWidth: 600, alignment: .leading)
        }
        .navigationTitle(title)
    }
}

private struct HelpCode: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.body.monospaced())
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
            .accessibilityLabel("Terminal command: \(text)")
    }
}
