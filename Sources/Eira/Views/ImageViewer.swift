import Photos
import SwiftUI

/// 看大图：双指缩放、双击放大或复原；可以存到照片、分享。
struct ImageViewer: View {
    let imageId: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var notice: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LocalImage(id: imageId, maxPixel: 4096, fit: true)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in scale = max(1, min(6, lastScale * v.magnification)) }
                        .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } }
                        .simultaneously(with: DragGesture()
                            .onChanged { v in
                                guard scale > 1 else { return }
                                offset = CGSize(width: lastOffset.width + v.translation.width,
                                                height: lastOffset.height + v.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset })
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 }
                        lastScale = scale; lastOffset = offset
                    }
                }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title3) }
                    .accessibilityLabel("关闭")
                Spacer()
                if let url = MediaStore.url(.images, id: imageId) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up").font(.title3) }
                        .accessibilityLabel("分享")
                }
                Button(action: save) { Image(systemName: "arrow.down.to.line").font(.title3) }
                    .accessibilityLabel("存到照片")
                    .padding(.leading, Theme.pad)
            }
            .foregroundStyle(.white)
            .padding(Theme.pad)
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.white)
                    .padding(Theme.pad).background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, Theme.pad * 3)
            }
        }
    }

    /// 存到「照片」。只要「添加照片」这一项权限，不读相册。
    private func save() {
        guard let url = MediaStore.url(.images, id: imageId) else { notice = "这张图片的文件不存在"; return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in notice = "没有添加照片的权限。可在「设置 - Eiraowo - 照片」中开启。" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
            }) { ok, error in
                Task { @MainActor in notice = ok ? "已存到照片" : "保存失败：\(error?.localizedDescription ?? "未知原因")" }
            }
        }
    }
}
