import Foundation
import CoreGraphics

struct HeaderFooter: Codable, Equatable {
    var left = ""
    var center = ""
    var right = ""
    var isEmpty: Bool { left.isEmpty && center.isEmpty && right.isEmpty }
}

struct PaperSize: Hashable, Identifiable {
    let name: String
    let width: CGFloat
    let height: CGFloat
    var id: String { name }

    static let all: [PaperSize] = [
        PaperSize(name: "Letter", width: 612, height: 792),
        PaperSize(name: "Legal", width: 612, height: 1008),
        PaperSize(name: "Executive", width: 522, height: 756),
        PaperSize(name: "Tabloid", width: 792, height: 1224),
        PaperSize(name: "A3", width: 842, height: 1191),
        PaperSize(name: "A4", width: 595, height: 842),
        PaperSize(name: "A5", width: 420, height: 595),
    ]
}

/// Page setup plus header and footer content. Stored with the document.
struct LayoutSettings: Codable, Equatable {
    /// Portrait dimensions in points; `landscape` swaps them.
    var pageWidth: CGFloat = 612
    var pageHeight: CGFloat = 792
    var landscape = false
    var top: CGFloat = 72
    var bottom: CGFloat = 72
    var left: CGFloat = 72
    var right: CGFloat = 72
    var columns = 1
    var columnSpacing: CGFloat = 36
    var header = HeaderFooter()
    var footer = HeaderFooter()
    var headerDistance: CGFloat = 36
    var footerDistance: CGFloat = 36

    var effectiveSize: CGSize {
        landscape ? CGSize(width: pageHeight, height: pageWidth) : CGSize(width: pageWidth, height: pageHeight)
    }

    var paperName: String {
        PaperSize.all.first { $0.width == pageWidth && $0.height == pageHeight }?.name ?? "Custom"
    }

    var columnWidth: CGFloat {
        let n = CGFloat(max(1, columns))
        return max(36, (effectiveSize.width - left - right - (n - 1) * columnSpacing) / n)
    }

    var containerSize: CGSize {
        CGSize(width: columnWidth, height: max(36, effectiveSize.height - top - bottom))
    }
}
