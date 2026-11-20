import Foundation

/// AndroidX Palette's `ColorCutQuantizer`: a modified median cut over a
/// 15-bit (5 bits per channel) colour histogram.
///
/// 1. Every pixel is reduced to 5-5-5 RGB and counted; alpha is ignored.
/// 2. Histogram entries the filters reject are dropped before any box is cut,
///    so a filtered-out colour can't drag an average towards itself.
/// 3. If what's left already fits in `maxColors`, each distinct colour is its
///    own swatch. Otherwise boxes are split — always the one with the largest
///    *volume* in colour space, at the population median of its longest side —
///    until there are `maxColors` boxes or none can be split.
/// 4. Each box becomes a swatch: its population-weighted mean colour, and its
///    population. Means are filtered again, since averaging can land on a colour
///    no filter would have let through.
///
/// The Java `PriorityQueue` is reproduced heap-for-heap (``JavaPriorityQueue``)
/// because the output order *is* its internal array order, and callers pick
/// "the first swatch with the highest X" — equal-volume ties and swatch order
/// have to break the same way they do on Android.
enum ColorCutQuantizer {
    static let wordWidth = 5
    static let wordMask = (1 << wordWidth) - 1

    static func quantize(pixels: [UInt32], maxColors: Int, filters: [PaletteFilter]) -> [PaletteSwatch] {
        var histogram = [Int](repeating: 0, count: 1 << (wordWidth * 3))
        for pixel in pixels {
            histogram[quantizeFromRgb888(pixel)] += 1
        }

        var distinctColorCount = 0
        for color in 0..<histogram.count {
            if histogram[color] > 0 && shouldIgnore(color555: color, filters: filters) {
                histogram[color] = 0
            }
            if histogram[color] > 0 {
                distinctColorCount += 1
            }
        }

        var colors = [Int]()
        colors.reserveCapacity(distinctColorCount)
        for color in 0..<histogram.count where histogram[color] > 0 {
            colors.append(color)
        }

        if distinctColorCount <= maxColors {
            // Fewer colours than asked for: each one is a swatch, in histogram order.
            return colors.map { PaletteSwatch(argb: approximateToRgb888(color555: $0), population: histogram[$0]) }
        }

        // Always split the box with the largest volume first.
        var queue = JavaPriorityQueue<Vbox> { lhs, rhs in rhs.volume - lhs.volume }
        queue.offer(Vbox(lower: 0, upper: colors.count - 1, colors: colors, histogram: histogram))

        while queue.count < maxColors {
            guard var box = queue.poll(), box.canSplit else { break }
            let newBox = box.split(colors: &colors, histogram: histogram)
            queue.offer(newBox)
            queue.offer(box)
        }

        var swatches = [PaletteSwatch]()
        swatches.reserveCapacity(queue.count)
        for box in queue.elementsInIterationOrder {
            let swatch = box.averageColor(colors: colors, histogram: histogram)
            if !shouldIgnore(argb: swatch.argb, hsl: swatch.hsl, filters: filters) {
                swatches.append(swatch)
            }
        }
        return swatches
    }

    // MARK: Boxes

    struct Vbox {
        // Inclusive bounds into the colours array.
        var lower: Int
        var upper: Int
        var population = 0
        var minRed = 0, maxRed = 0
        var minGreen = 0, maxGreen = 0
        var minBlue = 0, maxBlue = 0

        init(lower: Int, upper: Int, colors: [Int], histogram: [Int]) {
            self.lower = lower
            self.upper = upper
            fit(colors: colors, histogram: histogram)
        }

        var volume: Int {
            (maxRed - minRed + 1) * (maxGreen - minGreen + 1) * (maxBlue - minBlue + 1)
        }

        var colorCount: Int { 1 + upper - lower }

        var canSplit: Bool { colorCount > 1 }

