import SwiftUI

// MARK: - Navigation

enum AppScreen { case signIn, home, room }

// MARK: - Sync State

enum SyncState: Equatable {
    case idle, loading, playing, paused, outOfSync, disconnected

    var labelJa: String {
        switch self {
        case .idle:         return "ホスト選曲待ち"
        case .loading:      return "読み込み中"
        case .playing:      return "同期中"
        case .paused:       return "一時停止"
        case .outOfSync:    return "補正中"
        case .disconnected: return "再接続中"
        }
    }

    var labelEn: String {
        switch self {
        case .idle:         return "awaiting host"
        case .loading:      return "loading"
        case .playing:      return "in sync"
        case .paused:       return "paused"
        case .outOfSync:    return "realigning"
        case .disconnected: return "reconnecting"
        }
    }

    var color: Color {
        switch self {
        case .idle:                  return .pairtuneTextTertiary
        case .loading, .outOfSync:  return .pairtuneSyncWarn
        case .playing:              return .pairtuneSyncOk
        case .paused:               return .pairtuneTextSecondary
        case .disconnected:         return .pairtuneSyncBad
        }
    }

    var pulses: Bool {
        switch self {
        case .loading, .outOfSync, .disconnected: return true
        default: return false
        }
    }
}

// MARK: - Track

struct Track: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Int // seconds
    let gradientStops: [Gradient.Stop]
    let dominant: Color
    var artworkURL: URL? = nil
    /// Apple Music Album ID(`relationships.albums.data[].id`)。
    /// TrackContextMenu「アルバムを見る」で AlbumDetailView へ push する時に使う。
    var albumId: String? = nil
    /// Apple Music Artist ID(`relationships.artists.data[].id`)。
    /// TrackContextMenu「アーティストを見る」で ArtistDetailView へ push する時に使う。
    var artistId: String? = nil

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
}

// MARK: - Participant

enum ParticipantRole { case host, guest }

struct Participant: Identifiable {
    let id: String
    let name: String
    let nameJa: String
    let role: ParticipantRole
    let color: Color
    let initials: String
}

// MARK: - Time formatting

func fmt(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

// MARK: - Mock data

let mockTrack = Track(
    id: "t1",
    title: "Never Goodbye",
    artist: "NCT DREAM",
    album: "DREAM( )SCAPE",
    duration: 217,
    gradientStops: [
        .init(color: Color(hex: "FF5A6E"), location: 0.00),
        .init(color: Color(hex: "B83C5E"), location: 0.30),
        .init(color: Color(hex: "4A1D3D"), location: 0.70),
        .init(color: Color(hex: "1A0E1F"), location: 1.00),
    ],
    dominant: Color(hex: "FF5A6E")
)

let mockCode = "KTOMSO"

let mockParticipants: [Participant] = [
    Participant(id: "me",  name: "You", nameJa: "あなた", role: .host,  color: .pairtuneCoral,          initials: "YO"),
    Participant(id: "aoi", name: "Aoi", nameJa: "あおい", role: .guest, color: Color(hex: "7BD389"),  initials: "AO"),
    Participant(id: "ren", name: "Ren", nameJa: "れん",   role: .guest, color: Color(hex: "6BB6F0"),  initials: "RE"),
    Participant(id: "mio", name: "Mio", nameJa: "みお",   role: .guest, color: Color(hex: "F4C26A"),  initials: "MI"),
    Participant(id: "kai", name: "Kai", nameJa: "かい",   role: .guest, color: Color(hex: "C49AF4"),  initials: "KA"),
]

