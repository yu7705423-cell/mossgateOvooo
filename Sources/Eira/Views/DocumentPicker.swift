import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 选文件。不用 SwiftUI 的 `.fileImporter`：它挂在推进来的页面（NavigationLink 的目标）上时，
/// 在真机上点了文件常常没有回调，表现为「点了没反应」。这里直接用 UIKit 的文件选择器，
/// 以副本方式打开（asCopy），选中的文件先抄进本机的临时目录，之后读它不再需要访问授权，
/// iCloud 里还没下载的文件也由系统先下载好再交过来。
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType]
    var multiple = false
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        vc.allowsMultipleSelection = multiple
        vc.shouldShowFileExtensions = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick([])
        }
    }
}

extension View {
    /// 弹出文件选择器；选中后回调一次，取消只收起、不回调。
    func documentPicker(isPresented: Binding<Bool>, types: [UTType], multiple: Bool = false,
                        onPick: @escaping ([URL]) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(types: types, multiple: multiple) { urls in
                isPresented.wrappedValue = false
                guard !urls.isEmpty else { return }
                // 等选择器收起再交出去，免得接下来的界面变化与收起的动画撞在一起
                DispatchQueue.main.async { onPick(urls) }
            }
            .ignoresSafeArea()
        }
    }
}