        /// Shrinks the bounds to tightly fit the colours in the box.
        mutating func fit(colors: [Int], histogram: [Int]) {
            var minR = Int.max, minG = Int.max, minB = Int.max
            var maxR = Int.min, maxG = Int.min, maxB = Int.min
            var count = 0
            for i in lower...upper {
                let color = colors[i]
                count += histogram[color]
                let r = quantizedRed(color), g = quantizedGreen(color), b = quantizedBlue(color)
                if r > maxR { maxR = r }
                if r < minR { minR = r }
                if g > maxG { maxG = g }
                if g < minG { minG = g }
                if b > maxB { maxB = b }
                if b < minB { minB = b }
            }
            minRed = minR; maxRed = maxR
            minGreen = minG; maxGreen = maxG
            minBlue = minB; maxBlue = maxB
            population = count
        }

        /// Splits at the population median along the longest dimension; `self`
        /// keeps the lower half and the upper half is returned.
        mutating func split(colors: inout [Int], histogram: [Int]) -> Vbox {
            precondition(canSplit, "Can not split a box with only 1 color")
            let splitPoint = findSplitPoint(colors: &colors, histogram: histogram)
            let newBox = Vbox(lower: splitPoint + 1, upper: upper, colors: colors, histogram: histogram)
            upper = splitPoint
            fit(colors: colors, histogram: histogram)
            return newBox
        }

        enum Dimension { case red, green, blue }

        var longestDimension: Dimension {
            let redLength = maxRed - minRed
            let greenLength = maxGreen - minGreen
            let blueLength = maxBlue - minBlue
            if redLength >= greenLength && redLength >= blueLength {
                return .red
            } else if greenLength >= redLength && greenLength >= blueLength {
                return .green
            } else {
                return .blue
            }
        }

        func findSplitPoint(colors: inout [Int], histogram: [Int]) -> Int {
            let dimension = longestDimension
            // Sort the box's colours by the longest dimension, by making it the
            // most significant word, sorting, and swapping back.
            modifySignificantOctet(&colors, dimension: dimension, lower: lower, upper: upper)
            colors[lower...upper].sort()
            modifySignificantOctet(&colors, dimension: dimension, lower: lower, upper: upper)

            let midPoint = population / 2
            var count = 0
            for i in lower...upper {
                count += histogram[colors[i]]
                if count >= midPoint {
                    // Never split on the upper index — that would give back the same box.
                    return min(upper - 1, i)
                }
            }
            return lower
        }

        func averageColor(colors: [Int], histogram: [Int]) -> PaletteSwatch {
            var redSum = 0, greenSum = 0, blueSum = 0
            var totalPopulation = 0
            for i in lower...upper {
                let color = colors[i]
                let colorPopulation = histogram[color]
                totalPopulation += colorPopulation
                redSum += colorPopulation * quantizedRed(color)
                greenSum += colorPopulation * quantizedGreen(color)
                blueSum += colorPopulation * quantizedBlue(color)
            }
            let redMean = javaRound(Float(redSum) / Float(totalPopulation))
            let greenMean = javaRound(Float(greenSum) / Float(totalPopulation))
            let blueMean = javaRound(Float(blueSum) / Float(totalPopulation))
            return PaletteSwatch(
                argb: approximateToRgb888(red: redMean, green: greenMean, blue: blueMean),
                population: totalPopulation
            )
        }
    }

    static func modifySignificantOctet(_ a: inout [Int], dimension: Vbox.Dimension, lower: Int, upper: Int) {
        switch dimension {
        case .red:
            break
        case .green:
            // RGB <-> GRB
            for i in lower...upper {
                let color = a[i]
                a[i] = quantizedGreen(color) << (wordWidth * 2) | quantizedRed(color) << wordWidth | quantizedBlue(color)
            }
        case .blue:
            // RGB <-> BGR
            for i in lower...upper {
                let color = a[i]
                a[i] = quantizedBlue(color) << (wordWidth * 2) | quantizedGreen(color) << wordWidth | quantizedRed(color)
            }
        }
    }

