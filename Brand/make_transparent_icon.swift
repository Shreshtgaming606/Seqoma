import AppKit
import Foundation

// Remove only the dark exterior connected to the image border. Keep the
// supplied artwork's interior RGB pixels intact, including dark regions.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift make_transparent_icon.swift input.png output.png")
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = NSBitmapImageRep(data: try Data(contentsOf: input)),
      source.bitsPerSample == 8, source.bitsPerPixel == 32,
      let sourcePixels = source.bitmapData,
      let result = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: source.pixelsWide,
                                    pixelsHigh: source.pixelsHigh,
                                    bitsPerSample: 8,
                                    samplesPerPixel: 4,
                                    hasAlpha: true,
                                    isPlanar: false,
                                    colorSpaceName: .calibratedRGB,
                                    bytesPerRow: 0,
                                    bitsPerPixel: 0),
      let resultPixels = result.bitmapData else {
    fatalError("Expected an 8-bit RGB icon")
}

let width = source.pixelsWide
let height = source.pixelsHigh
let count = width * height
let threshold: UInt8 = 30
var exterior = [Bool](repeating: false, count: count)
var queue: [Int] = []
queue.reserveCapacity(count / 4)

func offset(_ index: Int, rowBytes: Int) -> Int {
    (index / width) * rowBytes + (index % width) * 4
}

for index in 0..<count {
    let sourceOffset = offset(index, rowBytes: source.bytesPerRow)
    let resultOffset = offset(index, rowBytes: result.bytesPerRow)
    resultPixels[resultOffset] = sourcePixels[sourceOffset]
    resultPixels[resultOffset + 1] = sourcePixels[sourceOffset + 1]
    resultPixels[resultOffset + 2] = sourcePixels[sourceOffset + 2]
    resultPixels[resultOffset + 3] = 255
}

func addExterior(_ index: Int) {
    guard !exterior[index] else { return }
    let sourceOffset = offset(index, rowBytes: source.bytesPerRow)
    guard sourcePixels[sourceOffset] <= threshold,
          sourcePixels[sourceOffset + 1] <= threshold,
          sourcePixels[sourceOffset + 2] <= threshold else { return }
    exterior[index] = true
    queue.append(index)
}

for x in 0..<width {
    addExterior(x)
    addExterior((height - 1) * width + x)
}
for y in 0..<height {
    addExterior(y * width)
    addExterior(y * width + width - 1)
}

var cursor = 0
while cursor < queue.count {
    let index = queue[cursor]
    cursor += 1
    let x = index % width
    let y = index / width
    if x > 0 { addExterior(index - 1) }
    if x + 1 < width { addExterior(index + 1) }
    if y > 0 { addExterior(index - width) }
    if y + 1 < height { addExterior(index + width) }
}

for index in queue {
    resultPixels[offset(index, rowBytes: result.bytesPerRow) + 3] = 0
}

guard let png = result.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode icon PNG")
}
try png.write(to: output, options: .atomic)
print("Made \(queue.count) exterior pixels transparent in \(output.path)")
