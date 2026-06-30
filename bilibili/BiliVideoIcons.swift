import SwiftUI

enum BiliTheme {
    static let blue = Color(red: 0, green: 174 / 255, blue: 236 / 255)
    static let pink = Color(red: 251 / 255, green: 114 / 255, blue: 153 / 255)
    static let actionInactive = Color(red: 153 / 255, green: 153 / 255, blue: 153 / 255)
    static let videoControlBorder = Color(red: 153 / 255, green: 153 / 255, blue: 153 / 255).opacity(0.5)
}

enum BiliIcon: String {
    case like = "ic_bili_like"
    case coin = "ic_bili_coin"
    case favorite = "ic_bili_favorite"
    case share = "ic_bili_share"
    case play = "ic_bili_play"
    case danmaku = "ic_bili_danmaku"
}

struct BiliIconView: View {
    let icon: BiliIcon
    var color: Color = BiliTheme.actionInactive
    var size: CGFloat = 24

    var body: some View {
        Image(icon.rawValue)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}

struct BiliStatLabel: View {
    let icon: BiliIcon
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            BiliIconView(icon: icon, color: BiliTheme.actionInactive, size: 16)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct VideoDetailActionBar: View {
    let likeCount: Int64
    let coinCount: Int64
    let favoriteCount: Int64
    let shareCount: Int64
    var liked = false
    var coined = false
    var favorited = false

    var body: some View {
        HStack(spacing: 0) {
            VideoDetailActionItem(
                icon: .like,
                label: likeCount.compactCount,
                tint: liked ? BiliTheme.blue : BiliTheme.actionInactive
            )
            VideoDetailActionItem(
                icon: .coin,
                label: coinCount.compactCount,
                tint: coined ? BiliTheme.blue : BiliTheme.actionInactive
            )
            VideoDetailActionItem(
                icon: .favorite,
                label: favoriteCount.compactCount,
                tint: favorited ? BiliTheme.blue : BiliTheme.actionInactive
            )
            VideoDetailActionItem(
                icon: .share,
                label: shareCount.compactCount,
                tint: BiliTheme.actionInactive
            )
        }
    }
}

private struct VideoDetailActionItem: View {
    let icon: BiliIcon
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            BiliIconView(icon: icon, color: tint, size: 24)
                .frame(width: 34, height: 34)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint == BiliTheme.blue ? BiliTheme.blue : .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
