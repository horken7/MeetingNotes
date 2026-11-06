import Foundation
import MeetingCore

/// Sample meetings for the simulator and screenshots (launch with `-demo`), since speech recognition and
/// Apple Intelligence don't run in the iOS Simulator.
enum DemoData {
    static func seed(in store: MeetingStore) {
        guard store.loadAll().isEmpty else { return }
        let now = Date()
        add(store, title: "Veckomöte produkt", date: now.addingTimeInterval(-3600 * 26), lang: "sv", notes: """
        ## Sammanfattning
        Teamet gick igenom läget inför lanseringen i december. Betaversionen är klar och testas av tio kunder. **Prissättningen** behöver bestämmas innan nästa vecka.

        ## Beslut
        - Lanseringen flyttas till 9 december.
        - Vi börjar med en månadsplan och lägger till årsplan senare.

        ## Att göra
        - [ ] Anna: skicka prisförslaget till ledningen före fredag
        - [ ] Johan: sammanställa feedback från betakunderna
        - [x] Boka lokal för lanseringen

        ## Öppna frågor
        - Ska vi erbjuda rabatt till betakunderna?

        ## Viktiga punkter
        - **Beta:** tio kunder, mest positiv feedback om exporten.
        - **Support:** två nya frågor om inloggning.
        """, transcript: """
        [0:00] **Speaker:** Okej, ska vi börja? Första punkten är lanseringen.

        [0:12] **Speaker:** Betan är ute hos tio kunder nu och feedbacken är mest positiv, särskilt om exporten.

        [1:05] **Speaker:** Jag föreslår att vi flyttar lanseringen till nionde december så hinner vi fixa inloggningen.

        [1:40] **Speaker:** Det låter bra. Anna, kan du skicka prisförslaget till ledningen före fredag?
        """)
        add(store, title: "Customer call prep", date: now.addingTimeInterval(-3600 * 72), lang: "en", notes: """
        ## Summary
        Short prep for Thursday's customer workshop. The agenda is set and the demo runs on the new build.

        ## Action items
        - [ ] Send the agenda to the customer
        - [ ] Test the demo on the projector

        ## Key points
        - Keep the workshop to two hours.
        """, transcript: """
        [0:00] **Speaker:** Let's go through the agenda for Thursday.

        [0:30] **Speaker:** I'll run the demo on the new build, and we'll keep it to two hours.
        """)
    }

    private static func add(_ store: MeetingStore, title: String, date: Date, lang: String, notes: String, transcript: String) {
        guard let folder = try? store.newFolder(title: title, date: date) else { return }
        MeetingStore.writeMeta(Meta(title: title, created: date, status: "done", lang: lang, duration: 1260), to: folder)
        try? MeetingStore.writeNotes(notes, title: title, to: folder)
        try? MeetingStore.writeTranscript(transcript, title: title, to: folder)
    }
}
