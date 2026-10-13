import Foundation
import Testing
@testable import AlexaKit

@Suite("Search phrasing")
struct SearchPhrasingTests {
    @Test func classicalMovementUsesMovementWorkAndPerformer() {
        // Real case: the full title + credits made Alexa play nothing; these all found the right recording.
        let candidates = SearchPhrasing.songCandidates(
            title: #"Songs from "Friday Afternoons", Op. 7: Cuckoo!"#,
            artist: "Choir of Downside School, Purley, Benjamin Britten & Viola Tunnard",
            album: "Britten - The Masterpieces"
        )
        #expect(candidates == [
            "Cuckoo from Friday Afternoons by Choir of Downside School",
            "Cuckoo by Choir of Downside School",
            "Cuckoo by Benjamin Britten",
        ])
    }

    @Test func symphonyMovementDropsNumberingAndOpus() {
        let parts = SearchPhrasing.movement(of: "Symphony No. 5 in C Minor, Op. 67: I. Allegro con brio")
        #expect(parts?.movement == "Allegro con brio")
        #expect(parts?.work == "Symphony No. 5 in C Minor")
    }

    @Test func popSongsKeepTheNaturalPhrase() {
        #expect(SearchPhrasing.songCandidates(title: "Better Together", artist: "Jack Johnson", album: "In Between Dreams (Bonus Track Version)") == [
            "Better Together by Jack Johnson",
            "the song Better Together by Jack Johnson",
            "Better Together by Jack Johnson from the album In Between Dreams",
        ])
        #expect(SearchPhrasing.songCandidates(title: "Don't Stop Me Now", artist: "Queen", album: nil).first == "Don't Stop Me Now by Queen")
    }

    @Test func shortCreditsStayWhole() {
        #expect(SearchPhrasing.shortArtist("Earth, Wind & Fire") == "Earth, Wind & Fire")
        #expect(SearchPhrasing.shortArtist("Ashanti, Ja Rule & R. Kelly") == "Ashanti, Ja Rule & R. Kelly")
        #expect(SearchPhrasing.shortArtist("Choir of Downside School, Purley, Benjamin Britten & Viola Tunnard") == "Choir of Downside School")
    }

    @Test func removesThingsThatTripUpSearch() {
        #expect(SearchPhrasing.speakable(#"Cuckoo!"#) == "Cuckoo")
        #expect(SearchPhrasing.speakable(#"“Hello” - Live?"#) == "Hello Live")
        #expect(SearchPhrasing.removeCatalogNumbers("Cello Suite No. 1 in G Major, BWV 1007") == "Cello Suite No. 1 in G Major")
        #expect(SearchPhrasing.removeCatalogNumbers("Nocturne in E-Flat Major, Op. 9 No. 2") == "Nocturne in E-Flat Major")
        #expect(SearchPhrasing.removeCatalogNumbers("Eine kleine Nachtmusik, K. 525") == "Eine kleine Nachtmusik")
    }

    @Test func otherCreditSkipsPlaceFragments() {
        #expect(SearchPhrasing.otherCredit(in: "Choir of Downside School, Purley, Benjamin Britten & Viola Tunnard", excluding: "Choir of Downside School") == "Benjamin Britten")
        #expect(SearchPhrasing.otherCredit(in: "Queen", excluding: "Queen") == nil)
    }
}
