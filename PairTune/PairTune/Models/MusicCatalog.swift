import Foundation

struct Artist: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let artworkURL: URL?
    /// この artist.id が取得された Apple Music のストアフロント(例: "jp", "us")。
    /// nil の時は端末ロケールから推定する。クロスストアフロントで artist 詳細を
    /// 引く時の 404/500 を避けるため、検索結果からの遷移ではここに値が入る。
    var storefront: String? = nil
}

struct Album: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let artistName: String
    let artworkURL: URL?
    /// この album.id が取得された Apple Music のストアフロント。Artist と同じ理由で保持。
    var storefront: String? = nil
    /// true のとき AlbumDetailViewModel はプレイリストエンドポイントを使う。
    var isPlaylist: Bool = false
}

struct Playlist: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let curatorName: String
    let artworkURL: URL?
    var storefront: String? = nil
}