    // MARK: Filters

    static func shouldIgnore(color555: Int, filters: [PaletteFilter]) -> Bool {
        let rgb = approximateToRgb888(color555: color555)
        return shouldIgnore(argb: rgb, hsl: ColorUtilsPort.rgbToHSL(argb: rgb), filters: filters)
    }

    static func shouldIgnore(argb: UInt32, hsl: ThemeHSL, filters: [PaletteFilter]) -> Bool {
        filters.contains { !$0.isAllowed(argb, hsl) }
    }

    // MARK: Word width

    static func quantizeFromRgb888(_ color: UInt32) -> Int {
        let r = modifyWordWidth(redOf(color), from: 8, to: wordWidth)
        let g = modifyWordWidth(greenOf(color), from: 8, to: wordWidth)
        let b = modifyWordWidth(blueOf(color), from: 8, to: wordWidth)
        return r << (wordWidth * 2) | g << wordWidth | b
    }

    static func approximateToRgb888(red: Int, green: Int, blue: Int) -> UInt32 {
        opaqueARGB(
            red: modifyWordWidth(red, from: wordWidth, to: 8),
            green: modifyWordWidth(green, from: wordWidth, to: 8),
            blue: modifyWordWidth(blue, from: wordWidth, to: 8)
        )
    }

    static func approximateToRgb888(color555 color: Int) -> UInt32 {
        approximateToRgb888(red: quantizedRed(color), green: quantizedGreen(color), blue: quantizedBlue(color))
    }

    @inline(__always) static func quantizedRed(_ color: Int) -> Int { (color >> (wordWidth * 2)) & wordMask }
    @inline(__always) static func quantizedGreen(_ color: Int) -> Int { (color >> wordWidth) & wordMask }
    @inline(__always) static func quantizedBlue(_ color: Int) -> Int { color & wordMask }

    static func modifyWordWidth(_ value: Int, from currentWidth: Int, to targetWidth: Int) -> Int {
        let newValue = targetWidth > currentWidth
            ? value << (targetWidth - currentWidth)
            : value >> (currentWidth - targetWidth)
        return newValue & ((1 << targetWidth) - 1)
    }
}

/// `java.util.PriorityQueue` with a comparator: a binary min-heap whose sift-up
/// and sift-down match the JDK's step for step, so ties settle in the same
/// slots and iteration (which walks the backing array) yields the same order.
struct JavaPriorityQueue<Element> {
    private var heap: [Element] = []
    private let compare: (Element, Element) -> Int

    init(compare: @escaping (Element, Element) -> Int) {
        self.compare = compare
    }

    var count: Int { heap.count }

    /// Iteration order of the Java collection: the backing array, front to back.
    var elementsInIterationOrder: [Element] { heap }

    mutating func offer(_ element: Element) {
        heap.append(element)
        siftUp(from: heap.count - 1, element)
    }

    mutating func poll() -> Element? {
        guard !heap.isEmpty else { return nil }
        let result = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            siftDown(from: 0, last)
        }
        return result
    }

    private mutating func siftUp(from index: Int, _ element: Element) {
        var k = index
        while k > 0 {
            let parent = (k - 1) >> 1
            let e = heap[parent]
            if compare(element, e) >= 0 { break }
            heap[k] = e
            k = parent
        }
        heap[k] = element
    }

    private mutating func siftDown(from index: Int, _ element: Element) {
        var k = index
        let n = heap.count
        let half = n >> 1
        while k < half {
            var child = (k << 1) + 1
            var c = heap[child]
            let right = child + 1
            if right < n && compare(c, heap[right]) > 0 {
                child = right
                c = heap[child]
            }
            if compare(element, c) <= 0 { break }
            heap[k] = c
            k = child
        }
        heap[k] = element
    }
}
