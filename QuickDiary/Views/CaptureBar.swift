import PhotosUI
import SwiftUI
import Vision
import VisionKit

/// Quick capture under the editor, in thumb reach: your quick lists, weather, photo, camera, scan.
/// Every chip adds one Markdown line at the end of the note.
struct CaptureBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var quickLists: QuickListStore
    var append: (String) -> Void
    var onError: (String) -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showScanner = false
    @State private var showToday = false
    @State private var busy: String?
    @State private var added = 0

    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)
    private let scannerAvailable = VNDocumentCameraViewController.isSupported

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showToday = true } label: { chip("Today", symbol: "sun.max") }
                    .accessibilityIdentifier("quick-Today")
                ForEach(quickLists.lists) { list in
                    Menu {
                        ForEach(list.options, id: \.self) { option in
                            Button(option) { add(list.line(for: option)) }
                        }
                    } label: {
                        chip(list.name, symbol: list.symbol)
                    }
                    .accessibilityIdentifier("quick-\(list.name)")
                }
                Button(action: addWeather) {
                    chip("Weather", symbol: "cloud.sun", working: busy == "weather")
                }
                .accessibilityIdentifier("quick-Weather")
                PhotosPicker(selection: $photoItem, matching: .images) {
                    chip("Photo", symbol: "photo", working: busy == "photo")
                }
                if cameraAvailable {
                    Button { showCamera = true } label: { chip("Camera", symbol: "camera") }
                }
                if scannerAvailable {
                    Button { showScanner = true } label: {
                        chip("Scan", symbol: "doc.text.viewfinder", working: busy == "scan")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .disabled(busy != nil)
        .sensoryFeedback(.impact(weight: .light), trigger: added)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task { await addPhoto(item) }
        }
        .sheet(isPresented: $showToday) {
            TodaySheet(demo: model.options.isDemo) { add($0) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in addImage(image, alt: "Photo") }
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { pages in Task { await addScan(pages) } }
                .ignoresSafeArea()
        }
    }

    private func chip(_ title: String, symbol: String, working: Bool = false) -> some View {
        HStack(spacing: 6) {
            if working {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
            }
            Text(title)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(.fill.secondary, in: Capsule())
        .contentShape(Capsule())
    }

    private func add(_ line: String) {
        append(line)
        added += 1
    }

    private func addWeather() {
        busy = "weather"
        Task {
            defer { busy = nil }
            do {
                // Demo and UI tests: fixed weather, no location or network.
                let now: Weather.Now
                if model.options.isDemo {
                    now = Weather.demo
                } else {
                    now = try await Weather.current()
                }
                add(now.line)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func addImage(_ image: UIImage, alt: String) {
        do {
            add(try model.addImage(image, alt: alt))
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func addPhoto(_ item: PhotosPickerItem) async {
        busy = "photo"
        defer { busy = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            onError(String(localized: "This photo can't be read. Try another one."))
            return
        }
        addImage(image, alt: "Photo")
    }

    /// Each page is kept as an encrypted image, with its recognized text as a quote below it.
    private func addScan(_ pages: [UIImage]) async {
        busy = "scan"
        defer { busy = nil }
        for page in pages {
            addImage(page, alt: "Scan")
            let text = await TextRecognizer.text(in: page)
            if !text.isEmpty {
                add(text.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n"))
            }
        }
    }
}

enum TextRecognizer {
    /// On-device text recognition (Vision). Nothing leaves the phone.
    static func text(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            parent.onScan((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}
